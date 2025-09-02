# typeconv.nim
# Type conversion instruction handlers

import std/strutils
import ../../common/[values, types]
import ../[vm, vm_types]


proc execCast*(vm: VirtualMachine, instr: Instruction) {.inline.} =
  let val = getReg(vm, instr.b)
  let castType = VKind(instr.c)  # Cast to VKind enum
  var res: V

  case castType:
  of vkInt:  # To int
    if isInt(val):
      res = val
    elif isFloat(val):
      res = makeInt(int64(getFloat(val)))
    elif isEnum(val):
      res = makeInt(val.enumIntVal)
    elif isString(val):
      try:
        res = makeInt(int64(parseInt(val.sval)))
      except:
        res = makeNil()
    elif isTypeDesc(val):
      res = makeInt(computeStringHashId(val.typeDescName))
    else:
      res = makeNil()

  of vkFloat:  # To float
    if isFloat(val):
      res = val
    elif isInt(val):
      res = makeFloat(float64(getInt(val)))
    elif isString(val):
      try:
        res = makeFloat(parseFloat(val.sval))
      except:
        res = makeNil()
    else:
      res = makeNil()

  of vkString:  # To string
    if isInt(val):
      res = makeString($getInt(val))
    elif isFloat(val):
      let fv = getFloat(val)
      if fv == float64(int64(fv)):
        res = makeString(formatFloat(fv, ffDecimal, 1))
      else:
        let fstr = formatFloat(fv, ffDefault, -1)
        if '.' notin fstr and 'e' notin fstr and 'E' notin fstr:
          res = makeString(fstr & ".0")
        else:
          res = makeString(fstr)
    elif isString(val):
      res = val
    elif isEnum(val):
      res = makeString(val.enumStringVal)
    elif isBool(val):
      res = makeString(if getBool(val): "true" else: "false")
    elif isNil(val):
      res = makeString("nil")
    elif isTypeDesc(val):
      res = makeString(val.typeDescName)
    else:
      res = makeString("")

  else:
    res = makeNil()

  setReg(vm, instr.a, res)
