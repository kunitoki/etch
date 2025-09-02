# ast.nim
# Core AST + type for Etch

import std/[tables, options, strutils]
import ../../common/[constants, types]


type
  EnumMember* = object
    name*: string
    intValue*: int64
    stringValue*: Option[string]

  ObjectField* = object
    name*: string
    fieldType*: EtchType
    defaultValue*: Option[Expression]

  EtchType* = ref object
    kind*: TypeKind
    name*: string               # for tkGeneric, tkUserDefined, tkDistinct, tkObject, tkEnum
    inner*: EtchType            # for tkRef and tkArray, base type for tkDistinct
    fields*: seq[ObjectField]   # for tkObject
    destructor*: Option[string] # for tkObject - destructor function name  (fn ~(obj: Type))
    unionTypes*: seq[EtchType]  # for tkUnion - list of possible types
    tupleTypes*: seq[EtchType]  # for tkTuple - list of element types
    enumMembers*: seq[EnumMember]  # for tkEnum - list of enum members
    enumTypeId*: int            # stable identifier for enum types
    funcParams*: seq[EtchType]  # for tkFunction - parameter types
    funcReturn*: EtchType       # for tkFunction - return type

  TypeEnv* = Table[string, EtchType]

  TyParam* = object
    name*: string
    koncept*: Option[string]

  BinOp* = enum
    boAdd, boSub, boMul, boDiv, boMod,
    boEq, boNe, boLt, boLe, boGt, boGe,
    boAnd, boOr, boIn, boNotIn

  UnOp* = enum uoNot, uoNeg

  PatternKind* = enum
    pkSome, pkNone, pkOk, pkErr, pkWildcard, pkType, pkEnum,
    pkIdentifier, pkLiteral, pkRange, pkOr, pkAs, pkTuple, pkArray

  PatternLiteralKind* = enum
    plInt, plFloat, plString, plChar, plBool

  PatternLiteral* = object
    case kind*: PatternLiteralKind
    of plBool:
      bval*: bool
    of plChar:
      cval*: char
    of plInt:
      ival*: int64
    of plFloat:
      fval*: float64
    of plString:
      sval*: string

  Pattern* = ref object
    pos*: Pos
    case kind*: PatternKind
    of pkSome, pkOk, pkErr:
      innerPattern*: Option[Pattern]  # inner pattern to match after unwrap
    of pkType:
      typePattern*: EtchType          # union branch type
      typeBind*: string               # optional binding name
    of pkEnum:
      enumPattern*: string            # qualified enum member name (e.g., "Color.Red")
      enumType*: EtchType             # the enum type
      enumMember*: Option[EnumMember] # the specific member being matched
    of pkLiteral:
      literal*: PatternLiteral
    of pkIdentifier:
      bindName*: string
    of pkRange:
      rangeStart*: PatternLiteral
      rangeEnd*: PatternLiteral
      endInclusive*: bool
    of pkOr:
      orPatterns*: seq[Pattern]
    of pkAs:
      innerAsPattern*: Pattern
      asBind*: string
    of pkTuple:
      tuplePatterns*: seq[Pattern]
    of pkArray:
      arrayPatterns*: seq[Pattern]
      hasSpread*: bool
      spreadName*: string
    of pkWildcard, pkNone:
      discard

  MatchCase* = object
    pattern*: Pattern
    body*: seq[Statement]          # statements to execute if pattern matches

  ExpressionKind* = enum
    ekBool, ekChar, ekInt, ekFloat, ekString, ekVar, ekBin, ekUn,
    ekCall, ekNewRef, ekDeref, ekArray, ekIndex, ekSlice, ekArrayLen, ekCast, ekNil,
    ekOptionSome, ekOptionNone, ekResultOk, ekResultErr, ekResultPropagate, ekMatch,
    ekObjectLiteral, ekFieldAccess, ekNew, ekIf, ekComptime, ekCompiles, ekTuple,
    ekYield, ekResume, ekSpawn, ekSpawnBlock, ekChannelNew, ekChannelSend, ekChannelRecv,
    ekLambda, ekTypeof

  Expression* = ref object
    pos*: Pos
    typ*: EtchType
    case kind*: ExpressionKind
    of ekNil:
      discard
    of ekBool:
      bval*: bool
    of ekChar:
      cval*: char
    of ekInt:
      ival*: int64
    of ekFloat:
      fval*: float64
    of ekString:
      sval*: string
    of ekVar:
      vname*: string
    of ekUn:
      uop*: UnOp
      ue*: Expression
    of ekBin:
      bop*: BinOp
      lhs*, rhs*: Expression
    of ekCall:
      fname*: string
      args*: seq[Expression]
      instTypes*: seq[EtchType]
      callTarget*: Expression
      callIsValue*: bool
    of ekNewRef:
      init*: Expression
      refInner*: EtchType
    of ekDeref:
      refExpression*: Expression
    of ekArray:
      elements*: seq[Expression]
    of ekIndex:
      arrayExpression*: Expression
      indexExpression*: Expression
    of ekSlice:
      sliceExpression*: Expression
      startExpression*: Option[Expression]
      endExpression*: Option[Expression]
    of ekArrayLen:
      lenExpression*: Expression
    of ekCast:
      castType*: EtchType
      castExpression*: Expression
    of ekOptionSome:
      someExpression*: Expression
    of ekOptionNone:
      discard
    of ekResultOk:
      okExpression*: Expression
    of ekResultErr:
      errExpression*: Expression
    of ekResultPropagate:
      propagateExpression*: Expression
    of ekMatch:
      matchExpression*: Expression        # expression to match against
      cases*: seq[MatchCase]  # pattern cases
    of ekObjectLiteral:
      objectType*: EtchType   # type of the object being created
      fieldInits*: seq[tuple[name: string, value: Expression]]  # field initializers
    of ekFieldAccess:
      objectExpression*: Expression       # object being accessed
      fieldName*: string      # name of field
      enumTargetType*: EtchType
      enumResolvedMember*: Option[EnumMember]
    of ekNew:
      newType*: EtchType      # type to create on heap (for ref[X])
      initExpression*: Option[Expression] # optional initialization expression
    of ekIf:
      ifCond*: Expression                                   # condition
      ifThen*: seq[Statement]                               # then body
      ifElifChain*: seq[tuple[cond: Expression, body: seq[Statement]]]  # elif chain
      ifElse*: seq[Statement]                               # else body
    of ekComptime:
      comptimeExpression*: Expression                       # expression to evaluate at compile-time
    of ekCompiles:
      compilesBlock*: seq[Statement]                        # statements to check if they compile
      compilesEnv*: Table[string, EtchType]                 # captured type environment from surrounding scope
    of ekTuple:
      tupleElements*: seq[Expression]                       # elements of the tuple
    of ekYield:
      yieldValue*: Option[Expression]                       # optional value to yield
    of ekResume:
      resumeValue*: Expression                              # coroutine to resume
    of ekSpawn:
      spawnExpression*: Expression                          # expression to spawn (call or async block)
    of ekSpawnBlock:
      spawnBody*: seq[Statement]                            # statements in spawn block
    of ekChannelNew:
      channelType*: EtchType                                # channel element type
      channelCapacity*: Option[Expression]                  # optional capacity (default 1)
    of ekChannelSend:
      sendChannel*: Expression                              # channel to send to
      sendValue*: Expression                                # value to send
    of ekChannelRecv:
      recvChannel*: Expression                              # channel to receive from
    of ekLambda:
      lambdaCaptures*: seq[string]                          # explicit capture list
      lambdaParams*: seq[Param]                             # lambda parameters
      lambdaReturnType*: EtchType                           # optional explicit return type
      lambdaBody*: seq[Statement]                           # lambda body
      lambdaCaptureTypes*: seq[EtchType]
      lambdaFunctionName*: string
    of ekTypeof:
      typeofExpression*: Expression                         # expression to get type of

  UnpackKind* = enum
    upArray      # Array unpacking: [a, b, c] = arr (compile-time positions)
    upObject     # Object unpacking: {x, y} = obj (field names)

  StatementKind* = enum
    skVar, skAssign, skCompoundAssign, skFieldAssign, skIf, skWhile, skFor,
    skBreak, skExpression, skReturn, skComptime, skTypeDecl, skImport,
    skDiscard, skDefer, skBlock, skTupleUnpack, skObjectUnpack

  TypeDefinitionKind* = enum
    tdkAlias, tdkDistinct, tdkObject, tdkEnum

  VarFlag* = enum
    vfLet, vfVar

  Statement* = ref object
    pos*: Pos
    isExported*: bool                 # Whether this is exported from the module
    case kind*: StatementKind
    of skVar:
      vflag*: VarFlag
      vname*: string
      vtype*: EtchType
      vinit*: Option[Expression]
    of skAssign:
      aname*: string
      aval*: Expression
    of skCompoundAssign:
      caname*: string
      cop*: BinOp
      crhs*: Expression
    of skFieldAssign:
      faTarget*: Expression           # field access expression (can be nested)
      faValue*: Expression            # value to assign
    of skIf:
      cond*: Expression
      thenBody*: seq[Statement]
      elifChain*: seq[tuple[cond: Expression, body: seq[Statement]]]
      elseBody*: seq[Statement]
    of skWhile:
      wcond*: Expression
      wbody*: seq[Statement]
    of skFor:
      fvar*: string
      fstart*: Option[Expression]     # None for array iteration
      fend*: Option[Expression]       # None for array iteration
      farray*: Option[Expression]     # Some for array iteration
      finclusive*: bool               # true for .., false for ..<
      fbody*: seq[Statement]
    of skExpression:
      sexpr*: Expression
    of skReturn:
      re*: Option[Expression]
    of skComptime:
      cbody*: seq[Statement]
    of skTypeDecl:
      typeName*: string               # name of the type being declared
      typeKind*: TypeDefinitionKind   # type of declaration
      aliasTarget*: EtchType          # target type for alias/distinct
      objectFields*: seq[ObjectField] # fields for object types
      enumMembers*: seq[EnumMember]   # members for enum types
    of skImport:
      importKind*: string             # "module" or "ffi"
      importPath*: string             # file path for modules, namespace for FFI
      importItems*: seq[ImportItem]   # items to import
    of skDiscard:
      dexprs*: seq[Expression]        # expressions to discard
    of skBreak:
      discard
    of skDefer:
      deferBody*: seq[Statement]      # statements to execute at scope exit
    of skBlock:
      blockBody*: seq[Statement]      # statements in unnamed scope block
      blockHoistedVars*: seq[string]  # variable names that survive past this block
    of skTupleUnpack:
      tupFlag*: VarFlag               # let or var
      tupNames*: seq[string]          # variable names to bind
      tupTypes*: seq[EtchType]        # optional type annotations (nil if not provided)
      tupInit*: Expression            # tuple expression to unpack
    of skObjectUnpack:
      objFlag*: VarFlag               # let or var
      objFieldMappings*: seq[tuple[fieldName: string, varName: string]]  # field -> variable mappings
      objTypes*: seq[EtchType]        # resolved types for each variable
      objInit*: Expression            # object expression to unpack

  ImportItem* = object
    pos*: Pos
    itemKind*: string       # "function", "const", "type"
    name*: string           # item name
    signature*: FunctionSignature  # for functions
    typ*: EtchType          # for constants and types
    isExported*: bool       # whether item is exported from module
    alias*: string          # optional alias for C FFI symbols

  FunctionSignature* = object
    params*: seq[Param]
    returnType*: EtchType

  Param* = object
    name*: string
    typ*: EtchType
    defaultValue*: Option[Expression]

  FunctionDeclaration* = ref object
    pos*: Pos
    name*: string
    typarams*: seq[TyParam]
    params*: seq[Param]
    ret*: EtchType
    hasExplicitReturnType*: bool
    body*: seq[Statement]
    isExported*: bool  # Whether this function is exported
    isCFFI*: bool      # Whether this is a C FFI function
    isHost*: bool      # Whether this is a host function
    isAsync*: bool     # Whether this function contains yields (coroutine)
    isBuiltin*: bool   # Whether this declaration represents a builtin function
    usesResultPropagation*: bool            # Tracks whether postfix ? appears in body
    resultPropagationInner*: EtchType       # Inferred inner type required by postfix ?
    resultPropagationPos*: Option[Pos]      # First source location of postfix ?

  Program* = ref object
    globals*: seq[Statement]                          # global let/var with init allowed
    funs*: Table[string, seq[FunctionDeclaration]]    # generic templates (supports overloads)
    funInstances*: Table[string, FunctionDeclaration] # monomorphized instances
    types*: Table[string, EtchType]                   # user-defined types
    lambdaCounter*: int


