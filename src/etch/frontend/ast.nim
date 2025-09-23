# ast.nim
# Core AST + type for Etch


import std/[tables, options, strutils]


const
  AST_VERSION* = 2


type
  Pos* = object
    line*, col*: int
    filename*: string

  TypeKind* = enum
    tkInt, tkFloat, tkString, tkChar, tkBool, tkVoid, tkRef, tkGeneric, tkArray, tkOption, tkResult

  EtchType* = ref object
    kind*: TypeKind
    name*: string           # for tkGeneric
    inner*: EtchType        # for tkRef and tkArray

  TypeEnv* = Table[string, EtchType]

  # Generic parameter: name
  TyParam* = object
    name*: string
    koncept*: Option[string]

  BinOp* = enum
    boAdd, boSub, boMul, boDiv, boMod,
    boEq, boNe, boLt, boLe, boGt, boGe,
    boAnd, boOr

  UnOp* = enum uoNot, uoNeg

  PatternKind* = enum
    pkSome, pkNone, pkOk, pkErr, pkWildcard

  Pattern* = ref object
    case kind*: PatternKind
    of pkSome, pkOk, pkErr:
      bindName*: string  # variable name to bind the extracted value
    of pkNone, pkWildcard:
      discard

  MatchCase* = object
    pattern*: Pattern
    body*: seq[Stmt]  # statements to execute if pattern matches

  ExprKind* = enum
    ekBool, ekChar, ekInt, ekFloat, ekString, ekVar, ekBin, ekUn,
    ekCall, ekNewRef, ekDeref, ekArray, ekIndex, ekSlice, ekArrayLen, ekCast, ekNil,
    ekOptionSome, ekOptionNone, ekResultOk, ekResultErr, ekMatch

  Expr* = ref object
    pos*: Pos
    typ*: EtchType
    case kind*: ExprKind
    of ekInt:
      ival*: int64
    of ekFloat:
      fval*: float64
    of ekString:
      sval*: string
    of ekChar:
      cval*: char
    of ekBool:
      bval*: bool
    of ekVar:
      vname*: string
    of ekUn:
      uop*: UnOp
      ue*: Expr
    of ekBin:
      bop*: BinOp
      lhs*, rhs*: Expr
    of ekCall:
      fname*: string
      args*: seq[Expr]
      instTypes*: seq[EtchType]
    of ekNewRef:
      init*: Expr
      refInner*: EtchType
    of ekDeref:
      refExpr*: Expr
    of ekArray:
      elements*: seq[Expr]
    of ekIndex:
      arrayExpr*: Expr
      indexExpr*: Expr
    of ekSlice:
      sliceExpr*: Expr
      startExpr*: Option[Expr]
      endExpr*: Option[Expr]
    of ekArrayLen:
      lenExpr*: Expr
    of ekCast:
      castType*: EtchType
      castExpr*: Expr
    of ekNil:
      discard
    of ekOptionSome:
      someExpr*: Expr
    of ekOptionNone:
      discard
    of ekResultOk:
      okExpr*: Expr
    of ekResultErr:
      errExpr*: Expr
    of ekMatch:
      matchExpr*: Expr        # expression to match against
      cases*: seq[MatchCase]  # pattern cases

  StmtKind* = enum
    skVar, skAssign, skIf, skWhile, skFor, skBreak, skExpr, skReturn, skComptime

  VarFlag* = enum
    vfLet, vfVar

  Stmt* = ref object
    pos*: Pos
    case kind*: StmtKind
    of skVar:
      vflag*: VarFlag
      vname*: string
      vtype*: EtchType
      vinit*: Option[Expr]
    of skAssign:
      aname*: string
      aval*: Expr
    of skIf:
      cond*: Expr
      thenBody*: seq[Stmt]
      elifChain*: seq[tuple[cond: Expr, body: seq[Stmt]]]
      elseBody*: seq[Stmt]
    of skWhile:
      wcond*: Expr
      wbody*: seq[Stmt]
    of skFor:
      fvar*: string
      fstart*: Option[Expr]   # None for array iteration
      fend*: Option[Expr]     # None for array iteration
      farray*: Option[Expr]   # Some for array iteration
      finclusive*: bool       # true for .., false for ..<
      fbody*: seq[Stmt]
    of skExpr:
      sexpr*: Expr
    of skReturn:
      re*: Option[Expr]
    of skComptime:
      cbody*: seq[Stmt]
    of skBreak:
      discard

  Param* = object
    name*: string
    typ*: EtchType
    defaultValue*: Option[Expr]

  FunDecl* = ref object
    name*: string
    typarams*: seq[TyParam]
    params*: seq[Param]
    ret*: EtchType
    body*: seq[Stmt]

  Program* = ref object
    globals*: seq[Stmt]                   # global let/var with init allowed
    funs*: Table[string, seq[FunDecl]]    # generic templates (supports overloads)
    funInstances*: Table[string, FunDecl] # monomorphized instances


