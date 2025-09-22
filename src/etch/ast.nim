# ast.nim
# Core AST + type and concept model for Etch

import std/[tables, options]

type
  Pos* = object
    line*, col*: int
    filename*: string

  TypeKind* = enum tkInt, tkFloat, tkString, tkBool, tkVoid, tkRef, tkGeneric, tkArray
  EtchType* = ref object
    kind*: TypeKind
    name*: string           # for tkGeneric
    inner*: EtchType        # for tkRef and tkArray
  TypeEnv* = Table[string, EtchType]

  ConceptReq* = enum crAdd, crDiv, crCmp, crDeref
  Concept* = ref object
    name*: string
    reqs*: set[ConceptReq]

  # Generic parameter: name with optional concept
  TyParam* = object
    name*: string
    koncept*: Option[string]

  BinOp* = enum
    boAdd, boSub, boMul, boDiv, boMod,
    boEq, boNe, boLt, boLe, boGt, boGe,
    boAnd, boOr

  UnOp* = enum uoNot, uoNeg

  ExprKind* = enum
    ekInt, ekFloat, ekString, ekBool, ekVar, ekBin, ekUn,
    ekCall, ekNewRef, ekDeref, ekArray, ekIndex, ekSlice, ekArrayLen, ekCast, ekNil

  Expr* = ref object
    pos*: Pos
    typ*: EtchType
    case kind*: ExprKind
    of ekInt:    ival*: int64
    of ekFloat:  fval*: float64
    of ekString: sval*: string
    of ekBool:   bval*: bool
    of ekNil:    discard  # nil needs no additional fields
    of ekVar:    vname*: string
    of ekUn:
      uop*: UnOp
      ue*: Expr
    of ekBin:
      bop*: BinOp
      lhs*, rhs*: Expr
    of ekCall:
      fname*: string
      args*: seq[Expr]
      instTypes*: seq[EtchType]   # monomorphized type args (filled by typer)
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
      startExpr*: Option[Expr]  # None means start from 0
      endExpr*: Option[Expr]    # None means until end
    of ekArrayLen:
      lenExpr*: Expr  # Expression that should evaluate to an array
    of ekCast:
      castType*: EtchType  # Target type to cast to
      castExpr*: Expr      # Expression to cast

  StmtKind* = enum skVar, skAssign, skIf, skWhile, skExpr, skReturn, skComptime
  VarFlag* = enum vfLet, vfVar

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
    of skExpr:
      sexpr*: Expr
    of skReturn:
      re*: Option[Expr]
    of skComptime:
      cbody*: seq[Stmt]

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
    concepts*: Table[string, Concept]
    globals*: seq[Stmt]   # global let/var with init allowed
    funs*: Table[string, FunDecl]    # generic templates
    funInstances*: Table[string, FunDecl] # monomorphized instances

proc tInt*(): EtchType = EtchType(kind: tkInt)
proc tFloat*(): EtchType = EtchType(kind: tkFloat)
proc tString*(): EtchType = EtchType(kind: tkString)
proc tBool*(): EtchType = EtchType(kind: tkBool)
proc tVoid*(): EtchType = EtchType(kind: tkVoid)
proc tRef*(inner: EtchType): EtchType = EtchType(kind: tkRef, inner: inner)
proc tGeneric*(name: string): EtchType = EtchType(kind: tkGeneric, name: name)
proc tArray*(inner: EtchType): EtchType = EtchType(kind: tkArray, inner: inner)

proc `$`*(t: EtchType): string =
  case t.kind
  of tkInt: "int"
  of tkFloat: "float"
  of tkString: "string"
  of tkBool: "bool"
  of tkVoid: "void"
  of tkRef: "Ref[" & $t.inner & "]"
  of tkGeneric: t.name
  of tkArray: "array[" & $t.inner & "]"

proc copyType*(t: EtchType): EtchType =
  case t.kind
  of tkRef: tRef(copyType(t.inner))
  of tkGeneric: tGeneric(t.name)
  of tkArray: tArray(copyType(t.inner))
  of tkInt: tInt()
  of tkFloat: tFloat()
  of tkString: tString()
  of tkBool: tBool()
  of tkVoid: tVoid()

proc conceptAdd*(): Concept =
  Concept(name: "Addable", reqs: {crAdd})
proc conceptDiv*(): Concept =
  Concept(name: "Divisible", reqs: {crDiv})
proc conceptCmp*(): Concept =
  Concept(name: "Comparable", reqs: {crCmp})
proc conceptDeref*(): Concept =
  Concept(name: "Derefable", reqs: {crDeref})