proc compoundAssignExpression*(stmt: Statement): Expression =
  ## Build a synthetic binary expression representing a compound assignment
  doAssert stmt.kind == skCompoundAssign
  result = Expression(
    kind: ekBin,
    bop: stmt.cop,
    lhs: Expression(kind: ekVar, vname: stmt.caname, pos: stmt.pos),
    rhs: stmt.crhs,
    pos: stmt.pos
  )


proc desugarCompoundAssign*(stmt: Statement): Statement =
  ## Convert a compound assignment into a regular assignment statement
  doAssert stmt.kind == skCompoundAssign
  result = Statement(
    kind: skAssign,
    aname: stmt.caname,
    aval: compoundAssignExpression(stmt),
    pos: stmt.pos,
    isExported: stmt.isExported
  )


proc tVoid*(): EtchType = EtchType(kind: tkVoid)
proc tBool*(): EtchType = EtchType(kind: tkBool)
proc tChar*(): EtchType = EtchType(kind: tkChar)
proc tInt*(): EtchType = EtchType(kind: tkInt)
proc tFloat*(): EtchType = EtchType(kind: tkFloat)
proc tString*(): EtchType = EtchType(kind: tkString)
proc tInferred*(): EtchType = EtchType(kind: tkInferred)
proc tArray*(inner: EtchType): EtchType = EtchType(kind: tkArray, inner: inner)
proc tRef*(inner: EtchType): EtchType = EtchType(kind: tkRef, inner: inner)
proc tWeak*(inner: EtchType): EtchType = EtchType(kind: tkWeak, inner: inner)
proc tGeneric*(name: string): EtchType = EtchType(kind: tkGeneric, name: name)
proc tOption*(inner: EtchType): EtchType = EtchType(kind: tkOption, inner: inner)
proc tResult*(inner: EtchType): EtchType = EtchType(kind: tkResult, inner: inner)
proc tUserDefined*(name: string): EtchType = EtchType(kind: tkUserDefined, name: name)
proc tDistinct*(name: string, base: EtchType): EtchType = EtchType(kind: tkDistinct, name: name, inner: base)
proc tUnion*(types: seq[EtchType]): EtchType = EtchType(kind: tkUnion, unionTypes: types)
proc tTuple*(types: seq[EtchType]): EtchType = EtchType(kind: tkTuple, tupleTypes: types)
proc tCoroutine*(inner: EtchType): EtchType = EtchType(kind: tkCoroutine, inner: inner)
proc tChannel*(inner: EtchType): EtchType = EtchType(kind: tkChannel, inner: inner)
proc tObject*(name: string, fields: seq[ObjectField], destructor: Option[string] = none(string)): EtchType =
  EtchType(kind: tkObject, name: name, fields: fields, destructor: destructor)
