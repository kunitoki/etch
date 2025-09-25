# parser.nim
# Pratt parser for Etch using tokens from lexer

import std/[strformat, tables, options, strutils]
import ast, lexer, ../common/[errors, types], ../typechecker/core

type
  Parser* = ref object
    toks*: seq[Token]
    i*: int
    filename*: string
    genericParams*: seq[string]  # Track generic type parameters in current scope

proc posOf(p: Parser, t: Token): Pos = Pos(line: t.line, col: t.col, filename: p.filename)

proc friendlyTokenName(kind: TokKind, lex: string): string =
  case kind
  of tkBool: return &"boolean '{lex}'"
  of tkChar: return &"char '{lex}'"
  of tkInt: return &"number '{lex}'"
  of tkFloat: return &"number '{lex}'"
  of tkString: return &"string \"{lex}\""
  of tkIdent: return &"identifier '{lex}'"
  of tkKeyword: return &"keyword '{lex}'"
  of tkSymbol: return &"symbol '{lex}'"
  of tkEof: return "end of file"

proc cur(p: Parser): Token = p.toks[p.i]
proc peek(p: Parser, k=1): Token = p.toks[min(p.i+k, p.toks.high)]
proc eat(p: Parser): Token = (result = p.toks[p.i]; inc p.i)
proc expect(p: Parser, kind: TokKind, lex: string = ""): Token =
  let t = p.cur
  if t.kind != kind or (lex.len>0 and t.lex != lex):
    let expectedName = friendlyTokenName(kind, lex)
    let actualName = friendlyTokenName(t.kind, t.lex)
    raise newParseError(p.posOf(t), &"expected {expectedName}, got {actualName}")
  inc p.i
  t

# Forward declarations
proc parseExpr*(p: Parser; rbp=0): Expr
proc parseStmt*(p: Parser): Stmt
proc parseMatchExpr(p: Parser; t: Token): Expr
proc parsePattern(p: Parser): Pattern
proc parseBlock(p: Parser): seq[Stmt]

# --- Type parsing ---
proc parseType(p: Parser): EtchType =
  let t = p.cur
  if t.kind in {tkKeyword, tkIdent}:
    if t.lex == "int": discard p.eat; return tInt()
    if t.lex == "float": discard p.eat; return tFloat()
    if t.lex == "string": discard p.eat; return tString()
    if t.lex == "char": discard p.eat; return tChar()
    if t.lex == "bool": discard p.eat; return tBool()
    if t.lex == "void": discard p.eat; return tVoid()
    if t.lex == "ref":
      discard p.expect(tkKeyword, "ref")
      discard p.expect(tkSymbol, "[")
      let inner = p.parseType()
      discard p.expect(tkSymbol, "]")
      return tRef(inner)
    if t.lex == "array":
      discard p.expect(tkKeyword, "array")
      discard p.expect(tkSymbol, "[")
      let inner = p.parseType()
      discard p.expect(tkSymbol, "]")
      return tArray(inner)
    if t.lex == "option":
      discard p.expect(tkKeyword, "option")
      discard p.expect(tkSymbol, "[")
      let inner = p.parseType()
      discard p.expect(tkSymbol, "]")
      return tOption(inner)
    if t.lex == "result":
      discard p.expect(tkIdent, "result")
      discard p.expect(tkSymbol, "[")
      let inner = p.parseType()
      discard p.expect(tkSymbol, "]")
      return tResult(inner)
    # Check if it's a generic type parameter
    if t.lex in p.genericParams:
      discard p.eat
      return tGeneric(t.lex)
    # user-defined type name (could be alias, distinct, or object)
    discard p.eat
    return tUserDefined(t.lex)
  let actualName = friendlyTokenName(t.kind, t.lex)
  raise newParseError(p.posOf(t), &"expected type, got {actualName}")

