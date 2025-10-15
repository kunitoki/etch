# parser.nim
# Pratt parser for Etch using tokens from lexer

import std/[strformat, tables, options, strutils]
import ast, lexer, ../common/[errors, types, builtins]
import ../typechecker/types


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


proc parseType(p: Parser): EtchType
proc parseExpr*(p: Parser; rbp=0): Expr
proc parseStmt*(p: Parser): Stmt
proc parseMatchExpr(p: Parser; t: Token): Expr
proc parseIfExpr(p: Parser; t: Token): Expr
proc parsePattern(p: Parser): Pattern
proc parseBlock(p: Parser): seq[Stmt]


## Parse a single type, potentially part of a union
proc parseSingleType(p: Parser): EtchType =
  let t = p.cur

  if t.kind notin {tkKeyword, tkIdent}:
    let actualName = friendlyTokenName(t.kind, t.lex)
    raise newParseError(p.posOf(t), &"expected type, got {actualName}")

  case t.lex:
  of "void":
    discard p.eat
    return tVoid()

  of "bool":
    discard p.eat
    return tBool()

  of "char":
    discard p.eat
    return tChar()

  of "int":
    discard p.eat
    return tInt()

  of "float":
    discard p.eat
    return tFloat()

  of "string":
    discard p.eat
    return tString()

  of "ref":
    discard p.expect(tkKeyword, "ref")
    discard p.expect(tkSymbol, "[")
    let inner = p.parseType()
    discard p.expect(tkSymbol, "]")
    return tRef(inner)

  of "array":
    discard p.expect(tkKeyword, "array")
    discard p.expect(tkSymbol, "[")
    let inner = p.parseType()
    discard p.expect(tkSymbol, "]")
    return tArray(inner)

  of "option":
    discard p.expect(tkKeyword, "option")
    discard p.expect(tkSymbol, "[")
    let inner = p.parseType()
    discard p.expect(tkSymbol, "]")
    return tOption(inner)

  of "result":
    discard p.expect(tkIdent, "result")
    discard p.expect(tkSymbol, "[")
    let inner = p.parseType()
    discard p.expect(tkSymbol, "]")
    return tResult(inner)

  else:
    if t.lex in p.genericParams:
      discard p.eat
      return tGeneric(t.lex)

  # user-defined type name (could be alias, distinct, or object)
  discard p.eat
  return tUserDefined(t.lex)


# Parse a type, potentially a union of multiple types
proc parseType(p: Parser): EtchType =
  # Parse first type
  var types: seq[EtchType] = @[parseSingleType(p)]

  # Check for union (|) operator
  while p.cur.kind == tkSymbol and p.cur.lex == "|":
    discard p.eat()  # consume |
    types.add(parseSingleType(p))

  # If we have multiple types, create a union
  if types.len > 1:
    return tUnion(types)
  else:
    return types[0]


# Returns the left binding power (precedence) of an operator
proc getOperatorPrecedence(op: string): int =
  case op
  of "or": 1
  of "and": 2
  of "==","!=": 3
  of "<",">","<=",">=","in","not in": 4
  of "+","-": 5
  of "*","/","%": 6
  of ".": 7  # field access and UFCS method calls
  of "[": 8  # array indexing/slicing has high precedence
  of "@": 9  # deref has very high precedence, higher than field access
  else: 0


# Returns the binary operation kind for an operator
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
  of "in": boIn
  of "not in": boNotIn
  else: raise newEtchError(&"unknown operator: {op}")


# Parses literal expressions (int, float, string, char, bool)
proc parseLiteralExpr(p: Parser; t: Token): Expr =
  case t.kind
  of tkBool:
    return Expr(kind: ekBool, bval: t.lex == "true", pos: p.posOf(t))
  of tkChar:
    return Expr(kind: ekChar, cval: t.lex[0], pos: p.posOf(t))
  of tkInt:
    return Expr(kind: ekInt, ival: parseInt(t.lex), pos: p.posOf(t))
  of tkFloat:
    return Expr(kind: ekFloat, fval: parseFloat(t.lex), pos: p.posOf(t))
  of tkString:
    return Expr(kind: ekString, sval: t.lex, pos: p.posOf(t))
  else:
    raise newEtchError("not a literal token")


