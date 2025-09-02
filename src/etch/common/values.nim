# values.nim
# Common value types used across FFI and interpreter

type
  ValueKind* = enum
    vkInt, vkFloat, vkString, vkChar, vkBool, vkVoid, vkRef, vkOption,
    vkResult, vkUnion, vkEnum, vkClosure

  Value* = object
    case kind*: ValueKind
    of vkInt:
      intVal*: int64
    of vkFloat:
      floatVal*: float64
    of vkString:
      stringVal*: string
    of vkChar:
      charVal*: char
    of vkBool:
      boolVal*: bool
    of vkVoid:
      discard
    of vkRef:
      refId*: int
    of vkOption:
      hasValue*: bool
      optionVal*: ref Value
    of vkResult:
      isOk*: bool
      resultVal*: ref Value
    of vkUnion:
      unionTypeIndex*: int     # Index indicating which type in the union is active (0-based)
      unionVal*: ref Value     # The actual value
    of vkEnum:
      enumTypeId*: int         # Type ID for the enum
      enumIntVal*: int64       # The integer value
      enumStringVal*: string   # The string representation (interned)
    of vkClosure:
      closureId*: int          # Closure object ID (RegVM heap)

# Value constructors
proc vInt*(val: int64): Value =
  Value(kind: vkInt, intVal: val)

proc vFloat*(val: float64): Value =
  Value(kind: vkFloat, floatVal: val)

proc vString*(val: string): Value =
  Value(kind: vkString, stringVal: val)

proc vChar*(val: char): Value =
  Value(kind: vkChar, charVal: val)

proc vBool*(val: bool): Value =
  Value(kind: vkBool, boolVal: val)

proc vVoid*(): Value =
  Value(kind: vkVoid)

proc vRef*(id: int): Value =
  Value(kind: vkRef, refId: id)

proc vClosure*(id: int): Value =
  Value(kind: vkClosure, closureId: id)

proc vUnion*(typeIndex: int, val: Value): Value =
  Value(kind: vkUnion, unionTypeIndex: typeIndex, unionVal: new(Value))

proc vEnum*(typeId: int, intVal: int64, stringVal: string): Value =
  Value(kind: vkEnum, enumTypeId: typeId, enumIntVal: intVal, enumStringVal: stringVal)

proc initUnion*(typeIndex: int, val: Value): Value =
  result = Value(kind: vkUnion, unionTypeIndex: typeIndex)
  new(result.unionVal)
  result.unionVal[] = val
