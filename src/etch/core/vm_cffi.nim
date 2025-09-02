# vm_cffi.nim
# Shared utilities for CFFI (Common Foreign Function Interface) operations

import std/[tables, strformat]
import ../common/[cffi, logging]
import ./vm_types


proc createCFFIFunctionInfo*(funcName: string, cffiFunc: CFFIFunction, existing: FunctionInfo, libraryPath: string, verbose: bool): FunctionInfo =
  ## Create a CFFI FunctionInfo with proper parameter/return types and library info
  logCompiler(verbose, &"CFFI function {funcName} uses library {cffiFunc.library} at path: {libraryPath}")

  var paramTypes: seq[string] = @[]
  for param in cffiFunc.signature.params:
    paramTypes.add($param.typ.kind)

  let returnType = $cffiFunc.signature.returnType.kind

  FunctionInfo(
    name: funcName,
    kind: fkCFFI,
    library: cffiFunc.library,
    libraryPath: libraryPath,
    symbol: cffiFunc.symbol,
    baseName: cffiFunc.symbol,
    paramTypes: paramTypes,
    returnType: returnType
  )


proc updateCFFIFunctions*(regProg: var BytecodeProgram, verbose: bool, registry: CFFIRegistry, updateExisting: bool = true) =
  ## Update all CFFI functions in bytecode program with proper metadata
  if updateExisting:
    # Update existing CFFI functions in the program
    var functionsToUpdate: seq[string] = @[]
    for funcName, funcInfo in regProg.functions:
      if funcInfo.kind == fkCFFI and registry.functions.hasKey(funcName):
        functionsToUpdate.add(funcName)

    for funcName in functionsToUpdate:
      let cffiFunc = registry.functions[funcName]
      let libPath = if cffiFunc.library in registry.libraries:
        registry.libraries[cffiFunc.library].path
      else:
        regProg.functions[funcName].libraryPath
      regProg.functions[funcName] = createCFFIFunctionInfo(funcName, cffiFunc, regProg.functions[funcName], libPath, verbose)
  else:
    # Add/update all CFFI functions from registry
    for funcName, cffiFunc in registry.functions:
      let libPath = if cffiFunc.library in registry.libraries:
        registry.libraries[cffiFunc.library].path
      else:
        ""
      regProg.functions[funcName] = createCFFIFunctionInfo(funcName, cffiFunc, FunctionInfo(name: funcName), libPath, verbose)