# Parses built-in keyword expressions (true, false, nil, new)
proc parseBuiltinKeywordExpr(p: Parser; t: Token): Expr =
  case t.lex
  of "true":
    return Expr(kind: ekBool, bval: true, pos: p.posOf(t))

  of "false":
    return Expr(kind: ekBool, bval: false, pos: p.posOf(t))

  of "nil":
    return Expr(kind: ekNil, pos: p.posOf(t))

  of "not":
    let e = p.parseExpr(6)  # highest prefix binding
    return Expr(kind: ekUn, uop: uoNot, ue: e, pos: p.posOf(t))

  of "new":
    # Check for new[Type] or new[Type]{value} syntax
    if p.cur.kind == tkSymbol and p.cur.lex == "[":
      discard p.eat()  # consume "["
      let typeExpr = p.parseType()  # Parse the type
      discard p.expect(tkSymbol, "]")
      var initExpr = none(Expr)
      # Check for optional {value} initialization
      if p.cur.kind == tkSymbol and p.cur.lex == "{":
        initExpr = some(p.parseExpr())
      return Expr(kind: ekNew, newType: typeExpr, initExpr: initExpr, pos: p.posOf(t))
    else:
      # Old syntax: new(value) - infer type from value
      discard p.expect(tkSymbol, "(")
      let valueExpr = p.parseExpr()
      discard p.expect(tkSymbol, ")")
      # Create new expression with type inference marker
      return Expr(kind: ekNew, newType: nil, initExpr: some(valueExpr), pos: p.posOf(t))

  of "match":
    return p.parseMatchExpr(t)

  of "if":
    return p.parseIfExpr(t)

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

  else:
    return Expr(kind: ekVar, vname: t.lex, pos: p.posOf(t))


# Parses match expressions: match expr { pattern => body, ... }
proc parseMatchExpr(p: Parser; t: Token): Expr =
  let matchExpr = p.parseExpr()
  discard p.expect(tkSymbol, "{")

  var cases: seq[MatchCase] = @[]

  while p.cur.kind != tkSymbol or p.cur.lex != "}":
    let pattern = p.parsePattern()
    discard p.expect(tkSymbol, "=>")

    # Parse body: either { block } or single expression
    let body =
      if p.cur.kind == tkSymbol and p.cur.lex == "{":
        p.parseBlock()
      else:
        let expr = p.parseExpr()
        @[Stmt(kind: skExpr, sexpr: expr, pos: expr.pos)]
    cases.add(MatchCase(pattern: pattern, body: body))

    # Skip optional comma or semicolon
    if p.cur.kind == tkSymbol and (p.cur.lex == "," or p.cur.lex == ";"):
      discard p.eat()

  discard p.expect(tkSymbol, "}")
  return Expr(kind: ekMatch, matchExpr: matchExpr, cases: cases, pos: p.posOf(t))