# --- Expression Pratt parser ---
proc getOperatorPrecedence(op: string): int =
  ## Returns the left binding power (precedence) of an operator
  case op
  of "or": 1
  of "and": 2
  of "==","!=": 3
  of "<",">","<=",">=": 4
  of "+","-": 5
  of "*","/","%": 6
  of "@": 9  # deref has very high precedence, higher than field access
  of "[": 8  # array indexing/slicing has high precedence
  of ".": 7  # field access and UFCS method calls
  else: 0

proc binOp(op: string): BinOp =
  case op
  of "+": boAdd
  of "-": boSub
  of "*": boMul
  of "/": boDiv
  of "%": boMod
  of "==": boEq
  of "!=": boNe
  of "<": boLt
  of "<=": boLe
  of ">": boGt
  of ">=": boGe
  of "and": boAnd
  of "or": boOr
  else: raise newEtchError("unknown operator: " & op)

proc parseLiteralExpr(p: Parser; t: Token): Expr =
  ## Parses literal expressions (int, float, string, char, bool)
  case t.kind
  of tkInt:
    return Expr(kind: ekInt, ival: parseInt(t.lex), pos: p.posOf(t))
  of tkFloat:
    return Expr(kind: ekFloat, fval: parseFloat(t.lex), pos: p.posOf(t))
  of tkString:
    return Expr(kind: ekString, sval: t.lex, pos: p.posOf(t))
  of tkChar:
    return Expr(kind: ekChar, cval: t.lex[0], pos: p.posOf(t))
  of tkBool:
    return Expr(kind: ekBool, bval: t.lex == "true", pos: p.posOf(t))
  else:
    raise newEtchError("not a literal token")

proc parseBuiltinKeywordExpr(p: Parser; t: Token): Expr =
  ## Parses built-in keyword expressions (true, false, nil, new)
  case t.lex
  of "true": return Expr(kind: ekBool, bval: true, pos: p.posOf(t))
  of "false": return Expr(kind: ekBool, bval: false, pos: p.posOf(t))
  of "nil": return Expr(kind: ekNil, pos: p.posOf(t))
  of "new":
    # Check for new[Type] or new[Type]{value} syntax
    if p.cur.kind == tkSymbol and p.cur.lex == "[":
      discard p.eat()  # consume "["
      let typeExpr = p.parseType()  # Parse the type
      discard p.expect(tkSymbol, "]")

      var initExpr = none(Expr)
      # Check for optional {value} initialization
      if p.cur.kind == tkSymbol and p.cur.lex == "{":
        # Let parseExpr handle the entire object literal including the braces
        initExpr = some(p.parseExpr())

      return Expr(kind: ekNew, newType: typeExpr, initExpr: initExpr, pos: p.posOf(t))
    else:
      # Old syntax: new(value) - infer type from value
      discard p.expect(tkSymbol, "(")
      let valueExpr = p.parseExpr()
      discard p.expect(tkSymbol, ")")

      # Create new expression with type inference marker
      return Expr(kind: ekNew, newType: nil, initExpr: some(valueExpr), pos: p.posOf(t))
  of "some":
    discard p.expect(tkSymbol, "(")
    let e = p.parseExpr()
    discard p.expect(tkSymbol, ")")
    return Expr(kind: ekOptionSome, someExpr: e, pos: p.posOf(t))
  of "none":
    return Expr(kind: ekOptionNone, pos: p.posOf(t))
  of "ok":
    discard p.expect(tkSymbol, "(")
    let e = p.parseExpr()
    discard p.expect(tkSymbol, ")")
    return Expr(kind: ekResultOk, okExpr: e, pos: p.posOf(t))
  of "error":
    discard p.expect(tkSymbol, "(")
    let e = p.parseExpr()
    discard p.expect(tkSymbol, ")")
    return Expr(kind: ekResultErr, errExpr: e, pos: p.posOf(t))
  of "match":
    return p.parseMatchExpr(t)
  else:
    # Allow keyword names as identifiers for simplicity except reserved control words
    return Expr(kind: ekVar, vname: t.lex, pos: p.posOf(t))

