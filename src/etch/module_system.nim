# module_system.nim
# Module loading and resolution for Etch

import std/[tables, os, sets, options]
import frontend/[ast, parser, lexer]
import common/[types, errors, cffi, library_resolver]

type
  ExportKind* = enum
    ekFunction, ekConstant, ekType

  ExportedItem* = object
    case kind*: ExportKind
    of ekFunction:
      funcDecl*: FunDecl
    of ekConstant:
      constName*: string
      constType*: EtchType
      constValue*: Expr
    of ekType:
      typeName*: string
      typeDecl*: EtchType

  ModuleInfo* = object
    path*: string
    program*: Program
    exports*: Table[string, ExportedItem]
    isLoaded*: bool

  ModuleRegistry* = ref object
    modules*: Table[string, ModuleInfo]
    searchPaths*: seq[string]
    loadedPaths*: HashSet[string]  # Track loaded files to prevent cycles

# Global module registry
var globalModuleRegistry* = ModuleRegistry(
  modules: initTable[string, ModuleInfo](),
  searchPaths: @[".", "modules", "lib"],  # Default search paths
  loadedPaths: initHashSet[string]()
)

proc resolvePath*(registry: ModuleRegistry, importPath: string, fromFile: string): string =
  ## Resolve module path relative to current file and search paths

  # If it's an absolute path, use it directly
  if isAbsolute(importPath):
    if fileExists(importPath):
      return importPath
    raise newException(IOError, "Module not found: " & importPath)

  # Try relative to the importing file's directory
  let fromDir = parentDir(fromFile)
  let relativePath = fromDir / importPath
  if fileExists(relativePath):
    return relativePath

  # Try search paths
  for searchPath in registry.searchPaths:
    let fullPath = searchPath / importPath
    if fileExists(fullPath):
      return fullPath

  raise newException(IOError, "Module not found: " & importPath)

proc extractExports*(program: Program): Table[string, ExportedItem] =
  ## Extract exported items from a program
  ## Only export items explicitly marked with 'export'

  result = initTable[string, ExportedItem]()

  # Export functions marked as exported
  for name, funcList in program.funs:
    for fn in funcList:
      if fn.isExported:
        result[name] = ExportedItem(
          kind: ekFunction,
          funcDecl: fn
        )
        break  # Only export first overload for now

  # Export global constants marked as exported (let declarations)
  for global in program.globals:
    if global.isExported and global.kind == skVar and global.vflag == vfLet:
      if global.vinit.isSome:
        result[global.vname] = ExportedItem(
          kind: ekConstant,
          constName: global.vname,
          constType: global.vtype,
          constValue: global.vinit.get()
        )

  # Export all type declarations
  for typeName, typeDecl in program.types:
    result[typeName] = ExportedItem(
      kind: ekType,
      typeName: typeName,
      typeDecl: typeDecl
    )

proc loadModule*(registry: ModuleRegistry, importPath: string, fromFile: string): ModuleInfo =
  ## Load a module from disk and parse it

  let resolvedPath = registry.resolvePath(importPath, fromFile)

  # Check if already loaded
  if resolvedPath in registry.loadedPaths:
    if resolvedPath in registry.modules:
      return registry.modules[resolvedPath]
    else:
      raise newException(ValueError, "Circular dependency detected: " & resolvedPath)

  # Mark as being loaded (to detect cycles)
  registry.loadedPaths.incl(resolvedPath)

  # Read and parse the module
  let source = readFile(resolvedPath)
  let tokens = lex(source)
  let program = parseProgram(tokens, resolvedPath)

  # For now, don't recursively process imports in loaded modules
  # This avoids circular dependencies and keeps things simple

  # Extract exports from the module
  let exports = extractExports(program)

  # Create and store module info
  result = ModuleInfo(
    path: resolvedPath,
    program: program,
    exports: exports,
    isLoaded: true
  )

  registry.modules[resolvedPath] = result