# Parses if expressions: if cond { body } else { body }
proc parseIfExpr(p: Parser; t: Token): Expr =
  let cond = p.parseExpr()

  # Parse then branch: either { block } or single expression (for match-like syntax)
  discard p.expect(tkSymbol, "{")
  var thenBody: seq[Stmt] = @[]

  # Check if this is a single expression without semicolon
  let isSimpleExpr = not (p.peek(1).kind == tkSymbol and p.peek(1).lex == ";")
  if isSimpleExpr:
    let expr = p.parseExpr()
    thenBody.add(Stmt(kind: skExpr, sexpr: expr, pos: expr.pos))
  else:
    while not (p.cur.kind == tkSymbol and p.cur.lex == "}"):
      thenBody.add(p.parseStmt())
  discard p.expect(tkSymbol, "}")

  # Parse elif/else-if chain
  var elifChain: seq[tuple[cond: Expr, body: seq[Stmt]]] = @[]
  while p.cur.kind == tkKeyword and (p.cur.lex == "elif" or (p.cur.lex == "else" and p.peek(1).kind == tkKeyword and p.peek(1).lex == "if")):
    # Handle both "elif" and "else if"
    if p.cur.lex == "elif":
      discard p.eat()  # consume "elif"
    else:
      discard p.eat()  # consume "else"
      discard p.eat()  # consume "if"

    let elifCond = p.parseExpr()
    discard p.expect(tkSymbol, "{")
    var elifBody: seq[Stmt] = @[]
    let isSimpleElifExpr = not (p.peek(1).kind == tkSymbol and p.peek(1).lex == ";")
    if isSimpleElifExpr:
      let expr = p.parseExpr()
      elifBody.add(Stmt(kind: skExpr, sexpr: expr, pos: expr.pos))
    else:
      while not (p.cur.kind == tkSymbol and p.cur.lex == "}"):
        elifBody.add(p.parseStmt())
    discard p.expect(tkSymbol, "}")
    elifChain.add((cond: elifCond, body: elifBody))

  # Parse else (required for if-expressions)
  if not (p.cur.kind == tkKeyword and p.cur.lex == "else"):
    raise newParseError(p.posOf(t), "if expression requires an 'else' branch")

  discard p.eat()  # consume "else"
  discard p.expect(tkSymbol, "{")
  var elseBody: seq[Stmt] = @[]
  let isSimpleElseExpr = not (p.peek(1).kind == tkSymbol and p.peek(1).lex == ";")
  if isSimpleElseExpr:
    let expr = p.parseExpr()
    elseBody.add(Stmt(kind: skExpr, sexpr: expr, pos: expr.pos))
  else:
    while not (p.cur.kind == tkSymbol and p.cur.lex == "}"):
      elseBody.add(p.parseStmt())
  discard p.expect(tkSymbol, "}")

  return Expr(kind: ekIf, ifCond: cond, ifThen: thenBody, ifElifChain: elifChain, ifElse: elseBody, pos: p.posOf(t))


# Parses match patterns: some(x), none, ok(x), error(x), _, or type patterns for unions
proc parsePattern(p: Parser): Pattern =
  let t = p.cur

  # Check for type patterns (for union matching)
  # Support both: `int(x)` or just `int` patterns
  if t.kind in {tkKeyword, tkIdent}:
    # Check if this might be a type
    let isType = t.lex in ["int", "float", "string", "char", "bool", "ref", "array", "option", "result"] or
                 t.lex in p.genericParams

    if isType:
      # Try to parse as type
      let typ = p.parseType()

      # Check for optional binding: type(bindVar)
      var bindName = ""
      if p.cur.kind == tkSymbol and p.cur.lex == "(":
        discard p.eat()  # consume (
        bindName = p.expect(tkIdent).lex
        discard p.expect(tkSymbol, ")")

      return Pattern(kind: pkType, typePattern: typ, typeBind: bindName)

  # Fall back to regular patterns
  discard p.eat()
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
    # Try parsing as a type pattern for user-defined types
    p.i -= 1  # backtrack
    let typ = p.parseType()
    var bindName = ""
    if p.cur.kind == tkSymbol and p.cur.lex == "(":
      discard p.eat()  # consume (
      bindName = p.expect(tkIdent).lex
      discard p.expect(tkSymbol, ")")
    return Pattern(kind: pkType, typePattern: typ, typeBind: bindName)


# Parses cast expressions: type(expr)
proc parseCastExpr(p: Parser; t: Token): Expr =
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


# Parses function call expressions: func(arg1, arg2, ...)
proc parseFunctionCallExpr(p: Parser; t: Token): Expr =
  var args: seq[Expr] = @[]
  discard p.eat() # consume (
  if not (p.cur.kind == tkSymbol and p.cur.lex == ")"):
    args.add p.parseExpr()
    while p.cur.kind == tkSymbol and p.cur.lex == ",":
      discard p.eat()
      args.add p.parseExpr()
  discard p.expect(tkSymbol, ")")
  return Expr(kind: ekCall, fname: t.lex, args: args, pos: p.posOf(t))