proc parseMatchExpr(p: Parser; t: Token): Expr =
  ## Parses match expressions: match expr { pattern => body, ... }
  let matchExpr = p.parseExpr()
  discard p.expect(tkSymbol, "{")

  var cases: seq[MatchCase] = @[]

  while p.cur.kind != tkSymbol or p.cur.lex != "}":
    # Parse pattern
    let pattern = p.parsePattern()
    discard p.expect(tkSymbol, "=>")

    # Parse body: either { block } or single expression
    let body =
      if p.cur.kind == tkSymbol and p.cur.lex == "{":
        # Full block with braces
        p.parseBlock()
      else:
        # Single expression - wrap in statement sequence
        let expr = p.parseExpr()
        @[Stmt(kind: skExpr, sexpr: expr, pos: expr.pos)]
    cases.add(MatchCase(pattern: pattern, body: body))

    # Skip optional comma or semicolon
    if p.cur.kind == tkSymbol and (p.cur.lex == "," or p.cur.lex == ";"):
      discard p.eat()

  discard p.expect(tkSymbol, "}")
  return Expr(kind: ekMatch, matchExpr: matchExpr, cases: cases, pos: p.posOf(t))

proc parsePattern(p: Parser): Pattern =
  ## Parses match patterns: some(x), none, ok(x), error(x), _
  let t = p.eat()
  case t.lex
  of "some":
    discard p.expect(tkSymbol, "(")
    let bindName = p.expect(tkIdent).lex
    discard p.expect(tkSymbol, ")")
    return Pattern(kind: pkSome, bindName: bindName)
  of "none":
    return Pattern(kind: pkNone)
  of "ok":
    discard p.expect(tkSymbol, "(")
    let bindName = p.expect(tkIdent).lex
    discard p.expect(tkSymbol, ")")
    return Pattern(kind: pkOk, bindName: bindName)
  of "error":
    discard p.expect(tkSymbol, "(")
    let bindName = p.expect(tkIdent).lex
    discard p.expect(tkSymbol, ")")
    return Pattern(kind: pkErr, bindName: bindName)
  of "_":
    return Pattern(kind: pkWildcard)
  else:
    raise newParseError(p.posOf(t), "expected pattern (some, none, ok, error, or _)")

proc parseCastExpr(p: Parser; t: Token): Expr =
  ## Parses cast expressions: type(expr)
  discard p.eat() # consume (
  if p.cur.kind == tkSymbol and p.cur.lex == ")":
    raise newParseError(p.posOf(t), "cast expression cannot be empty")

  let castExpr = p.parseExpr()
  discard p.expect(tkSymbol, ")")
  let castType = case t.lex:
    of "bool": tBool()
    of "char": tChar()
    of "int": tInt()
    of "float": tFloat()
    of "string": tString()
    else: raise newParseError(p.posOf(t), "unknown cast type")
  return Expr(kind: ekCast, castType: castType, castExpr: castExpr, pos: p.posOf(t))

proc parseFunctionCallExpr(p: Parser; t: Token): Expr =
  ## Parses function call expressions: func(arg1, arg2, ...)
  var args: seq[Expr] = @[]
  discard p.eat() # consume (
  if not (p.cur.kind == tkSymbol and p.cur.lex == ")"):
    args.add p.parseExpr()
    while p.cur.kind == tkSymbol and p.cur.lex == ",":
      discard p.eat()
      args.add p.parseExpr()
  discard p.expect(tkSymbol, ")")
  return Expr(kind: ekCall, fname: t.lex, args: args, pos: p.posOf(t))

proc parseIdentifierExpr(p: Parser; t: Token): Expr =
  ## Parses identifier expressions (variables, function calls, or casts)
  if p.cur.kind == tkSymbol and p.cur.lex == "(":
    # Check if this is a cast (built-in type name)
    if t.lex in ["bool", "char", "int", "float", "string"]:
      return p.parseCastExpr(t)
    else:
      return p.parseFunctionCallExpr(t)
  else:
    return Expr(kind: ekVar, vname: t.lex, pos: p.posOf(t))