proc processImports*(registry: ModuleRegistry, program: var Program, mainFile: string) =
  ## Process all import statements in a program

  var importsToProcess: seq[Stmt] = @[]
  var newGlobals: seq[Stmt] = @[]

  # Separate imports from other globals
  for global in program.globals:
    if global.kind == skImport:
      importsToProcess.add(global)
    else:
      newGlobals.add(global)

  # Process each import
  for importStmt in importsToProcess:
    case importStmt.importKind
    of "module":
      # Load the module
      let moduleInfo = registry.loadModule(importStmt.importPath, mainFile)

      # Import requested items or all exports if no specific items
      if importStmt.importItems.len == 0:
        # Import all exports
        for name, item in moduleInfo.exports:
          case item.kind
          of ekFunction:
            if name notin program.funs:
              program.funs[name] = @[]
            program.funs[name].add(item.funcDecl)
          of ekConstant:
            # Add as global constant
            let varStmt = Stmt(
              kind: skVar,
              vflag: vfLet,
              vname: name,
              vtype: item.constType,
              vinit: some(item.constValue),
              pos: importStmt.pos
            )
            newGlobals.add(varStmt)
          of ekType:
            program.types[name] = item.typeDecl
      else:
        # Import specific items
        for importItem in importStmt.importItems:
          if importItem.name in moduleInfo.exports:
            let exported = moduleInfo.exports[importItem.name]
            case exported.kind
            of ekFunction:
              # If no itemKind specified, default to function
              if importItem.itemKind == "" or importItem.itemKind == "function":
                if importItem.name notin program.funs:
                  program.funs[importItem.name] = @[]
                program.funs[importItem.name].add(exported.funcDecl)
            of ekConstant:
              if importItem.itemKind == "const":
                let varStmt = Stmt(
                  kind: skVar,
                  vflag: vfLet,
                  vname: importItem.name,
                  vtype: exported.constType,
                  vinit: some(exported.constValue),
                  pos: importStmt.pos
                )
                newGlobals.add(varStmt)
            of ekType:
              if importItem.itemKind == "type":
                program.types[importItem.name] = exported.typeDecl
          else:
            raise newParseError(importStmt.pos,
              "Item '" & importItem.name & "' not found in module " & importStmt.importPath)

    of "cffi":
      # Process FFI imports - load native functions from shared libraries
      # The import path should be the library name, alias, or relative path
      let importingDir = if importStmt.pos.filename.len > 0:
        parentDir(importStmt.pos.filename)
      else:
        "."

      # Use shared library resolver for consistent resolution
      let (libName, actualLibPath) = resolveLibraryPath(importStmt.importPath, importingDir)

      # Try to load the library if not already loaded
      if libName notin globalCFFIRegistry.libraries:
        var loaded = false

        # Try to load the library with the resolved path
        if actualLibPath != "":
          try:
            discard globalCFFIRegistry.loadLibrary(libName, actualLibPath)
            loaded = true
          except:
            # Try searching in standard paths
            let foundPath = findLibraryInSearchPaths(actualLibPath)
            if foundPath != "":
              try:
                discard globalCFFIRegistry.loadLibrary(libName, foundPath)
                loaded = true
              except:
                discard

        if not loaded:
          raise newParseError(importStmt.pos,
            "Failed to load C library: " & importStmt.importPath)

      # Load each function from the library
      for importItem in importStmt.importItems:
        if importItem.itemKind == "function":
          # Register the C function - convert AST params to FFI params
          var ffiParams: seq[cffi.ParamSpec] = @[]
          for param in importItem.signature.params:
            ffiParams.add(cffi.ParamSpec(
              name: param.name,
              typ: param.typ
            ))

          let signature = cffi.FunctionSignature(
            params: ffiParams,
            returnType: importItem.signature.returnType
          )

          # Symbol name defaults to function name if not specified
          let symbol = if importItem.alias != "":
            importItem.alias
          else:
            importItem.name

          try:
            # Create a function declaration that will be handled as C FFI call
            let funcDecl = FunDecl(
              name: importItem.name,
              typarams: @[],
              params: importItem.signature.params,
              ret: importItem.signature.returnType,
              body: @[],  # Empty body - will be handled as C FFI
              isCFFI: true  # Mark as C FFI function
            )

            # Generate the mangled name for the function (used in bytecode)
            let mangledName = generateOverloadSignature(funcDecl)

            # Load the function with the mangled name
            globalCFFIRegistry.loadFunction(libName, mangledName, symbol, signature)

            if importItem.name notin program.funs:
              program.funs[importItem.name] = @[]
            program.funs[importItem.name].add(funcDecl)
          except:
            raise newParseError(importStmt.pos,
              "Failed to load C function '" & symbol & "' from library " & libName)

    else:
      raise newParseError(importStmt.pos, "Unknown import kind: " & importStmt.importKind)

  # Update program globals with the new list (imports removed, imported items added)
  program.globals = newGlobals

proc addSearchPath*(registry: ModuleRegistry, path: string) =
  ## Add a search path for module resolution
  if path notin registry.searchPaths:
    registry.searchPaths.add(path)