proc tEnum*(name: string, members: seq[EnumMember]): EtchType =
  EtchType(kind: tkEnum, name: name, enumMembers: members, enumTypeId: computeStringHashId(name))
proc tFunction*(params: seq[EtchType], ret: EtchType): EtchType =
  EtchType(kind: tkFunction, funcParams: params, funcReturn: if ret != nil: ret else: tVoid())
proc tTypeDesc*(): EtchType = EtchType(kind: tkTypeDesc)


proc etchTypeFromString*(valueName: string): EtchType


proc splitTopLevel(str: string; separator: char): seq[string] =
  var current = ""
  var depthSquare = 0
  var depthParen = 0
  for ch in str:
    if ch == separator and depthSquare == 0 and depthParen == 0:
      let trimmed = current.strip()
      if trimmed.len > 0:
        result.add(trimmed)
      current.setLen(0)
      continue

    case ch
    of '[':
      inc depthSquare
    of ']':
      if depthSquare > 0: dec depthSquare
    of '(':
      inc depthParen
    of ')':
      if depthParen > 0: dec depthParen
    else:
      discard
    current.add(ch)
  let trimmed = current.strip()
  if trimmed.len > 0:
    result.add(trimmed)


proc parseFunctionTypeString(str: string): EtchType =
  var s = str.strip()
  if not s.startsWith("fn"):
    return nil
  s = s[2 ..< s.len].strip()
  if s.len == 0 or s[0] != '(':
    return nil
  var depth = 0
  var closingIdx = -1
  for i in 0 ..< s.len:
    if s[i] == '(':
      inc depth
    elif s[i] == ')':
      dec depth
      if depth == 0:
        closingIdx = i
        break
  if closingIdx == -1:
    return nil
  let paramSection = s[1 ..< closingIdx]
  if closingIdx + 1 > s.len:
    return nil
  var tail = s[closingIdx + 1 ..< s.len].strip()
  if tail.len < 2 or not tail.startsWith("->"):
    return nil
  var returnSection = "void"
  if tail.len > 2:
    returnSection = tail[2 ..< tail.len].strip()
    if returnSection.len == 0:
      returnSection = "void"
  var params: seq[EtchType] = @[]
  for part in splitTopLevel(paramSection, ','):
    params.add(etchTypeFromString(part))
  let retType = etchTypeFromString(returnSection)
  return tFunction(params, retType)


