proc emitCFFIDeclarations(gen: var CGenerator) =
  ## Emit forward declarations for CFFI functions
  gen.emit("\n// CFFI forward declarations")
  for funcName, funcInfo in gen.program.functions:
    if funcInfo.kind == fkCFFI:
      # Generate parameter list
      var params = ""
      if funcInfo.paramTypes.len > 0:
        for i, paramType in funcInfo.paramTypes:
          if i > 0:
            params &= ", "
          params &= convertToCType(paramType)
      else:
        params = "void"

      # Map return type
      let returnType = convertToCType(funcInfo.returnType)

      # Access symbol field safely for CFFI functions
      let symbol = funcInfo.symbol
      gen.emit(&"extern {returnType} {symbol}({params});")