# Parses identifier expressions (variables, function calls, or casts)
proc parseIdentifierExpr(p: Parser; t: Token): Expr =
  if p.cur.kind == tkSymbol and p.cur.lex == "(":
    if t.lex in ["bool", "char", "int", "float", "string"]:
      return p.parseCastExpr(t)
    else:
      return p.parseFunctionCallExpr(t)
  else:
    return Expr(kind: ekVar, vname: t.lex, pos: p.posOf(t))


# Parses symbol expressions (parentheses, arrays, unary operators)
proc parseSymbolExpr(p: Parser; t: Token): Expr =
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


# Parses atomic expressions (null denotation - expressions that don't need a left operand)
proc parseAtomicExpr(p: Parser): Expr =
  let t = p.eat()
  case t.kind
  of tkInt, tkFloat, tkString, tkChar, tkBool:
    return p.parseLiteralExpr(t)
  of tkKeyword:
    if t.lex in ["bool", "char", "int", "float", "string"] and p.cur.kind == tkSymbol and p.cur.lex == "(":
      return p.parseCastExpr(t)
    else:
      return p.parseBuiltinKeywordExpr(t)
  of tkIdent:
    return p.parseIdentifierExpr(t)
  of tkSymbol:
    return p.parseSymbolExpr(t)
  of tkEof:
    raise newParseError(Pos(line: t.line, col: t.col), "unexpected end of input")


# Parses array indexing or slicing: expr[index] or expr[start:end] or expr[:end]
proc parseArrayAccessOrSlice(p: Parser; left: Expr; t: Token): Expr =
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


# Parses UFCS method calls: obj.method() or field access: obj.field
proc parseUFCSCall(p: Parser; obj: Expr; t: Token): Expr =
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


# Parses infix expressions (left denotation - expressions that need a left operand)
proc parseInfixExpr(p: Parser; left: Expr; t: Token): Expr =
  let op = t.lex
  if op in ["+","-","*","/","%","==","!=","<",">","<=",">=","and","or","in"]:
    var right = p.parseExpr(getOperatorPrecedence(op))
    return Expr(kind: ekBin, bop: binOp(op), lhs: left, rhs: right, pos: p.posOf(t))
  if op == "[":
    return p.parseArrayAccessOrSlice(left, t)
  if op == ".":
    return p.parseUFCSCall(left, t)
  raise newEtchError(&"unexpected operator: {op}")


# Parse expressions using Pratt parsing
proc parseExpr*(p: Parser; rbp=0): Expr =
  var left = p.parseAtomicExpr()
  while true:
    let t = p.cur
    # Check for "not in" operator (two keywords)
    if t.kind == tkKeyword and t.lex == "not" and p.peek().kind == tkKeyword and p.peek().lex == "in":
      if getOperatorPrecedence("not in") <= rbp: break
      discard p.eat()  # consume "not"
      discard p.eat()  # consume "in"
      var right = p.parseExpr(getOperatorPrecedence("not in"))
      left = Expr(kind: ekBin, bop: boNotIn, lhs: left, rhs: right, pos: p.posOf(t))
    elif (t.kind == tkSymbol and t.lex in ["+","-","*","/","%","==","!=","<",">","<=",">=","[","."]) or (t.kind == tkKeyword and t.lex in ["and", "or", "in"]):
      if getOperatorPrecedence(t.lex) <= rbp: break
      discard p.eat()
      left = p.parseInfixExpr(left, t)
    else:
      break
  left


# Parse blocks and statements
proc parseBlock(p: Parser): seq[Stmt] =
  var body: seq[Stmt] = @[]
  discard p.expect(tkSymbol, "{")
  while not (p.cur.kind == tkSymbol and p.cur.lex == "}"):
    body.add p.parseStmt()
  discard p.expect(tkSymbol, "}")
  body


# Parse var and let declarations
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
          # Use deferred inference for complex expressions that need type checker context
          ty = tInferred()
  elif ty == nil:
    # No type annotation and no initializer
    raise newParseError(p.posOf(tname), &"variable '{tname.lex}' requires either type annotation or initializer for type inference")

  discard p.expect(tkSymbol, ";")
  Stmt(kind: skVar, vflag: vflag, vname: tname.lex, vtype: ty, vinit: ini, pos: p.posOf(tname))