proc unwrapTypeComponent(str, prefix: string): string =
  if str.len > prefix.len and str.startsWith(prefix) and str[^1] == ']':
    return str[prefix.len ..< str.len - 1].strip()
  else:
    return ""


proc etchTypeFromString*(valueName: string): EtchType =
  let trimmed = valueName.strip()
  if trimmed.len == 0:
    return tVoid()

  let lowered = trimmed.toLowerAscii()
  case lowered
  of "bool", "tkbool": return tBool()
  of "char", "tkchar": return tChar()
  of "int", "tkint": return tInt()
  of "float", "tkfloat": return tFloat()
  of "string", "tkstring": return tString()
  of "void", "tkvoid": return tVoid()
  else:
    discard

  let arrayInner = unwrapTypeComponent(trimmed, "array[")
  if arrayInner.len > 0:
    return tArray(etchTypeFromString(arrayInner))

  let refInner = unwrapTypeComponent(trimmed, "ref[")
  if refInner.len > 0:
    return tRef(etchTypeFromString(refInner))

  let weakInner = unwrapTypeComponent(trimmed, "weak[")
  if weakInner.len > 0:
    return tWeak(etchTypeFromString(weakInner))

  let optionInner = unwrapTypeComponent(trimmed, "option[")
  if optionInner.len > 0:
    return tOption(etchTypeFromString(optionInner))

  let resultInner = unwrapTypeComponent(trimmed, "result[")
  if resultInner.len > 0:
    return tResult(etchTypeFromString(resultInner))

  let coroutineInner = unwrapTypeComponent(trimmed, "coroutine[")
  if coroutineInner.len > 0:
    return tCoroutine(etchTypeFromString(coroutineInner))

  let channelInner = unwrapTypeComponent(trimmed, "channel[")
  if channelInner.len > 0:
    return tChannel(etchTypeFromString(channelInner))

  let tupleInner = unwrapTypeComponent(trimmed, "tuple[")
  if tupleInner.len > 0:
    var elems: seq[EtchType] = @[]
    for part in splitTopLevel(tupleInner, ','):
      elems.add(etchTypeFromString(part))
    return tTuple(elems)

  if trimmed.startsWith("fn"):
    let fnType = parseFunctionTypeString(trimmed)
    if fnType != nil:
      return fnType

  # Fallback to user-defined type placeholder
  return tUserDefined(trimmed)