proc tVoid*(): EtchType = EtchType(kind: tkVoid)
proc tBool*(): EtchType = EtchType(kind: tkBool)
proc tChar*(): EtchType = EtchType(kind: tkChar)
proc tInt*(): EtchType = EtchType(kind: tkInt)
proc tFloat*(): EtchType = EtchType(kind: tkFloat)
proc tString*(): EtchType = EtchType(kind: tkString)
proc tArray*(inner: EtchType): EtchType = EtchType(kind: tkArray, inner: inner)
proc tRef*(inner: EtchType): EtchType = EtchType(kind: tkRef, inner: inner)
proc tGeneric*(name: string): EtchType = EtchType(kind: tkGeneric, name: name)
proc tOption*(inner: EtchType): EtchType = EtchType(kind: tkOption, inner: inner)
proc tResult*(inner: EtchType): EtchType = EtchType(kind: tkResult, inner: inner)


proc `$`*(t: EtchType): string =
  case t.kind
  of tkVoid: "void"
  of tkBool: "bool"
  of tkChar: "char"
  of tkInt: "int"
  of tkFloat: "float"
  of tkString: "string"
  of tkArray: "array[" & $t.inner & "]"
  of tkRef: "ref[" & $t.inner & "]"
  of tkGeneric: t.name
  of tkOption: "option[" & $t.inner & "]"
  of tkResult: "result[" & $t.inner & "]"


proc `$`*(t: ExprKind): string =
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
  else: "unknown kind"


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
  of tkGeneric: tGeneric(t.name)
  of tkOption: tOption(copyType(t.inner))
  of tkResult: tResult(copyType(t.inner))


# Function overload management helpers
proc addFunction*(prog: Program, funDecl: FunDecl) =
  ## Add a function declaration, supporting overloads
  if prog.funs.hasKey(funDecl.name):
    prog.funs[funDecl.name].add(funDecl)
  else:
    prog.funs[funDecl.name] = @[funDecl]


proc getFunctionOverloads*(prog: Program, name: string): seq[FunDecl] =
  ## Get all overloads for a function name
  if prog.funs.hasKey(name):
    result = prog.funs[name]
  else:
    result = @[]


proc generateOverloadSignature*(funDecl: FunDecl): string =
  ## Generate a unique signature string for overload resolution using compact name mangling
  ## Format: funcName__paramTypes_returnType (inspired by JNI/C++ mangling but simplified)
  result = funDecl.name & "__"

  # Compact type encoding: v=void, b=bool, c=char, i=int, f=float, s=string, A=array, R=ref, O=option, E=result
  proc encodeType(t: EtchType): string =
    case t.kind
    of tkVoid: "v"
    of tkBool: "b"
    of tkChar: "c"
    of tkInt: "i"
    of tkFloat: "f"
    of tkString: "s"
    of tkArray: "A" & encodeType(t.inner)
    of tkRef: "R" & encodeType(t.inner)
    of tkGeneric: "G" & $t.name.len & t.name
    of tkOption: "O" & encodeType(t.inner)
    of tkResult: "E" & encodeType(t.inner)

  # Encode parameters
  for param in funDecl.params:
    result.add(encodeType(param.typ))

  # Add return type separator and return type
  result.add("_")
  if funDecl.ret != nil:
    result.add(encodeType(funDecl.ret))
  else:
    result.add("v")


proc functionNameFromSignature*(mangledName: string): string =
  if "__" notin mangledName:
    result = mangledName  # Not mangled, return as-is
  else:
    result = mangledName.split("__")[0]


proc demangleFunctionSignature*(mangledName: string): string =
  ## Demangle function signatures from their internal representation to human-readable form
  ## Format: funcName__paramTypes_returnType -> funcName(paramTypes) -> returnType
  if "__" notin mangledName:
    return mangledName  # Not mangled, return as-is

  let parts = mangledName.split("__")
  if parts.len != 2:
    return mangledName  # Invalid format, return as-is

  let funcName = parts[0]
  let signature = parts[1]

  if "_" notin signature:
    return mangledName  # Invalid format, return as-is

  let sigParts = signature.split("_")
  if sigParts.len != 2:
    return mangledName  # Invalid format, return as-is

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
    of 'G':
      # Generic type: G<length><name>
      if pos >= encoded.len:
        return "generic"
      var lenStr = ""
      while pos < encoded.len and encoded[pos].isDigit:
        lenStr.add(encoded[pos])
        pos += 1
      if lenStr.len == 0:
        return "generic"
      let nameLen = parseInt(lenStr)
      if pos + nameLen > encoded.len:
        return "generic"
      let name = encoded[pos..<pos + nameLen]
      pos += nameLen
      name
    else: "unknown"

  proc decodeAllTypes(encoded: string): seq[string] =
    var pos = 0
    var types: seq[string] = @[]
    while pos < encoded.len:
      types.add(decodeType(encoded, pos))
    types

  let params = decodeAllTypes(paramTypes)
  let retTypeStr = if returnType == "v": "void" else: decodeAllTypes(returnType)[0]

  if params.len == 0:
    return funcName & "() -> " & retTypeStr
  else:
    return funcName & "(" & params.join(", ") & ") -> " & retTypeStr