# Parse if statements with elif and else branches
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


# Parse while loops
proc parseWhile(p: Parser): Stmt =
  let k = p.expect(tkKeyword, "while")
  let c = p.parseExpr()
  let b = p.parseBlock()
  Stmt(kind: skWhile, wcond: c, wbody: b, pos: p.posOf(k))


# Parse for loops (both range and array iteration)
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


# Parse break, return, discard, comptime, and import statements
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


proc parseDiscard(p: Parser): Stmt =
  let k = p.expect(tkKeyword, "discard")
  var exprs: seq[Expr] = @[]
  if not (p.cur.kind == tkSymbol and p.cur.lex == ";"):
    exprs.add(p.parseExpr())
    while p.cur.kind == tkSymbol and p.cur.lex == ",":
      discard p.eat()  # consume ","
      exprs.add(p.parseExpr())
  discard p.expect(tkSymbol, ";")
  Stmt(kind: skDiscard, dexprs: exprs, pos: p.posOf(k))


proc parseComptime(p: Parser): Stmt =
  let k = p.expect(tkKeyword, "comptime")
  let body = p.parseBlock()
  Stmt(kind: skComptime, cbody: body, pos: p.posOf(k))


proc parseImport(p: Parser): Stmt =
  let k = p.expect(tkKeyword, "import")
  let pos = p.posOf(k)

  # Parse the module path or FFI namespace
  var importKind = "module"  # default to module import
  var importPath = ""

  # Check for FFI import: "import ffi <library>" for C libraries
  if p.cur.kind == tkIdent and p.cur.lex == "ffi":
    discard p.eat()  # consume "ffi"
    if p.cur.kind == tkIdent:
      importKind = "cffi"  # C FFI
      importPath = p.cur.lex  # Library name or alias (c, cmath, etc.)
      discard p.eat()

      # Check for path-like syntax (e.g., clib/mathlib)
      while p.cur.kind == tkSymbol and p.cur.lex == "/":
        discard p.eat()  # consume '/'
        if p.cur.kind == tkIdent:
          importPath = importPath & "/" & p.cur.lex
          discard p.eat()
        else:
          raise newParseError(Pos(filename: p.filename, line: p.cur.line, col: p.cur.col), "Expected library name after '/'")
    else:
      raise newParseError(Pos(filename: p.filename, line: p.cur.line, col: p.cur.col), "Expected library name or path after 'ffi' (e.g., 'c', 'cmath', 'clib/mathlib')")
  elif p.cur.kind == tkString:
    # Module import with quotes: 'import "path/to/module.etch"'
    importPath = p.expect(tkString).lex
  else:
    # Module import without quotes: 'import lib/math'
    importPath = p.expect(tkIdent).lex

    # Check for path-like syntax (e.g., lib/math)
    while p.cur.kind == tkSymbol and p.cur.lex == "/":
      discard p.eat()  # consume '/'
      if p.cur.kind == tkIdent:
        importPath = importPath & "/" & p.cur.lex
        discard p.eat()
      elif p.cur.kind == tkSymbol and p.cur.lex == "[":
        # Path ends with / for multi-module import (e.g., lib/ [math, physics])
        importPath = importPath & "/"
        break
      else:
        raise newParseError(Pos(filename: p.filename, line: p.cur.line, col: p.cur.col), "Expected module name after '/'")

    # Add .etch extension if not present (but not for paths ending with /)
    if not importPath.endsWith(".etch") and not importPath.endsWith("/"):
      importPath = importPath & ".etch"

  # Parse optional import list
  var items: seq[ImportItem] = @[]

  # Check for [ ] - multiple submodule import
  if p.cur.kind == tkSymbol and p.cur.lex == "[":
    discard p.eat()  # consume "["

    # Parse multiple submodule imports: import lib/ [ math, physics ]
    var moduleNames: seq[string] = @[]
    while p.cur.kind != tkSymbol or p.cur.lex != "]":
      let moduleName = p.expect(tkIdent).lex
      moduleNames.add(moduleName)

      if p.cur.kind == tkSymbol and p.cur.lex == ",":
        discard p.eat()
      elif p.cur.kind == tkSymbol and p.cur.lex == "]":
        break
      else:
        raise newParseError(Pos(filename: p.filename, line: p.cur.line, col: p.cur.col), "Expected ',' or ']' after module name")

    discard p.expect(tkSymbol, "]")

    # Store the module names as a special marker in importItems
    # We'll expand these in parseProgram
    for moduleName in moduleNames:
      items.add(ImportItem(
        itemKind: "module",
        name: moduleName,
        signature: FunctionSignature(),
        typ: nil,
        isExported: false,
        alias: ""
      ))

    # Return with special marker to indicate multi-module import
    return Stmt(
      kind: skImport,
      importKind: "multi-module",
      importPath: importPath,
      importItems: items,
      pos: pos
    )
  elif p.cur.kind == tkSymbol and p.cur.lex == "{":
    discard p.eat()  # consume "{"

    # Parse symbol imports from a specific module
    # import lib/math { add, square }  (import specific symbols from module)

    # Parse as regular item import
    while p.cur.kind != tkSymbol or p.cur.lex != "}":
      var itemKind = "function"  # default
      var itemName = ""

      # For FFI imports, require 'fn' keyword
      if importKind == "cffi":
        if p.cur.kind == tkKeyword and p.cur.lex == "fn":
          itemKind = "function"
          discard p.eat()
          itemName = p.expect(tkIdent).lex
        else:
          raise newParseError(Pos(filename: p.filename, line: p.cur.line, col: p.cur.col), "FFI imports require 'fn' keyword before function declarations")
      else:
        # For module imports, check for explicit item kind
        if p.cur.kind == tkKeyword:
          if p.cur.lex == "fn":
            itemKind = "function"
            discard p.eat()
            itemName = p.expect(tkIdent).lex
          elif p.cur.lex == "const":
            itemKind = "const"
            discard p.eat()
            itemName = p.expect(tkIdent).lex
          elif p.cur.lex == "type":
            itemKind = "type"
            discard p.eat()
            itemName = p.expect(tkIdent).lex
          else:
            # Default: assume it's a function without 'fn' prefix
            itemName = p.expect(tkIdent).lex
        else:
          # No keyword, just parse the name
          itemName = p.expect(tkIdent).lex

      var item = ImportItem(
        itemKind: itemKind,
        name: itemName,
        signature: FunctionSignature(),
        typ: nil,
        isExported: false,
        alias: ""
      )

      # Parse function signature if it's a function
      if itemKind == "function" and p.cur.kind == tkSymbol and p.cur.lex == "(":
        discard p.eat()  # consume "("

        var params: seq[Param] = @[]
        while p.cur.kind != tkSymbol or p.cur.lex != ")":
          let paramName = p.expect(tkIdent).lex
          discard p.expect(tkSymbol, ":")
          let paramType = p.parseType()
          params.add(Param(name: paramName, typ: paramType, defaultValue: none(Expr)))

          if p.cur.kind == tkSymbol and p.cur.lex == ",":
            discard p.eat()

        discard p.expect(tkSymbol, ")")

        # Parse return type
        var returnType = tVoid()
        if p.cur.kind == tkSymbol and p.cur.lex == "->":
          discard p.eat()
          returnType = p.parseType()

        item.signature = FunctionSignature(params: params, returnType: returnType)

      # Check for 'as' clause for aliasing (after signature for functions)
      if p.cur.kind == tkIdent and p.cur.lex == "as":
        discard p.eat()
        item.alias = p.expect(tkIdent).lex
      elif itemKind == "const" and p.cur.kind == tkSymbol and p.cur.lex == ":":
        # Parse const type
        discard p.eat()  # consume ":"
        item.typ = p.parseType()

      # For CFFI imports, signatures must be provided explicitly
      if importKind == "cffi" and itemKind == "function":
        if item.signature.params.len == 0 and item.signature.returnType == nil:
          raise newParseError(Pos(filename: p.filename, line: p.cur.line, col: p.cur.col), "FFI function imports require explicit type signatures")

      items.add(item)

      # Check for comma, semicolon or closing brace
      if p.cur.kind == tkSymbol and p.cur.lex == ",":
        discard p.eat()
      elif p.cur.kind == tkSymbol and p.cur.lex == ";":
        discard p.eat()
      elif p.cur.kind == tkSymbol and p.cur.lex == "}":
        break

    discard p.expect(tkSymbol, "}")

  # Optional semicolon after import
  if p.cur.kind == tkSymbol and p.cur.lex == ";":
    discard p.eat()

  return Stmt(
    kind: skImport,
    importKind: importKind,
    importPath: importPath,
    importItems: items,
    pos: pos
  )


