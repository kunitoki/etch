# modules.nim
# Module loading and resolution for Etch

import std/[tables, os, sets, options, strformat]
import frontend/[ast, parser, lexer]
import ../common/[types, errors, cffi]
import ./libraries


type
  ExportKind* = enum
    ekFunction, ekConstant, ekType

  ExportedItem* = object
    case kind*: ExportKind
    of ekFunction:
      funcDecl*: FunctionDeclaration
    of ekConstant:
      constName*: string
      constType*: EtchType
      constValue*: Expression
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


proc newModuleRegistry*(): ModuleRegistry =
  ModuleRegistry(
    modules: initTable[string, ModuleInfo](),
    searchPaths: @[".", "modules", "lib"],
    loadedPaths: initHashSet[string]()
  )


proc resolvePath(registry: ModuleRegistry, importPath: string, fromFile: string): string =
  if isAbsolute(importPath):
    if fileExists(importPath):
      return importPath
    raise newException(IOError, &"Module not found: {importPath}")

  let fromDir = parentDir(fromFile)
  let relativePath = fromDir / importPath
  if fileExists(relativePath):
    return relativePath

  for searchPath in registry.searchPaths:
    let fullPath = searchPath / importPath
    if fileExists(fullPath):
      return fullPath

  raise newException(IOError, &"Module not found: {importPath}")


proc extractExports(program: Program): Table[string, ExportedItem] =
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


proc loadModule(registry: ModuleRegistry, importPath: string, fromFile: string): ModuleInfo =
  let resolvedPath = registry.resolvePath(importPath, fromFile)

  if resolvedPath in registry.loadedPaths:
    if resolvedPath in registry.modules:
      return registry.modules[resolvedPath]
    else:
      raise newException(ValueError, &"Circular dependency detected: {resolvedPath}")

  registry.loadedPaths.incl(resolvedPath)

  let source = readFile(resolvedPath)
  let tokens = lex(source, resolvedPath)
  let program = parseProgram(tokens, resolvedPath)

  let exports = extractExports(program)

  result = ModuleInfo(
    path: resolvedPath,
    program: program,
    exports: exports,
    isLoaded: true
  )

  registry.modules[resolvedPath] = result


proc processImports*(registry: ModuleRegistry, cffiReg: var CFFIRegistry, program: var Program, mainFile: string) =
  var importsToProcess: seq[Statement] = @[]
  var newGlobals: seq[Statement] = @[]

  for global in program.globals:
    if global.kind == skImport:
      importsToProcess.add(global)
    else:
      newGlobals.add(global)

  for importStatement in importsToProcess:
    case importStatement.importKind
    of "module":
      let moduleInfo = registry.loadModule(importStatement.importPath, mainFile)

      if importStatement.importItems.len == 0:
        for name, item in moduleInfo.exports:
          case item.kind
          of ekFunction:
            if name notin program.funs:
              program.funs[name] = @[]
            program.funs[name].add(item.funcDecl)
          of ekConstant:
            let varStatement = Statement(
              kind: skVar,
              vflag: vfLet,
              vname: name,
              vtype: item.constType,
              vinit: some(item.constValue),
              pos: importStatement.pos
            )
            newGlobals.add(varStatement)
          of ekType:
            program.types[name] = item.typeDecl
      else:
        for importItem in importStatement.importItems:
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
                let varStatement = Statement(
                  kind: skVar,
                  vflag: vfLet,
                  vname: importItem.name,
                  vtype: exported.constType,
                  vinit: some(exported.constValue),
                  pos: importStatement.pos
                )
                newGlobals.add(varStatement)
            of ekType:
              if importItem.itemKind == "type":
                program.types[importItem.name] = exported.typeDecl
          else:
            raise newParseError(importStatement.pos,
              &"Item '{importItem.name}' not found in module {importStatement.importPath}")

    of "cffi":
      let importingDir = if importStatement.pos.filename.len > 0:
        parentDir(importStatement.pos.filename)
      else:
        "."

      let (libName, actualLibPath) = resolveLibraryPath(importStatement.importPath, importingDir)

      # Lazily initialize the per-compilation CFFI registry provided by the caller
      if cffiReg.isNil:
        cffiReg = newCFFIRegistry()

      if libName notin cffiReg.libraries:
        var loaded = false

        if actualLibPath != "":
          try:
            discard cffiReg.loadLibrary(libName, actualLibPath)
            loaded = true
          except:
            let foundPath = findLibraryInSearchPaths(actualLibPath)
            if foundPath != "":
              try:
                discard cffiReg.loadLibrary(libName, foundPath)
                loaded = true
              except:
                discard

        if not loaded:
          raise newParseError(importStatement.pos,
            &"Failed to load C library: {importStatement.importPath}")

      for importItem in importStatement.importItems:
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
            let funcDecl = FunctionDeclaration(
              name: importItem.name,
              typarams: @[],
              params: importItem.signature.params,
              ret: importItem.signature.returnType,
              hasExplicitReturnType: true,
              body: @[],
              isCFFI: true
            )

            let mangledName = generateOverloadSignature(funcDecl)

            cffiReg.loadFunction(libName, mangledName, symbol, signature)

            if importItem.name notin program.funs:
              program.funs[importItem.name] = @[]
            program.funs[importItem.name].add(funcDecl)
          except:
            raise newParseError(importStatement.pos,
              &"Failed to load C function '{symbol}' from library {libName}")

    of "host":
      # Host functions are provided by the host context, not loaded from external libraries
      for importItem in importStatement.importItems:
        if importItem.itemKind == "function":
          # Create a FunctionDeclaration for the host function
          let funcDecl = FunctionDeclaration(
            name: importItem.name,
            typarams: @[],
            params: importItem.signature.params,
            ret: importItem.signature.returnType,
            hasExplicitReturnType: true,
            body: @[],
            isHost: true  # Mark as host function
          )

          if importItem.name notin program.funs:
            program.funs[importItem.name] = @[]
          program.funs[importItem.name].add(funcDecl)

    else:
      raise newParseError(importStatement.pos, &"Unknown import kind: {importStatement.importKind}")

  program.globals = newGlobals
