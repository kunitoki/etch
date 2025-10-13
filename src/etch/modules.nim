# modules.nim
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
    loadedPaths*: HashSet[string]

var globalModuleRegistry* = ModuleRegistry(
  modules: initTable[string, ModuleInfo](),
  searchPaths: @[".", "modules", "lib"],
  loadedPaths: initHashSet[string]()
)

proc resolvePath*(registry: ModuleRegistry, importPath: string, fromFile: string): string =
  if isAbsolute(importPath):
    if fileExists(importPath):
      return importPath
    raise newException(IOError, "Module not found: " & importPath)

  let fromDir = parentDir(fromFile)
  let relativePath = fromDir / importPath
  if fileExists(relativePath):
    return relativePath

  for searchPath in registry.searchPaths:
    let fullPath = searchPath / importPath
    if fileExists(fullPath):
      return fullPath

  raise newException(IOError, "Module not found: " & importPath)

proc extractExports*(program: Program): Table[string, ExportedItem] =
  result = initTable[string, ExportedItem]()

  for name, funcList in program.funs:
    for fn in funcList:
      if fn.isExported:
        result[name] = ExportedItem(
          kind: ekFunction,
          funcDecl: fn
        )
        break

  for global in program.globals:
    if global.isExported and global.kind == skVar and global.vflag == vfLet:
      if global.vinit.isSome:
        result[global.vname] = ExportedItem(
          kind: ekConstant,
          constName: global.vname,
          constType: global.vtype,
          constValue: global.vinit.get()
        )

  for typeName, typeDecl in program.types:
    result[typeName] = ExportedItem(
      kind: ekType,
      typeName: typeName,
      typeDecl: typeDecl
    )

proc loadModule*(registry: ModuleRegistry, importPath: string, fromFile: string): ModuleInfo =
  let resolvedPath = registry.resolvePath(importPath, fromFile)

  if resolvedPath in registry.loadedPaths:
    if resolvedPath in registry.modules:
      return registry.modules[resolvedPath]
    else:
      raise newException(ValueError, "Circular dependency detected: " & resolvedPath)

  registry.loadedPaths.incl(resolvedPath)

  let source = readFile(resolvedPath)
  let tokens = lex(source)
  let program = parseProgram(tokens, resolvedPath)

  let exports = extractExports(program)

  result = ModuleInfo(
    path: resolvedPath,
    program: program,
    exports: exports,
    isLoaded: true
  )

  registry.modules[resolvedPath] = result

proc processImports*(registry: ModuleRegistry, program: var Program, mainFile: string) =
  var importsToProcess: seq[Stmt] = @[]
  var newGlobals: seq[Stmt] = @[]

  for global in program.globals:
    if global.kind == skImport:
      importsToProcess.add(global)
    else:
      newGlobals.add(global)

  for importStmt in importsToProcess:
    case importStmt.importKind
    of "module":
      let moduleInfo = registry.loadModule(importStmt.importPath, mainFile)

      if importStmt.importItems.len == 0:
        for name, item in moduleInfo.exports:
          case item.kind
          of ekFunction:
            if name notin program.funs:
              program.funs[name] = @[]
            program.funs[name].add(item.funcDecl)
          of ekConstant:
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
        for importItem in importStmt.importItems:
          if importItem.name in moduleInfo.exports:
            let exported = moduleInfo.exports[importItem.name]
            case exported.kind
            of ekFunction:
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
      let importingDir = if importStmt.pos.filename.len > 0:
        parentDir(importStmt.pos.filename)
      else:
        "."

      let (libName, actualLibPath) = resolveLibraryPath(importStmt.importPath, importingDir)

      if libName notin globalCFFIRegistry.libraries:
        var loaded = false

        if actualLibPath != "":
          try:
            discard globalCFFIRegistry.loadLibrary(libName, actualLibPath)
            loaded = true
          except:
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

      for importItem in importStmt.importItems:
        if importItem.itemKind == "function":
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

          let symbol = if importItem.alias != "":
            importItem.alias
          else:
            importItem.name

          try:
            let funcDecl = FunDecl(
              name: importItem.name,
              typarams: @[],
              params: importItem.signature.params,
              ret: importItem.signature.returnType,
              body: @[],
              isCFFI: true
            )

            let mangledName = generateOverloadSignature(funcDecl)

            globalCFFIRegistry.loadFunction(libName, mangledName, symbol, signature)

            if importItem.name notin program.funs:
              program.funs[importItem.name] = @[]
            program.funs[importItem.name].add(funcDecl)
          except:
            raise newParseError(importStmt.pos,
              "Failed to load C function '" & symbol & "' from library " & libName)

    else:
      raise newParseError(importStmt.pos, "Unknown import kind: " & importStmt.importKind)

  program.globals = newGlobals

proc addSearchPath*(registry: ModuleRegistry, path: string) =
  if path notin registry.searchPaths:
    registry.searchPaths.add(path)