proc `$`*(t: EtchType): string =
  if t.isNil:
    return "void"

  case t.kind
  of tkVoid: "void"
  of tkBool: "bool"
  of tkChar: "char"
  of tkInt: "int"
  of tkFloat: "float"
  of tkString: "string"
  of tkArray: "array[" & $t.inner & "]"
  of tkRef: "ref[" & $t.inner & "]"
  of tkWeak: "weak[" & $t.inner & "]"
  of tkOption: "option[" & $t.inner & "]"
  of tkResult: "result[" & $t.inner & "]"
  of tkCoroutine: "coroutine[" & $t.inner & "]"
  of tkChannel: "channel[" & $t.inner & "]"
  of tkTypeDesc: "typedesc[" & $t.inner & "]"
  of tkGeneric:
    if t.name.len > 0: t.name else: "generic"
  of tkUserDefined, tkObject, tkEnum:
    if t.name.len > 0: t.name else: $t.kind
  of tkDistinct:
    let innerRepr = $t.inner
    if t.name.len > 0:
      t.name & "(" & innerRepr & ")"
    else:
      "distinct(" & innerRepr & ")"
  of tkUnion:
    if t.unionTypes.len == 0:
      "union[]"
    else:
      var parts: seq[string] = @[]
      for ut in t.unionTypes:
        parts.add($ut)
      "union[" & parts.join(", ") & "]"
  of tkTuple:
    if t.tupleTypes.len == 0:
      "()"
    else:
      var elems: seq[string] = @[]
      for tt in t.tupleTypes:
        elems.add($tt)
      "(" & elems.join(", ") & ")"
  of tkFunction:
    var params: seq[string] = @[]
    for pt in t.funcParams:
      params.add($pt)
    let retStr = if t.funcReturn.isNil: "void" else: $t.funcReturn
    "fn(" & params.join(", ") & ") -> " & retStr
  of tkInferred: "inferred"


