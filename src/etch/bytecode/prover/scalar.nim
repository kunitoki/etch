# scalar.nim
# Scalar type representing either integer or float values for the prover

import std/[math]


type
  Scalar* = object
    ## Numeric scalar that can represent either an integer or a float value
    ## The prover historically only tracked integers; this structure lets us
    ## preserve that precision while supporting float literals and ranges.
    isFloat*: bool
    ival*: int64
    fval*: float64

proc makeScalar*[T: SomeInteger](value: T): Scalar {.inline.} =
  Scalar(isFloat: false, ival: int64(value), fval: 0.0)

proc makeScalar*(value: float64): Scalar {.inline.} =
  Scalar(isFloat: true, ival: 0, fval: value)

#converter intToScalar*(value: SomeInteger): Scalar = makeScalar(value)
#converter floatToScalar*(value: float64): Scalar = makeScalar(value)

proc scalarZero*(): Scalar {.inline.} = makeScalar(0'i64)

proc scalarOne*(): Scalar {.inline.} = makeScalar(1'i64)

proc scalarNegOne*(): Scalar {.inline.} = makeScalar(-1'i64)

proc toFloat*(value: Scalar): float64 {.inline.} =
  if value.isFloat: value.fval else: value.ival.float64

proc toInt*(value: Scalar): int64 {.inline.} =
  if value.isFloat: value.fval.int64 else: value.ival

proc cmp*(a, b: Scalar): int {.inline.} =
  ## Compare two scalars promoting to float when necessary
  if a.isFloat or b.isFloat:
    return cmp(toFloat(a), toFloat(b))
  cmp(a.ival, b.ival)

proc `==`*(a, b: Scalar): bool {.inline.} = cmp(a, b) == 0
proc `!=`*(a, b: Scalar): bool {.inline.} = not (a == b)
proc `==`*[T: SomeInteger](a: Scalar, b: T): bool {.inline.} = a == makeScalar(b)
proc `!=`*[T: SomeInteger](a: Scalar, b: T): bool {.inline.} = not (a == b)
proc `==`*[T: SomeInteger](a: T, b: Scalar): bool {.inline.} = makeScalar(a) == b
proc `!=`*[T: SomeInteger](a: T, b: Scalar): bool {.inline.} = not (a == b)
proc `<`*(a, b: Scalar): bool {.inline.} = cmp(a, b) < 0
proc `<=`*(a, b: Scalar): bool {.inline.} = cmp(a, b) <= 0
proc `>`*(a, b: Scalar): bool {.inline.} = cmp(a, b) > 0
proc `>=`*(a, b: Scalar): bool {.inline.} = cmp(a, b) >= 0

proc `<`*[T: SomeInteger](a: Scalar, b: T): bool {.inline.} = a < makeScalar(b)
proc `<=`*[T: SomeInteger](a: Scalar, b: T): bool {.inline.} = a <= makeScalar(b)
proc `>`*[T: SomeInteger](a: Scalar, b: T): bool {.inline.} = a > makeScalar(b)
proc `>=`*[T: SomeInteger](a: Scalar, b: T): bool {.inline.} = a >= makeScalar(b)
proc `<`*[T: SomeInteger](a: T, b: Scalar): bool {.inline.} = makeScalar(a) < b
proc `<=`*[T: SomeInteger](a: T, b: Scalar): bool {.inline.} = makeScalar(a) <= b
proc `>`*[T: SomeInteger](a: T, b: Scalar): bool {.inline.} = makeScalar(a) > b
proc `>=`*[T: SomeInteger](a: T, b: Scalar): bool {.inline.} = makeScalar(a) >= b

proc `<`*(a: Scalar, b: float64): bool {.inline.} = toFloat(a) < b
proc `<=`*(a: Scalar, b: float64): bool {.inline.} = toFloat(a) <= b
proc `>`*(a: Scalar, b: float64): bool {.inline.} = toFloat(a) > b
proc `>=`*(a: Scalar, b: float64): bool {.inline.} = toFloat(a) >= b
proc `<`*(a: float64, b: Scalar): bool {.inline.} = a < toFloat(b)
proc `<=`*(a: float64, b: Scalar): bool {.inline.} = a <= toFloat(b)
proc `>`*(a: float64, b: Scalar): bool {.inline.} = a > toFloat(b)
proc `>=`*(a: float64, b: Scalar): bool {.inline.} = a >= toFloat(b)

proc scalarMin*(a, b: Scalar): Scalar {.inline.} =
    if a <= b: a else: b
proc scalarMax*(a, b: Scalar): Scalar {.inline.} =
    if a >= b: a else: b

proc scalarMin*[T: SomeInteger](a: Scalar, b: T): Scalar {.inline.} = scalarMin(a, makeScalar(b))
proc scalarMin*[T: SomeInteger](a: T, b: Scalar): Scalar {.inline.} = scalarMin(makeScalar(a), b)
proc scalarMax*[T: SomeInteger](a: Scalar, b: T): Scalar {.inline.} = scalarMax(a, makeScalar(b))
proc scalarMax*[T: SomeInteger](a: T, b: Scalar): Scalar {.inline.} = scalarMax(makeScalar(a), b)

proc min*(a, b: Scalar): Scalar {.inline.} = scalarMin(a, b)
proc max*(a, b: Scalar): Scalar {.inline.} = scalarMax(a, b)

proc min*[T: SomeInteger](a: Scalar, b: T): Scalar {.inline.} = scalarMin(a, b)
proc min*[T: SomeInteger](a: T, b: Scalar): Scalar {.inline.} = scalarMin(a, b)
proc max*[T: SomeInteger](a: Scalar, b: T): Scalar {.inline.} = scalarMax(a, b)
proc max*[T: SomeInteger](a: T, b: Scalar): Scalar {.inline.} = scalarMax(a, b)

proc `+`*(a, b: Scalar): Scalar {.inline.} =
  if a.isFloat or b.isFloat:
    makeScalar(toFloat(a) + toFloat(b))
  else:
    makeScalar(a.ival + b.ival)

proc `-`*(a, b: Scalar): Scalar {.inline.} =
  if a.isFloat or b.isFloat:
    makeScalar(toFloat(a) - toFloat(b))
  else:
    makeScalar(a.ival - b.ival)

proc `*`*(a, b: Scalar): Scalar {.inline.} =
  if a.isFloat or b.isFloat:
    makeScalar(toFloat(a) * toFloat(b))
  else:
    makeScalar(a.ival * b.ival)

proc `/`*(a, b: Scalar): Scalar {.inline.} =
  if a.isFloat or b.isFloat:
    makeScalar(toFloat(a) / toFloat(b))
  else:
    makeScalar(a.ival div b.ival)

proc `div`*(a, b: Scalar): Scalar {.inline.} =
  if a.isFloat or b.isFloat:
    makeScalar(toFloat(a) / toFloat(b))
  else:
    makeScalar(a.ival div b.ival)

proc `mod`*(a, b: Scalar): Scalar {.inline.} =
  if a.isFloat or b.isFloat:
    let divisor = toFloat(b)
    if divisor == 0.0:
      return makeScalar(0.0)
    let dividend = toFloat(a)
    let quotient = floor(dividend / divisor)
    makeScalar(dividend - divisor * quotient)
  else:
    makeScalar(a.ival mod b.ival)

proc `+`*[T: SomeInteger](a: Scalar, b: T): Scalar {.inline.} = a + makeScalar(b)
proc `-`*[T: SomeInteger](a: Scalar, b: T): Scalar {.inline.} = a - makeScalar(b)
proc `+`*[T: SomeInteger](a: T, b: Scalar): Scalar {.inline.} = makeScalar(a) + b
proc `-`*[T: SomeInteger](a: T, b: Scalar): Scalar {.inline.} = makeScalar(a) - b

proc `-`*(a: Scalar): Scalar {.inline.} =
  if a.isFloat:
    makeScalar(-a.fval)
  else:
    makeScalar(-a.ival)

proc isZero*(value: Scalar): bool {.inline.} =
  if value.isFloat:
    value.fval == 0.0
  else:
    value.ival == 0

proc scalarAbs*(value: Scalar): Scalar {.inline.} =
  if value >= scalarZero(): value else: -value

proc isFloatScalar*(value: Scalar): bool {.inline.} = value.isFloat
proc isIntScalar*(value: Scalar): bool {.inline.} = not value.isFloat

proc scalarToString*(value: Scalar): string =
  if value.isFloat:
    $value.fval
  else:
    $value.ival

proc `$`*(value: Scalar): string = scalarToString(value)