# Parse simple statements: assignments or expression statements (assignments or call expressions)
proc parseSimpleStmt(p: Parser): Stmt =
  let start = p.cur

  # Try to detect assignment: either simple identifier, field access, or array index followed by =
  # We need to look ahead to see if we have an assignment pattern
  var isAssignment = false
  var isArrayIndexAssign = false
  var lookAheadIdx = 0

  # Check for simple identifier assignment (x = ...)
  if start.kind == tkIdent and p.peek().kind == tkSymbol and p.peek().lex == "=":
    isAssignment = true
  # Check for array index assignment (arr[idx] = ...)
  elif start.kind == tkIdent and p.peek().kind == tkSymbol and p.peek().lex == "[":
    # Look for pattern: identifier [ ... ] =
    lookAheadIdx = 1
    var bracketDepth = 0
    # Scan forward to find the matching ] and check for =
    while lookAheadIdx < 100:  # Safety limit
      let tok = p.peek(lookAheadIdx)
      if tok.kind == tkSymbol:
        if tok.lex == "[":
          bracketDepth += 1
        elif tok.lex == "]":
          bracketDepth -= 1
          if bracketDepth == 0:
            # Found matching ], check for =
            if p.peek(lookAheadIdx + 1).kind == tkSymbol and p.peek(lookAheadIdx + 1).lex == "=":
              isAssignment = true
              isArrayIndexAssign = true
            break
      lookAheadIdx += 1
  # Check for field assignment (obj.field = ...)
  elif start.kind == tkIdent:
    # Look for pattern: identifier . identifier =
    # We might have multiple field accesses: obj.field1.field2 = ...
    lookAheadIdx = 1
    while p.peek(lookAheadIdx).kind == tkSymbol and p.peek(lookAheadIdx).lex == ".":
      if p.peek(lookAheadIdx + 1).kind != tkIdent:
        break
      lookAheadIdx += 2
      if p.peek(lookAheadIdx).kind == tkSymbol and p.peek(lookAheadIdx).lex == "=":
        isAssignment = true
        break

  if isAssignment:
    if lookAheadIdx == 0:
      # Simple identifier assignment
      let n = p.eat()
      discard p.expect(tkSymbol, "=")
      let e = p.parseExpr()
      discard p.expect(tkSymbol, ";")
      return Stmt(kind: skAssign, aname: n.lex, aval: e, pos: p.posOf(n))
    else:
      # Field or array index assignment - parse left side as expression
      let leftExpr = p.parseExpr()
      discard p.expect(tkSymbol, "=")
      let rightExpr = p.parseExpr()
      discard p.expect(tkSymbol, ";")

      # Create appropriate assignment statement based on left expression type
      if leftExpr.kind == ekFieldAccess:
        # Support nested field access: p.sub.field = value
        return Stmt(kind: skFieldAssign,
                   faTarget: leftExpr,  # Store the full field access expression
                   faValue: rightExpr,
                   pos: p.posOf(start))
      elif leftExpr.kind == ekIndex:
        # Array index assignment: arr[idx] = value
        return Stmt(kind: skFieldAssign,
                   faTarget: leftExpr,  # Store the index expression
                   faValue: rightExpr,
                   pos: p.posOf(start))
      else:
        raise newEtchError(&"Invalid assignment target at {p.posOf(start)}")
  else:
    let e = p.parseExpr()
    discard p.expect(tkSymbol, ";")
    return Stmt(kind: skExpr, sexpr: e, pos: p.posOf(start))