proc `$`*(t: ExpressionKind): string =
  case t
  of ekBool: "bool literal"
  of ekChar: "char literal"
  of ekInt: "integer literal"
  of ekFloat: "float literal"
  of ekString: "string literal"
  of ekVar: "variable reference"
  of ekBin: "binary operation"
  of ekUn: "unary operation"
  of ekCall: "function call"
  of ekNewRef: "reference new"
  of ekDeref: "dereference operation"
  of ekArray: "array literal"
  of ekIndex: "array index"
  of ekSlice: "array slice"
  of ekArrayLen: "array length"
  of ekCast: "type cast"
  of ekNil: "nil literal"
  of ekFieldAccess: "field access"
  of ekOptionSome: "option some"
  of ekOptionNone: "option none"
  of ekResultOk: "result ok"
  of ekResultErr: "result error"
  of ekResultPropagate: "result propagate"
  of ekMatch: "match expression"
  of ekObjectLiteral: "object literal"
  of ekNew: "new expression"
  of ekIf: "if expression"
  of ekComptime: "compile-time expression"
  of ekCompiles: "compiles check"
  of ekTuple: "tuple literal"
  of ekYield: "yield expression"
  of ekResume: "resume expression"
  of ekSpawn: "spawn expression"
  of ekSpawnBlock: "spawn block"
  of ekChannelNew: "channel creation"
  of ekChannelSend: "channel send"
  of ekChannelRecv: "channel receive"
  of ekLambda: "lambda expression"
  of ekTypeof: "typeof expression"


proc `$`*(t: StatementKind): string =
  case t:
  of skVar: "variable declaration"
  of skTupleUnpack: "tuple unpacking"
  of skObjectUnpack: "object unpacking"
  of skAssign: "assignment"
  of skCompoundAssign: "compound assignment"
  of skFieldAssign: "field assignment"
  of skIf: "if statement"
  of skWhile: "while loop"
  of skFor: "for loop"
  of skBreak: "break statement"
  of skExpression: "expression statement"
  of skReturn: "return statement"
  of skComptime: "comptime block"
  of skTypeDecl: "type declaration"
  of skImport: "import statement"
  of skDiscard: "discard statement"
  of skDefer: "defer block"
  of skBlock: "unnamed scope block"


proc `$`*(bop: BinOp): string =
  case bop
  of boAdd: "+"
  of boSub: "-"
  of boMul: "*"
  of boDiv: "/"
  of boMod: "%"
  of boEq: "=="
  of boNe: "!="
  of boLt: "<"
  of boLe: "<="
  of boGt: ">"
  of boGe: ">="
  of boAnd: "and"
  of boOr: "or"
  of boIn: "in"
  of boNotIn: "not in"


proc copyType*(t: EtchType): EtchType =
  case t.kind
  of tkVoid: tVoid()
  of tkBool: tBool()
  of tkChar: tChar()
  of tkInt: tInt()
  of tkFloat: tFloat()
  of tkString: tString()
  of tkArray: tArray(copyType(t.inner))
  of tkRef: tRef(copyType(t.inner))
  of tkWeak: tWeak(copyType(t.inner))
  of tkGeneric: tGeneric(t.name)
  of tkOption: tOption(copyType(t.inner))
  of tkResult: tResult(copyType(t.inner))
  of tkCoroutine: tCoroutine(copyType(t.inner))
  of tkChannel: tChannel(copyType(t.inner))
  of tkTypeDesc: tTypeDesc()
  of tkUserDefined: tUserDefined(t.name)
  of tkDistinct: tDistinct(t.name, if t.inner != nil: copyType(t.inner) else: nil)
  of tkObject: tObject(t.name, t.fields)
  of tkEnum:
    result = tEnum(t.name, t.enumMembers)
    result.enumTypeId = t.enumTypeId
    return result
  of tkInferred: tInferred()
  of tkUnion:
    var copiedTypes: seq[EtchType] = @[]
    for ut in t.unionTypes:
      copiedTypes.add(copyType(ut))
    tUnion(copiedTypes)
  of tkTuple:
    var copiedTypes: seq[EtchType] = @[]
    for tt in t.tupleTypes:
      copiedTypes.add(copyType(tt))
    tTuple(copiedTypes)
  of tkFunction:
    var copiedParams: seq[EtchType] = @[]
    for pt in t.funcParams:
      copiedParams.add(copyType(pt))
    tFunction(copiedParams, if t.funcReturn != nil: copyType(t.funcReturn) else: tVoid())


