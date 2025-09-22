# ast.nim
# Core AST + type for Etch

import std/[tables, options]

type
  Pos* = object
    line*, col*: int
    filename*: string

  TypeKind* = enum
    tkInt, tkFloat, tkString, tkChar, tkBool, tkVoid, tkRef, tkGeneric, tkArray

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

  ExprKind* = enum
    ekInt, ekFloat, ekString, ekChar, ekBool, ekVar, ekBin, ekUn,
    ekCall, ekNewRef, ekDeref, ekArray, ekIndex, ekSlice, ekArrayLen, ekCast, ekNil

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

  # Compact type encoding: v=void, b=bool, c=char, i=int, f=float, s=string, A=array, R=ref
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

  # Encode parameters
  for param in funDecl.params:
    result.add(encodeType(param.typ))

  # Add return type separator and return type
  result.add("_")
  if funDecl.ret != nil:
    result.add(encodeType(funDecl.ret))
  else:
    result.add("v")
