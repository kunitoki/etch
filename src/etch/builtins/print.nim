# print.nim

import ../frontend/ast
import ../common/[types, errors]


proc performBuiltinPrintTypeCheck*(argTypes: seq[EtchType], pos: Pos): EtchType =
  if argTypes.len != 1:
    raise newTypecheckError(pos, "print expects 1 argument")
  if argTypes[0].kind notin {tkBool, tkInt, tkFloat, tkString, tkChar}:
    raise newTypecheckError(pos, "print supports bool/int/float/string/char")
  return tVoid()