proc parseSymbolExpr(p: Parser; t: Token): Expr =
  ## Parses symbol expressions (parentheses, arrays, unary operators)
  case t.lex
  of "(":
    let e = p.parseExpr()
    discard p.expect(tkSymbol, ")")
    return e
  of "[":
    # Array literal: [expr1, expr2, ...]
    var elements: seq[Expr] = @[]
    if not (p.cur.kind == tkSymbol and p.cur.lex == "]"):
      elements.add p.parseExpr()
      while p.cur.kind == tkSymbol and p.cur.lex == ",":
        discard p.eat()
        elements.add p.parseExpr()
    discard p.expect(tkSymbol, "]")
    return Expr(kind: ekArray, elements: elements, pos: p.posOf(t))
  of "-":
    let e = p.parseExpr(6) # highest prefix binding
    return Expr(kind: ekUn, uop: uoNeg, ue: e, pos: p.posOf(t))
  of "!":
    let e = p.parseExpr(6)
    return Expr(kind: ekUn, uop: uoNot, ue: e, pos: p.posOf(t))
  of "@":
    let e = p.parseExpr(100)  # Maximum precedence
    return Expr(kind: ekDeref, refExpr: e, pos: p.posOf(t))
  of "#":
    let e = p.parseExpr(6)
    return Expr(kind: ekArrayLen, lenExpr: e, pos: p.posOf(t))
  of "{":
    # Object literal: { field1: expr1, field2: expr2 }
    var fieldInits: seq[tuple[name: string, value: Expr]] = @[]
    if not (p.cur.kind == tkSymbol and p.cur.lex == "}"):
      while true:
        let fieldName = p.expect(tkIdent).lex
        discard p.expect(tkSymbol, ":")
        let fieldValue = p.parseExpr()
        fieldInits.add((name: fieldName, value: fieldValue))

        if p.cur.kind == tkSymbol and p.cur.lex == ",":
          discard p.eat()
        elif p.cur.kind == tkSymbol and p.cur.lex == "}":
          break
        else:
          let current = p.cur
          let actualName = friendlyTokenName(current.kind, current.lex)
          raise newParseError(p.posOf(current), &"expected ',' or '}}', got {actualName}")
    discard p.expect(tkSymbol, "}")
    # Object type will be inferred during type checking
    return Expr(kind: ekObjectLiteral, objectType: nil, fieldInits: fieldInits, pos: p.posOf(t))
  else:
    let actualName = friendlyTokenName(t.kind, t.lex)
    raise newEtchError(&"unexpected {actualName}")

proc parseAtomicExpr(p: Parser): Expr =
  ## Parses atomic expressions (null denotation - expressions that don't need a left operand)
  let t = p.eat()
  case t.kind
  of tkInt, tkFloat, tkString, tkChar, tkBool:
    return p.parseLiteralExpr(t)
  of tkKeyword:
    if t.lex in ["int", "float", "string", "char", "bool"] and p.cur.kind == tkSymbol and p.cur.lex == "(":
      return p.parseCastExpr(t)
    else:
      return p.parseBuiltinKeywordExpr(t)
  of tkIdent:
    return p.parseIdentifierExpr(t)
  of tkSymbol:
    return p.parseSymbolExpr(t)
  of tkEof:
    raise newParseError(Pos(line: t.line, col: t.col), "unexpected end of input")