# Parse type parameters: [T, U: SomeConcept]
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


# Parse ttype declarations: alias, distinct, and object types
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


# Parse function declarations
proc parseFn(p: Parser; prog: Program; isExported: bool = false) =
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
  let fd = FunDecl(name: name, typarams: tps, params: ps, ret: rt, body: body, isExported: isExported)
  prog.addFunction(fd)
  # Clear generic parameters after parsing the function
  p.genericParams.setLen(0)


# Parse a single statement
proc parseStmt*(p: Parser): Stmt =
  if p.cur.kind == tkKeyword:
    case p.cur.lex
    of "let":
      discard p.eat()
      return p.parseVarDecl(vfLet)
    of "var":
      discard p.eat()
      return p.parseVarDecl(vfVar)
    of "if": return p.parseIf()
    of "while": return p.parseWhile()
    of "for": return p.parseFor()
    of "break": return p.parseBreak()
    of "return": return p.parseReturn()
    of "discard": return p.parseDiscard()
    of "comptime": return p.parseComptime()
    of "type": return p.parseTypeDecl()
    of "import": return p.parseImport()
    else: discard # fallthrough to simple
  return p.parseSimpleStmt()


# Parse an entire program from a sequence of tokens
proc parseProgram*(toks: seq[Token], filename: string = "<unknown>"): Program =
  var p = Parser(toks: toks, i: 0, filename: filename, genericParams: @[])
  result = Program(
    funs: initTable[string, seq[FunDecl]](),
    funInstances: initTable[string, FunDecl](),
    globals: @[],
    types: initTable[string, EtchType]()
  )

  # Register all builtins automatically - they don't need to be imported
  for name in getBuiltinNames():
    let (paramTypes, returnType) = getBuiltinSignature(name)
    var params: seq[Param] = @[]
    for i, pType in paramTypes:
      params.add(Param(name: "arg" & $i, typ: pType, defaultValue: none(Expr)))

    let funcDecl = FunDecl(
      name: name,
      typarams: @[],
      params: params,
      ret: returnType,
      body: @[]  # Empty body - will be handled as builtin
    )

    if name notin result.funs:
      result.funs[name] = @[]
    result.funs[name].add(funcDecl)

  while p.cur.kind != tkEof:
    # Check for export modifier
    var isExported = false
    if p.cur.kind == tkKeyword and p.cur.lex == "export":
      isExported = true
      discard p.eat()  # consume "export"

    if p.cur.kind == tkKeyword and p.cur.lex == "fn":
      p.parseFn(result, isExported)
    elif p.cur.kind == tkKeyword and (p.cur.lex == "let" or p.cur.lex == "var"):
      let st = p.parseStmt()
      if isExported:
        st.isExported = true
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
    elif p.cur.kind == tkKeyword and p.cur.lex == "import":
      let importStmt = p.parseImport()

      # Handle multi-module imports by expanding them
      if importStmt.importKind == "multi-module":
        # Remove .etch extension from importPath if present for the base path
        let basePath = if importStmt.importPath.endsWith(".etch"):
          importStmt.importPath[0..^6]
        else:
          importStmt.importPath

        # Create individual import statements for each module
        for item in importStmt.importItems:
          if item.itemKind == "module":
            let fullPath = basePath & "/" & item.name & ".etch"
            result.globals.add Stmt(
              kind: skImport,
              importKind: "module",
              importPath: fullPath,
              importItems: @[],
              pos: importStmt.pos
            )
      else:
        result.globals.add importStmt  # Add import to globals for processing
    else:
      # top-level expr stmt not allowed, give error
      let t = p.cur
      let actualName = friendlyTokenName(t.kind, t.lex)
      raise newParseError(Pos(line: t.line, col: t.col), &"unexpected {actualName} at top-level")