proc isCompatibleWith*(actual: EtchType, expected: EtchType): bool =
  if expected.kind == tkGeneric and expected.name == "Any":
    return true

  if expected.kind == tkUnion:
    for ut in expected.unionTypes:
      if actual.isCompatibleWith(ut):
        return true
    return false

  if actual.kind == tkUnion:
    for ut in actual.unionTypes:
      if not ut.isCompatibleWith(expected):
        return false
    return true

  if actual.kind == expected.kind:
    case actual.kind
    of tkRef, tkWeak, tkArray, tkOption, tkCoroutine, tkChannel:
      return actual.inner.isCompatibleWith(expected.inner)
    of tkResult:
      return actual.inner.isCompatibleWith(expected.inner)
    of tkTuple:
      if actual.tupleTypes.len != expected.tupleTypes.len:
        return false
      for i in 0..<actual.tupleTypes.len:
        if not actual.tupleTypes[i].isCompatibleWith(expected.tupleTypes[i]):
          return false
      return true
    of tkEnum:
      # Enums are compatible only if they are the same enum type
      return actual.name == expected.name
    of tkFunction:
      if actual.funcParams.len != expected.funcParams.len:
        return false
      for i in 0..<actual.funcParams.len:
        if not actual.funcParams[i].isCompatibleWith(expected.funcParams[i]):
          return false
      return actual.funcReturn.isCompatibleWith(expected.funcReturn)
    else:
      return true
  return false


proc addFunction*(prog: Program, funDecl: FunctionDeclaration) =
  if prog.funs.hasKey(funDecl.name):
    prog.funs[funDecl.name].add(funDecl)
  else:
    prog.funs[funDecl.name] = @[funDecl]


proc getFunctionOverloads*(prog: Program, name: string): seq[FunctionDeclaration] =
  if prog.funs.hasKey(name):
    result = prog.funs[name]
  else:
    result = @[]


proc generateOverloadSignature*(funDecl: FunctionDeclaration): string =
  ## Generate a unique signature string for overload resolution using compact name mangling
  ## Format: funcName__paramTypes_returnType
  result = funDecl.name & FUNCTION_NAME_SEPARATOR_STRING

  # Compact type encoding:
  # v=void, b=bool, c=char, i=int, f=float, s=string, X=enum, A=array, R=ref, W=weak, O=option, E=result, U=user-defined, D=distinct, T=object, N=union, P=tuple, Y=async, C=channel
  proc encodeType(t: EtchType): string =
    case t.kind
    of tkVoid: return "v"
    of tkBool: return "b"
    of tkChar: return "c"
    of tkInt: return "i"
    of tkFloat: return "f"
    of tkString: return "s"
    of tkArray: return "A" & encodeType(t.inner)
    of tkRef: return "R" & encodeType(t.inner)
    of tkWeak: return "W" & encodeType(t.inner)
    of tkGeneric: return "G" & $t.name.len & t.name
    of tkOption: return "O" & encodeType(t.inner)
    of tkResult: return "E" & encodeType(t.inner)
    of tkCoroutine: return "Y" & encodeType(t.inner)
    of tkChannel: return "C" & encodeType(t.inner)
    of tkTypeDesc: return "Z"  # Z for typedesc
    of tkUserDefined: return "U" & $t.name.len & t.name
    of tkDistinct: return "D" & $t.name.len & t.name
    of tkObject: return "T" & $t.name.len & t.name
    of tkEnum: return "X" & $t.name.len & t.name  # X for enum
    of tkInferred: return "I" # Inferred type (shouldn't appear in function signatures)
    of tkUnion:
      result = "N" & $t.unionTypes.len
      for ut in t.unionTypes:
        result.add(encodeType(ut))
    of tkTuple:
      result = "P" & $t.tupleTypes.len
      for tt in t.tupleTypes:
        result.add(encodeType(tt))
    of tkFunction:
      result = "L" & $t.funcParams.len
      for pt in t.funcParams:
        result.add(encodeType(pt))
      result.add(encodeType(t.funcReturn))

  for param in funDecl.params:
    result.add(encodeType(param.typ))

  result.add(FUNCTION_RETURN_SEPARATOR_STRING)
  if funDecl.ret != nil:
    result.add(encodeType(funDecl.ret))
  else:
    result.add("v")