proc parseArrayAccessOrSlice(p: Parser; left: Expr; t: Token): Expr =
  ## Parses array indexing or slicing: expr[index] or expr[start:end] or expr[:end]
  if p.cur.kind == tkSymbol and p.cur.lex == ":":
    # Slicing from start: expr[:end]
    discard p.eat()  # consume ":"
    let endExpr = if p.cur.kind == tkSymbol and p.cur.lex == "]":
                    none(Expr)
                  else:
                    some(p.parseExpr())
    discard p.expect(tkSymbol, "]")
    return Expr(kind: ekSlice, sliceExpr: left, startExpr: none(Expr), endExpr: endExpr, pos: p.posOf(t))
  else:
    let firstExpr = p.parseExpr()
    if p.cur.kind == tkSymbol and p.cur.lex == ":":
      # Slicing: expr[start:end]
      discard p.eat()  # consume ":"
      let endExpr = if p.cur.kind == tkSymbol and p.cur.lex == "]":
                      none(Expr)
                    else:
                      some(p.parseExpr())
      discard p.expect(tkSymbol, "]")
      return Expr(kind: ekSlice, sliceExpr: left, startExpr: some(firstExpr), endExpr: endExpr, pos: p.posOf(t))
    else:
      # Simple indexing: expr[index]
      discard p.expect(tkSymbol, "]")
      return Expr(kind: ekIndex, arrayExpr: left, indexExpr: firstExpr, pos: p.posOf(t))

proc parseUFCSCall(p: Parser; obj: Expr; t: Token): Expr =
  ## Parses UFCS method calls: obj.method() or field access: obj.field
  let fieldOrMethodName = p.expect(tkIdent).lex

  # Check if followed by parentheses (method call) or not (field access)
  if p.cur.kind == tkSymbol and p.cur.lex == "(":
    # Method call: obj.method(args...)
    # Transform into method(obj, args...)
    var args: seq[Expr] = @[obj]  # object becomes first argument
    discard p.eat()  # consume "("
    if not (p.cur.kind == tkSymbol and p.cur.lex == ")"):
      args.add p.parseExpr()
      while p.cur.kind == tkSymbol and p.cur.lex == ",":
        discard p.eat()
        args.add p.parseExpr()
    discard p.expect(tkSymbol, ")")
    return Expr(kind: ekCall, fname: fieldOrMethodName, args: args, pos: p.posOf(t))
  else:
    # Field access: obj.field
    return Expr(kind: ekFieldAccess, objectExpr: obj, fieldName: fieldOrMethodName, pos: p.posOf(t))

proc parseInfixExpr(p: Parser; left: Expr; t: Token): Expr =
  ## Parses infix expressions (left denotation - expressions that need a left operand)
  let op = t.lex
  if op in ["+","-","*","/","%","==","!=","<",">","<=",">=","and","or"]:
    var right = p.parseExpr(getOperatorPrecedence(op))
    return Expr(kind: ekBin, bop: binOp(op), lhs: left, rhs: right, pos: p.posOf(t))
  if op == "[":
    return p.parseArrayAccessOrSlice(left, t)
  if op == ".":
    return p.parseUFCSCall(left, t)
  raise newEtchError(&"unexpected operator: {op}")

proc parseExpr*(p: Parser; rbp=0): Expr =
  var left = p.parseAtomicExpr()
  while true:
    let t = p.cur
    if (t.kind == tkSymbol and t.lex in ["+","-","*","/","%","==","!=","<",">","<=",">=","[","."]) or
       (t.kind == tkKeyword and t.lex in ["and", "or"]):
      if getOperatorPrecedence(t.lex) <= rbp: break
      discard p.eat()
      left = p.parseInfixExpr(left, t)
    else:
      break
  left

# --- Statements ---
proc parseBlock(p: Parser): seq[Stmt] =
  var body: seq[Stmt] = @[]
  discard p.expect(tkSymbol, "{")
  while not (p.cur.kind == tkSymbol and p.cur.lex == "}"):
    body.add p.parseStmt()
  discard p.expect(tkSymbol, "}")
  body

proc parseVarDecl(p: Parser; vflag: VarFlag): Stmt =
  let tname = p.expect(tkIdent)
  var ty: EtchType = nil
  var ini: Option[Expr] = none(Expr)

  # Check if type annotation is provided
  if p.cur.kind == tkSymbol and p.cur.lex == ":":
    discard p.eat()  # consume ":"
    ty = p.parseType()

  # Check for initialization
  if p.cur.kind == tkSymbol and p.cur.lex == "=":
    discard p.eat()  # consume "="
    ini = some(p.parseExpr())

    # If no type annotation provided, try to infer from initializer
    if ty == nil:
      ty = inferTypeFromExpr(ini.get())
      if ty == nil:
          raise newParseError(p.posOf(tname), &"cannot infer type for variable '{tname.lex}', please provide explicit type annotation")
  elif ty == nil:
    # No type annotation and no initializer
    raise newParseError(p.posOf(tname), &"variable '{tname.lex}' requires either type annotation or initializer for type inference")

  discard p.expect(tkSymbol, ";")
  Stmt(kind: skVar, vflag: vflag, vname: tname.lex, vtype: ty, vinit: ini, pos: p.posOf(tname))

proc parseIf(p: Parser): Stmt =
  let k = p.expect(tkKeyword, "if")
  let cond = p.parseExpr()
  let thn = p.parseBlock()

  # Parse elif chain
  var elifChain: seq[tuple[cond: Expr, body: seq[Stmt]]] = @[]
  while p.cur.kind == tkKeyword and p.cur.lex == "elif":
    discard p.eat()  # consume "elif"
    let elifCond = p.parseExpr()
    let elifBody = p.parseBlock()
    elifChain.add((cond: elifCond, body: elifBody))

  # Parse else if present
  var els: seq[Stmt] = @[]
  if p.cur.kind == tkKeyword and p.cur.lex == "else":
    discard p.eat()
    els = p.parseBlock()

  Stmt(kind: skIf, cond: cond, thenBody: thn, elifChain: elifChain, elseBody: els, pos: p.posOf(k))

proc parseWhile(p: Parser): Stmt =
  let k = p.expect(tkKeyword, "while")
  let c = p.parseExpr()
  let b = p.parseBlock()
  Stmt(kind: skWhile, wcond: c, wbody: b, pos: p.posOf(k))

proc parseFor(p: Parser): Stmt =
  let k = p.expect(tkKeyword, "for")
  let varname = p.expect(tkIdent).lex
  discard p.expect(tkKeyword, "in")

  # Parse the iteration target
  let firstExpr = p.parseExpr()

  # Check if this is a range (..) or (..<) or array iteration
  if p.cur.kind == tkSymbol and (p.cur.lex == ".." or p.cur.lex == "..<"):
    # Range iteration: for x in start..end or for x in start..<end
    let isInclusive = p.cur.lex == ".."
    discard p.eat()  # consume ".." or "..<"
    let endExpr = p.parseExpr()
    let body = p.parseBlock()
    Stmt(kind: skFor, fvar: varname, fstart: some(firstExpr), fend: some(endExpr), farray: none(Expr), finclusive: isInclusive, fbody: body, pos: p.posOf(k))
  else:
    # Array iteration: for x in array
    let body = p.parseBlock()
    Stmt(kind: skFor, fvar: varname, fstart: none(Expr), fend: none(Expr), farray: some(firstExpr), finclusive: true, fbody: body, pos: p.posOf(k))

proc parseBreak(p: Parser): Stmt =
  let k = p.expect(tkKeyword, "break")
  discard p.expect(tkSymbol, ";")
  Stmt(kind: skBreak, pos: p.posOf(k))

proc parseReturn(p: Parser): Stmt =
  let k = p.expect(tkKeyword, "return")
  var e: Option[Expr] = none(Expr)
  if not (p.cur.kind == tkSymbol and p.cur.lex == ";"):
    e = some(p.parseExpr())
  discard p.expect(tkSymbol, ";")
  Stmt(kind: skReturn, re: e, pos: p.posOf(k))

proc parseComptime(p: Parser): Stmt =
  let k = p.expect(tkKeyword, "comptime")
  let body = p.parseBlock()
  Stmt(kind: skComptime, cbody: body, pos: p.posOf(k))