proc functionNameFromSignature*(mangledName: string): string =
  if FUNCTION_NAME_SEPARATOR_STRING notin mangledName:
    result = mangledName  # Not mangled, return as-is
  else:
    result = mangledName.split(FUNCTION_NAME_SEPARATOR_STRING)[0]


proc decodeNamedType(typeName: string, encoded: string, pos: var int): string =
  if pos >= encoded.len:
    return typeName
  var lenStr = ""
  while pos < encoded.len and encoded[pos].isDigit:
    lenStr.add(encoded[pos])
    pos += 1
  if lenStr.len == 0:
    return typeName
  let nameLen = parseInt(lenStr)
  if pos + nameLen > encoded.len:
    return typeName
  let name = encoded[pos..<pos + nameLen]
  pos += nameLen
  name


proc demangleFunctionSignature*(mangledName: string): string =
  if FUNCTION_NAME_SEPARATOR_STRING notin mangledName:
    return mangledName

  let parts = mangledName.split(FUNCTION_NAME_SEPARATOR_STRING)
  if parts.len != 2:
    return mangledName

  let funcName = parts[0]
  let signature = parts[1]

  if FUNCTION_RETURN_SEPARATOR_STRING notin signature:
    return mangledName

  let sigParts = signature.split(FUNCTION_RETURN_SEPARATOR_STRING)
  if sigParts.len != 2:
    return mangledName

  let paramTypes = sigParts[0]
  let returnType = sigParts[1]

  proc decodeType(encoded: string, pos: var int): string =
    if pos >= encoded.len:
      return "?"

    let c = encoded[pos]
    pos += 1

    case c
    of 'v': "void"
    of 'b': "bool"
    of 'c': "char"
    of 'i': "int"
    of 'f': "float"
    of 's': "string"
    of 'A': "array[" & decodeType(encoded, pos) & "]"
    of 'R': "ref " & decodeType(encoded, pos)
    of 'O': "option[" & decodeType(encoded, pos) & "]"
    of 'E': "result[" & decodeType(encoded, pos) & "]"
    of 'Z': "typedesc"
    of 'C': "channel[" & decodeType(encoded, pos) & "]"
    of 'N':
      # Union type: N<count><type1><type2>...
      if pos >= encoded.len:
        return "union"
      var countStr = ""
      while pos < encoded.len and encoded[pos].isDigit:
        countStr.add(encoded[pos])
        pos += 1
      if countStr.len == 0:
        return "union"
      let typeCount = parseInt(countStr)
      var types: seq[string] = @[]
      for i in 0..<typeCount:
        types.add(decodeType(encoded, pos))
      types.join(" | ")
    of 'P':
      # Tuple type: P<count><type1><type2>...
      if pos >= encoded.len:
        return "tuple"
      var countStr = ""
      while pos < encoded.len and encoded[pos].isDigit:
        countStr.add(encoded[pos])
        pos += 1
      if countStr.len == 0:
        return "tuple"
      let typeCount = parseInt(countStr)
      var types: seq[string] = @[]
      for i in 0..<typeCount:
        types.add(decodeType(encoded, pos))
      "tuple[" & types.join(", ") & "]"
    of 'U', 'D', 'T', 'X', 'G':
      # User-defined, distinct, object, enum or generic type: <letter><length><name>
      decodeNamedType(
        if c == 'U': "user-defined"
        elif c == 'D': "distinct"
        elif c == 'T': "object"
        elif c == 'X': "enum"
        else: "generic",
        encoded,
        pos)
    of 'L':
      if pos >= encoded.len:
        return "fn() -> void"
      var countStr = ""
      while pos < encoded.len and encoded[pos].isDigit:
        countStr.add(encoded[pos])
        pos += 1
      if countStr.len == 0:
        return "fn() -> void"
      let paramCount = parseInt(countStr)
      var params: seq[string] = @[]
      for i in 0..<paramCount:
        params.add(decodeType(encoded, pos))
      let retType = decodeType(encoded, pos)
      "fn(" & params.join(", ") & ") -> " & retType
    else: "unknown"

  proc decodeAllTypes(encoded: string): seq[string] =
    var pos = 0
    var types: seq[string] = @[]
    while pos < encoded.len:
      types.add(decodeType(encoded, pos))
    types

  let params = decodeAllTypes(paramTypes)
  let retTypeStr = decodeAllTypes(returnType)[0]

  if params.len == 0:
    return funcName & "() -> " & retTypeStr
  else:
    return funcName & "(" & params.join(", ") & ") -> " & retTypeStr