proc parseSimpleStmt(p: Parser): Stmt =
  # assignment or call expr
  let start = p.cur
  if start.kind == tkIdent and p.peek().kind == tkSymbol and p.peek().lex == "=":
    let n = p.eat()
    discard p.expect(tkSymbol, "=")
    let e = p.parseExpr()
    discard p.expect(tkSymbol, ";")
    return Stmt(kind: skAssign, aname: n.lex, aval: e, pos: p.posOf(n))
  else:
    let e = p.parseExpr()
    discard p.expect(tkSymbol, ";")
    return Stmt(kind: skExpr, sexpr: e, pos: p.posOf(start))

proc parseTyParams(p: Parser): seq[TyParam] =
  result = @[]
  if p.cur.kind == tkSymbol and p.cur.lex == "[":
    discard p.eat()
    while true:
      let nameTok = p.expect(tkIdent)
      var c: Option[string] = none(string)
      if p.cur.kind == tkSymbol and p.cur.lex == ":":
        discard p.eat()
        let cname = p.expect(tkIdent).lex
        c = some(cname)
      result.add TyParam(name: nameTok.lex, koncept: c)
      if p.cur.kind == tkSymbol and p.cur.lex == ",":
        discard p.eat(); continue
      discard p.expect(tkSymbol, "]")
      break

proc parseTypeDecl(p: Parser): Stmt =
  let start = p.expect(tkKeyword, "type")
  let typeName = p.expect(tkIdent).lex
  discard p.expect(tkSymbol, "=")

  # Check if it's a distinct type
  var typeKind = "alias"
  var aliasTarget: EtchType = nil
  var objectFields: seq[ObjectField] = @[]

  if p.cur.kind == tkKeyword and p.cur.lex == "distinct":
    discard p.eat()  # consume "distinct"
    typeKind = "distinct"
    aliasTarget = p.parseType()
  elif p.cur.kind == tkKeyword and p.cur.lex == "object":
    discard p.eat()  # consume "object"
    typeKind = "object"

    # Parse object body
    discard p.expect(tkSymbol, "{")
    while p.cur.kind != tkSymbol or p.cur.lex != "}":
      let fieldName = p.expect(tkIdent).lex
      discard p.expect(tkSymbol, ":")
      let fieldType = p.parseType()

      # Check for default value
      var defaultValue = none(Expr)
      if p.cur.kind == tkSymbol and p.cur.lex == "=":
        discard p.eat()  # consume "="
        defaultValue = some(p.parseExpr())

      objectFields.add(ObjectField(
        name: fieldName,
        fieldType: fieldType,
        defaultValue: defaultValue,
        generationalRef: fieldType.kind == tkRef  # Enable generational refs for ref types
      ))

      # Handle field separator
      if p.cur.kind == tkSymbol and p.cur.lex == ";":
        discard p.eat()
      elif p.cur.kind == tkSymbol and p.cur.lex == "}":
        break
      else:
        let t = p.cur
        let actualName = friendlyTokenName(t.kind, t.lex)
        raise newParseError(p.posOf(t), &"expected ';' or '}}', got {actualName}")

    discard p.expect(tkSymbol, "}")
  else:
    # Type alias
    aliasTarget = p.parseType()

  discard p.expect(tkSymbol, ";")

  return Stmt(
    kind: skTypeDecl,
    typeName: typeName,
    typeKind: typeKind,
    aliasTarget: aliasTarget,
    objectFields: objectFields,
    pos: p.posOf(start)
  )

proc parseFn(p: Parser; prog: Program) =
  discard p.expect(tkKeyword, "fn")
  # Allow operator symbols as function names for operator overloading
  let nameToken = p.cur
  var name: string
  if nameToken.kind == tkIdent:
    name = p.eat().lex
  elif nameToken.kind == tkSymbol and nameToken.lex in ["+", "-", "*", "/", "%", "==", "!=", "<", "<=", ">", ">="]:
    name = p.eat().lex
  else:
    let actualName = friendlyTokenName(nameToken.kind, nameToken.lex)
    raise newParseError(p.posOf(nameToken), &"expected function name or operator symbol, got {actualName}")
  let tps = p.parseTyParams()
  # Track generic parameters for type parsing
  for tp in tps:
    p.genericParams.add(tp.name)
  discard p.expect(tkSymbol, "(")
  var ps: seq[Param] = @[]
  if not (p.cur.kind == tkSymbol and p.cur.lex == ")"):
    while true:
      let pn = p.expect(tkIdent).lex
      discard p.expect(tkSymbol, ":")
      let pt = p.parseType()

      # Check for default parameter value
      var defaultValue = none(Expr)
      if p.cur.kind == tkSymbol and p.cur.lex == "=":
        discard p.eat()  # consume "="
        defaultValue = some(p.parseExpr())

      ps.add Param(name: pn, typ: pt, defaultValue: defaultValue)
      if p.cur.kind == tkSymbol and p.cur.lex == ",":
        discard p.eat()
      else: break
  discard p.expect(tkSymbol, ")")

  # Return type is optional - if -> is present, parse it, otherwise infer from body
  var rt: EtchType = nil
  if p.cur.kind == tkSymbol and p.cur.lex == "->":
    discard p.eat()  # consume "->"
    rt = p.parseType()

  let body = p.parseBlock()
  let fd = FunDecl(name: name, typarams: tps, params: ps, ret: rt, body: body)
  prog.addFunction(fd)
  # Clear generic parameters after parsing the function
  p.genericParams.setLen(0)

proc parseStmt*(p: Parser): Stmt =
  if p.cur.kind == tkKeyword:
    case p.cur.lex
    of "let":
      discard p.eat();
      return p.parseVarDecl(vfLet)
    of "var":
      discard p.eat();
      return p.parseVarDecl(vfVar)
    of "if": return p.parseIf()
    of "while": return p.parseWhile()
    of "for": return p.parseFor()
    of "break": return p.parseBreak()
    of "return": return p.parseReturn()
    of "comptime": return p.parseComptime()
    of "type": return p.parseTypeDecl()
    else: discard # fallthrough to simple
  return p.parseSimpleStmt()

proc parseProgram*(toks: seq[Token], filename: string = "<unknown>"): Program =
  var p = Parser(toks: toks, i: 0, filename: filename, genericParams: @[])
  result = Program(
    funs: initTable[string, seq[FunDecl]](),
    funInstances: initTable[string, FunDecl](),
    globals: @[],
    types: initTable[string, EtchType]()
  )

  while p.cur.kind != tkEof:
    if p.cur.kind == tkKeyword and p.cur.lex == "fn":
      p.parseFn(result)
    elif p.cur.kind == tkKeyword and (p.cur.lex == "let" or p.cur.lex == "var"):
      let st = p.parseStmt()
      result.globals.add st
    elif p.cur.kind == tkKeyword and p.cur.lex == "type":
      let typeDecl = p.parseTypeDecl()
      # Process the type declaration and add to types table
      case typeDecl.typeKind
      of "alias":
        result.types[typeDecl.typeName] = typeDecl.aliasTarget
      of "distinct":
        result.types[typeDecl.typeName] = tDistinct(typeDecl.typeName, typeDecl.aliasTarget)
      of "object":
        result.types[typeDecl.typeName] = tObject(typeDecl.typeName, typeDecl.objectFields)
      else:
        let pos = typeDecl.pos
        raise newParseError(pos, &"unknown type kind: {typeDecl.typeKind}")
    else:
      # top-level expr stmt not allowed, give error
      let t = p.cur
      let actualName = friendlyTokenName(t.kind, t.lex)
      raise newParseError(Pos(line: t.line, col: t.col), &"unexpected {actualName} at top-level")
