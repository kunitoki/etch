# parser.nim
# Pratt parser for Etch using tokens from lexer

import std/[strformat, tables, options, strutils]
import ast, lexer, ../../common/[constants, errors, types, builtins]
import ../typechecker/types


type
  Parser* = ref object
    toks*: seq[Token]
    i*: int
    filename*: string
    genericParams*: seq[string]  # Track generic type parameters in current scope


proc posOf(p: Parser, t: Token): Pos = Pos(line: t.line, col: t.col, filename: p.filename)
proc parseAtomicExpression(p: Parser): Expression


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
proc parseExpression*(p: Parser; rbp=0): Expression
proc parseStatement*(p: Parser): Statement
proc parseNewExpression(p: Parser; t: Token): Expression
proc parseMatchExpression(p: Parser; t: Token): Expression
proc parseIfExpression(p: Parser; t: Token): Expression
proc parseLambdaExpression(p: Parser; startPos: Pos; hasCaptureList: bool = false; firstBarConsumed: bool = false): Expression
proc tryParseLambdaStart(p: Parser): bool
proc parseLambdaCaptures(p: Parser; startPos: Pos): seq[string]
proc parsePattern(p: Parser): Pattern
proc parseBlock(p: Parser): seq[Statement]
proc parseExpressionBlock(p: Parser): seq[Statement]


## Parse a single type, potentially part of a union
proc parseSingleType(p: Parser): EtchType =
  let t = p.cur

  if t.kind == tkSymbol and t.lex == "(":
    discard p.eat()
    let inner = p.parseType()
    discard p.expect(tkSymbol, ")")
    return inner

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

  of "typedesc":
    discard p.eat
    return tTypeDesc()

  of "ref":
    discard p.expect(tkKeyword, "ref")
    discard p.expect(tkSymbol, "[")
    let inner = p.parseType()
    discard p.expect(tkSymbol, "]")
    return tRef(inner)

  of "weak":
    discard p.expect(tkKeyword, "weak")
    discard p.expect(tkSymbol, "[")
    let inner = p.parseType()
    discard p.expect(tkSymbol, "]")
    return tWeak(inner)

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

  of "tuple":
    discard p.expect(tkKeyword, "tuple")
    discard p.expect(tkSymbol, "[")
    var types: seq[EtchType] = @[]
    if not (p.cur.kind == tkSymbol and p.cur.lex == "]"):
      types.add(p.parseType())
      while p.cur.kind == tkSymbol and p.cur.lex == ",":
        discard p.eat()
        types.add(p.parseType())
    discard p.expect(tkSymbol, "]")
    return tTuple(types)

  of "coroutine":
    discard p.expect(tkIdent, "coroutine")
    discard p.expect(tkSymbol, "[")
    let inner = p.parseType()
    discard p.expect(tkSymbol, "]")
    return tCoroutine(inner)

  of "channel":
    discard p.expect(tkIdent, "channel")
    discard p.expect(tkSymbol, "[")
    let inner = p.parseType()
    discard p.expect(tkSymbol, "]")
    return tChannel(inner)

  of "fn":
    discard p.expect(tkKeyword, "fn")
    discard p.expect(tkSymbol, "(")
    var params: seq[EtchType] = @[]
    if not (p.cur.kind == tkSymbol and p.cur.lex == ")"):
      params.add(p.parseType())
      while p.cur.kind == tkSymbol and p.cur.lex == ",":
        discard p.eat()
        params.add(p.parseType())
    discard p.expect(tkSymbol, ")")
    discard p.expect(tkSymbol, "->")
    let returnType = p.parseType()
    return tFunction(params, returnType)

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
  of "->": 0  # channel send has lowest precedence (like assignment)
  of "<-": 7  # channel receive has same precedence as field access
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
proc binaryOp(op: string, pos: Pos): BinOp =
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
  else: raise newParseError(pos, &"unknown operator: {op}")


# Parses literal expressions (int, float, string, char, bool)
proc parseLiteralExpression(p: Parser; t: Token): Expression =
  case t.kind
  of tkBool:
    return Expression(kind: ekBool, bval: t.lex == "true", pos: p.posOf(t))
  of tkChar:
    return Expression(kind: ekChar, cval: t.lex[0], pos: p.posOf(t))
  of tkInt:
    return Expression(kind: ekInt, ival: parseBiggestInt(t.lex), pos: p.posOf(t))
  of tkFloat:
    return Expression(kind: ekFloat, fval: parseFloat(t.lex), pos: p.posOf(t))
  of tkString:
    return Expression(kind: ekString, sval: t.lex, pos: p.posOf(t))
  else:
    raise newParseError(p.posOf(t), "not a literal token")


# Parses built-in keyword expressions (true, false, nil, new)
proc parseBuiltinKeywordExpression(p: Parser; t: Token): Expression =
  case t.lex
  of "true":
    return Expression(kind: ekBool, bval: true, pos: p.posOf(t))

  of "false":
    return Expression(kind: ekBool, bval: false, pos: p.posOf(t))

  of "nil":
    return Expression(kind: ekNil, pos: p.posOf(t))

  of "not":
    let e = p.parseExpression(6)  # highest prefix binding
    return Expression(kind: ekUn, uop: uoNot, ue: e, pos: p.posOf(t))

  of "new":
    return p.parseNewExpression(t)

  of "match":
    return p.parseMatchExpression(t)

  of "if":
    return p.parseIfExpression(t)

  of "comptime":
    discard p.expect(tkSymbol, "(")
    let e = p.parseExpression()
    discard p.expect(tkSymbol, ")")
    return Expression(kind: ekComptime, comptimeExpression: e, pos: p.posOf(t))

  of "compiles":
    let stmts = p.parseBlock()
    return Expression(kind: ekCompiles, compilesBlock: stmts, compilesEnv: initTable[string, EtchType](), pos: p.posOf(t))

  of "some":
    discard p.expect(tkSymbol, "(")
    let e = p.parseExpression()
    discard p.expect(tkSymbol, ")")
    return Expression(kind: ekOptionSome, someExpression: e, pos: p.posOf(t))

  of "none":
    return Expression(kind: ekOptionNone, pos: p.posOf(t))

  of "ok":
    discard p.expect(tkSymbol, "(")
    let e = p.parseExpression()
    discard p.expect(tkSymbol, ")")
    return Expression(kind: ekResultOk, okExpression: e, pos: p.posOf(t))

  of "error":
    discard p.expect(tkSymbol, "(")
    let e = p.parseExpression()
    discard p.expect(tkSymbol, ")")
    return Expression(kind: ekResultErr, errExpression: e, pos: p.posOf(t))

  of "tuple":
    discard p.expect(tkSymbol, "(")
    var elements: seq[Expression] = @[]
    if not (p.cur.kind == tkSymbol and p.cur.lex == ")"):
      elements.add(p.parseExpression())
      while p.cur.kind == tkSymbol and p.cur.lex == ",":
        discard p.eat()
        elements.add(p.parseExpression())
    discard p.expect(tkSymbol, ")")
    return Expression(kind: ekTuple, tupleElements: elements, pos: p.posOf(t))

  of "typeof":
    let e = p.parseAtomicExpression()
    return Expression(kind: ekTypeof, typeofExpression: e, pos: p.posOf(t))

  of "yield":
    # yield or yield expr
    if p.cur.kind == tkSymbol and p.cur.lex == ";":
      # Just yield without value
      return Expression(kind: ekYield, yieldValue: none(Expression), pos: p.posOf(t))
    else:
      # yield with value
      let e = p.parseExpression()
      return Expression(kind: ekYield, yieldValue: some(e), pos: p.posOf(t))

  of "resume":
    # resume expr - resume a coroutine, optional resume? flattening
    let exprPos = p.posOf(t)
    var flatten = false
    if p.cur.kind == tkSymbol and p.cur.lex == "?":
      discard p.eat()
      flatten = true
    let resumed = Expression(kind: ekResume, resumeValue: p.parseExpression(), pos: exprPos)
    if flatten:
      return Expression(kind: ekResultPropagate, propagateExpression: resumed, pos: exprPos)
    return resumed

  of "spawn":
    # spawn func() or spawn { block }
    if p.cur.kind == tkSymbol and p.cur.lex == "{":
      # spawn { block } - spawn block
      let stmts = p.parseBlock()
      return Expression(kind: ekSpawn, spawnExpression: Expression(kind: ekSpawnBlock, spawnBody: stmts, pos: p.posOf(t)), pos: p.posOf(t))
    else:
      # spawn expr - spawn an expression (usually a function call)
      let e = p.parseExpression()
      return Expression(kind: ekSpawn, spawnExpression: e, pos: p.posOf(t))

  of "channel":
    # channel[T]() or channel[T](capacity)
    discard p.expect(tkSymbol, "[")
    let channelType = p.parseType()
    discard p.expect(tkSymbol, "]")
    discard p.expect(tkSymbol, "(")
    var capacity = none(Expression)
    if not (p.cur.kind == tkSymbol and p.cur.lex == ")"):
      capacity = some(p.parseExpression())
    discard p.expect(tkSymbol, ")")
    return Expression(kind: ekChannelNew, channelType: channelType, channelCapacity: capacity, pos: p.posOf(t))

  else:
    return Expression(kind: ekVar, vname: t.lex, pos: p.posOf(t))


# Parses built-in new
proc parseNewExpression(p: Parser; t: Token): Expression =
  # Check for new[Type] or new[Type](value) syntax
  if p.cur.kind == tkSymbol and p.cur.lex == "[":
    discard p.eat()  # consume "["
    let typeExpression = p.parseType()  # Parse the type
    discard p.expect(tkSymbol, "]")
    var initExpression = none(Expression)
    # Check for optional initialization parentheses
    if p.cur.kind == tkSymbol and p.cur.lex == "(":
      discard p.eat()  # consume (
      if p.cur.kind == tkSymbol and p.cur.lex == ")":
        discard p.eat()  # consume ) for empty init
      else:
        let looksLikeObjectLiteral =
          (p.cur.kind == tkIdent and p.peek().kind == tkSymbol and p.peek().lex == ":")
        if looksLikeObjectLiteral:
          var fieldInits: seq[tuple[name: string, value: Expression]] = @[]
          while true:
            let fieldName = p.expect(tkIdent).lex
            discard p.expect(tkSymbol, ":")
            let fieldValue = p.parseExpression()
            fieldInits.add((name: fieldName, value: fieldValue))
            if p.cur.kind == tkSymbol and p.cur.lex == ",":
              discard p.eat()
            elif p.cur.kind == tkSymbol and p.cur.lex == ")":
              break
            else:
              let current = p.cur
              let actualName = friendlyTokenName(current.kind, current.lex)
              raise newParseError(p.posOf(current), &"expected ',' or ')', got {actualName}")
          discard p.expect(tkSymbol, ")")
          initExpression = some(Expression(kind: ekObjectLiteral, objectType: typeExpression, fieldInits: fieldInits, pos: p.posOf(t)))
        else:
          let valueExpression = p.parseExpression()
          discard p.expect(tkSymbol, ")")
          initExpression = some(valueExpression)
    return Expression(kind: ekNew, newType: typeExpression, initExpression: initExpression, pos: p.posOf(t))
  else:
    # Inferred syntax: new(value) - infer type from value
    discard p.expect(tkSymbol, "(")
    let valueExpression = p.parseExpression()
    discard p.expect(tkSymbol, ")")
    # Create new expression with type inference marker
    return Expression(kind: ekNew, newType: nil, initExpression: some(valueExpression), pos: p.posOf(t))


# Parses match expressions: match expr { pattern => body, ... }
proc parseMatchExpression(p: Parser; t: Token): Expression =
  let matchExpression = p.parseExpression()
  discard p.expect(tkSymbol, "{")

  var cases: seq[MatchCase] = @[]

  while p.cur.kind != tkSymbol or p.cur.lex != "}":
    let pattern = p.parsePattern()
    discard p.expect(tkSymbol, "=>")

    # Parse body: either { block } or single expression
    let body =
      if p.cur.kind == tkSymbol and p.cur.lex == "{":
        p.parseExpressionBlock()
      else:
        let expr = p.parseExpression()
        @[Statement(kind: skExpression, sexpr: expr, pos: expr.pos)]
    cases.add(MatchCase(pattern: pattern, body: body))

    # Skip optional comma or semicolon
    if p.cur.kind == tkSymbol and (p.cur.lex == "," or p.cur.lex == ";"):
      discard p.eat()

  discard p.expect(tkSymbol, "}")
  return Expression(kind: ekMatch, matchExpression: matchExpression, cases: cases, pos: p.posOf(t))


# Parses if expressions: if cond { body } else { body }
proc parseIfExpression(p: Parser; t: Token): Expression =
  let cond = p.parseExpression()

  # Parse then branch allowing either a statement block or an implicit expression
  let thenBody = p.parseExpressionBlock()

  # Parse elif/else-if chain
  var elifChain: seq[tuple[cond: Expression, body: seq[Statement]]] = @[]
  while p.cur.kind == tkKeyword and (p.cur.lex == "elif" or (p.cur.lex == "else" and p.peek(1).kind == tkKeyword and p.peek(1).lex == "if")):
    # Handle both "elif" and "else if"
    if p.cur.lex == "elif":
      discard p.eat()  # consume "elif"
    else:
      discard p.eat()  # consume "else"
      discard p.eat()  # consume "if"

    let elifCond = p.parseExpression()
    let elifBody = p.parseExpressionBlock()
    elifChain.add((cond: elifCond, body: elifBody))

  # Parse else (required for if-expressions)
  if not (p.cur.kind == tkKeyword and p.cur.lex == "else"):
    raise newParseError(p.posOf(t), "if expression requires an 'else' branch")

  discard p.eat()  # consume "else"
  let elseBody = p.parseExpressionBlock()

  return Expression(kind: ekIf, ifCond: cond, ifThen: thenBody, ifElifChain: elifChain, ifElse: elseBody, pos: p.posOf(t))


# Helper to check if a '[' starts a lambda expression (with captures) or array literal
proc tryParseLambdaStart(p: Parser): bool =
  ## Assumes the '[' token has been consumed and parser index points to the next token
  var depth = 1
  var idx = p.i
  while idx < p.toks.len:
    let tok = p.toks[idx]
    if tok.kind == tkSymbol:
      case tok.lex
      of "[":
        inc depth
      of "]":
        dec depth
        if depth == 0:
          let nextIdx = idx + 1
          if nextIdx < p.toks.len:
            let nextTok = p.toks[nextIdx]
            return nextTok.kind == tkSymbol and nextTok.lex == "|"
          return false
      else:
        discard
    inc idx
  false


proc parseLambdaCaptures(p: Parser; startPos: Pos): seq[string] =
  ## Parse capture list contents after the opening '[' has been consumed
  if p.cur.kind == tkSymbol and p.cur.lex == "]":
    raise newParseError(startPos, "lambda capture list cannot be empty")

  var seenCaptures = initTable[string, bool]()
  while true:
    let captureTok = p.expect(tkIdent)
    if seenCaptures.hasKey(captureTok.lex):
      raise newParseError(p.posOf(captureTok), &"duplicate lambda capture '{captureTok.lex}'")
    seenCaptures[captureTok.lex] = true
    result.add(captureTok.lex)

    if p.cur.kind == tkSymbol:
      case p.cur.lex
      of ",":
        discard p.eat()
        if p.cur.kind == tkSymbol and p.cur.lex == "]":
          raise newParseError(startPos, "lambda capture list cannot end with a comma")
      of "]":
        discard p.eat()
        break
      else:
        raise newParseError(p.posOf(p.cur), "expected ',' or ']' in lambda capture list")
    else:
      raise newParseError(p.posOf(p.cur), "expected ',' or ']' in lambda capture list")


# Parses lambda expressions: [captures] |params| -> returnType { body }
proc parseLambdaExpression(p: Parser; startPos: Pos; hasCaptureList: bool = false; firstBarConsumed: bool = false): Expression =
  var captures: seq[string] = @[]

  if hasCaptureList:
    captures = p.parseLambdaCaptures(startPos)

  if not firstBarConsumed:
    discard p.expect(tkSymbol, "|")

  var params: seq[Param] = @[]
  if not (p.cur.kind == tkSymbol and p.cur.lex == "|"):
    while true:
      let paramName = p.expect(tkIdent).lex
      var paramType: EtchType = nil

      if p.cur.kind == tkSymbol and p.cur.lex == ":":
        discard p.eat()
        paramType = p.parseSingleType()

      var defaultValue = none(Expression)
      if p.cur.kind == tkSymbol and p.cur.lex == "=":
        discard p.eat()
        defaultValue = some(p.parseExpression())

      params.add(Param(name: paramName, typ: paramType, defaultValue: defaultValue))

      if p.cur.kind == tkSymbol and p.cur.lex == ",":
        discard p.eat()
      else:
        break

  discard p.expect(tkSymbol, "|")

  var returnType: EtchType = nil
  if p.cur.kind == tkSymbol and p.cur.lex == "->":
    discard p.eat()
    returnType = p.parseType()

  var body: seq[Statement] = @[]
  if p.cur.kind == tkSymbol and p.cur.lex == "{":
    body = p.parseExpressionBlock()
  else:
    let expr = p.parseExpression()
    body = @[Statement(kind: skExpression, sexpr: expr, pos: expr.pos)]

  Expression(
    kind: ekLambda,
    lambdaCaptures: captures,
    lambdaParams: params,
    lambdaReturnType: returnType,
    lambdaBody: body,
    lambdaCaptureTypes: @[],
    lambdaFunctionName: "",
    pos: startPos
  )


# Pattern helpers -------------------------------------------------------------

proc literalFromToken(p: Parser; t: Token): PatternLiteral =
  case t.kind
  of tkInt:
    PatternLiteral(kind: plInt, ival: parseBiggestInt(t.lex))
  of tkFloat:
    PatternLiteral(kind: plFloat, fval: parseFloat(t.lex))
  of tkString:
    PatternLiteral(kind: plString, sval: t.lex)
  of tkChar:
    if t.lex.len != 1:
      raise newParseError(p.posOf(t), "character literal must contain exactly one character")
    PatternLiteral(kind: plChar, cval: t.lex[0])
  else:
    raise newParseError(p.posOf(t), &"invalid literal in pattern: {friendlyTokenName(t.kind, t.lex)}")


proc buildLiteralOrRangePattern(p: Parser; first: PatternLiteral; pos: Pos): Pattern =
  if p.cur.kind == tkSymbol and (p.cur.lex == ".." or p.cur.lex == "..<"):
    let inclusive = p.cur.lex == ".."
    discard p.eat()
    let endTok = p.cur
    if endTok.kind == tkKeyword and (endTok.lex == "true" or endTok.lex == "false"):
      let endLit = PatternLiteral(kind: plBool, bval: endTok.lex == "true")
      discard p.eat()
      if first.kind != endLit.kind:
        raise newParseError(pos, "range bounds must have the same literal type")
      return Pattern(kind: pkRange, pos: pos, rangeStart: first, rangeEnd: endLit, endInclusive: inclusive)
    elif endTok.kind in {TokKind.tkInt, TokKind.tkFloat, TokKind.tkString, TokKind.tkChar}:
      let endLit = literalFromToken(p, endTok)
      discard p.eat()
      if first.kind != endLit.kind:
        raise newParseError(pos, "range bounds must have the same literal type")
      return Pattern(kind: pkRange, pos: pos, rangeStart: first, rangeEnd: endLit, endInclusive: inclusive)
    else:
      let actual = friendlyTokenName(endTok.kind, endTok.lex)
      raise newParseError(p.posOf(endTok), &"expected literal for range upper bound, got {actual}")
  else:
    Pattern(kind: pkLiteral, pos: pos, literal: first)


proc tryParseTypedIdentifierPattern(p: Parser; firstIdent: string; startPos: Pos): Option[Pattern] =
  # Try to parse identifier : type pattern
  if p.cur.kind == tkSymbol and p.cur.lex == ":":
    discard p.eat()  # consume ":"
    let typ = p.parseType()
    return some(Pattern(kind: pkType, pos: startPos, typePattern: typ, typeBind: firstIdent))
  else:
    return none(Pattern)

proc tryParseTypePattern(p: Parser): Option[Pattern] =
  let startIdx = p.i
  let startPos = p.posOf(p.cur)
  try:
    let typ = p.parseType()
    if not (p.cur.kind == tkSymbol and p.cur.lex == "("):
      p.i = startIdx
      return none(Pattern)
    discard p.eat()
    var bindName = ""
    if p.cur.kind == tkSymbol and p.cur.lex == ")":
      discard p.eat()
    else:
      bindName = p.expect(tkIdent).lex
      discard p.expect(tkSymbol, ")")
    return some(Pattern(kind: pkType, pos: startPos, typePattern: typ, typeBind: bindName))
  except ParseError:
    p.i = startIdx
    return none(Pattern)


proc parseTupleOrGroupPattern(p: Parser): Pattern =
  let startPos = p.posOf(p.cur)
  discard p.expect(tkSymbol, "(")
  if p.cur.kind == tkSymbol and p.cur.lex == ")":
    discard p.eat()
    return Pattern(kind: pkTuple, pos: startPos, tuplePatterns: @[])

  var elements: seq[Pattern] = @[p.parsePattern()]
  var isTuple = false

  while p.cur.kind == tkSymbol and p.cur.lex == ",":
    isTuple = true
    discard p.eat()
    if p.cur.kind == tkSymbol and p.cur.lex == ")":
      break
    elements.add(p.parsePattern())

  discard p.expect(tkSymbol, ")")

  if isTuple or elements.len > 1:
    return Pattern(kind: pkTuple, pos: startPos, tuplePatterns: elements)
  else:
    return elements[0]


proc parseArrayPattern(p: Parser): Pattern =
  let startPos = p.posOf(p.cur)
  discard p.expect(tkSymbol, "[")
  var elements: seq[Pattern] = @[]
  var hasSpread = false
  var spreadName = ""

  if not (p.cur.kind == tkSymbol and p.cur.lex == "]"):
    while true:
      if p.cur.kind == tkSymbol and p.cur.lex == "...":
        if hasSpread:
          raise newParseError(p.posOf(p.cur), "array pattern can only contain a single spread")
        hasSpread = true
        discard p.eat()
        if p.cur.kind == tkIdent:
          spreadName = p.expect(tkIdent).lex
          if spreadName == "_":
            spreadName = ""
        elif p.cur.kind == tkSymbol and (p.cur.lex == "," or p.cur.lex == "]"):
          spreadName = ""
        else:
          let actual = friendlyTokenName(p.cur.kind, p.cur.lex)
          raise newParseError(p.posOf(p.cur), &"expected identifier or ']' after '...', got {actual}")

        if not (p.cur.kind == tkSymbol and p.cur.lex == "]"):
          raise newParseError(p.posOf(p.cur), "spread capture must be the last element in array pattern")
        break
      else:
        elements.add(p.parsePattern())
        if p.cur.kind == tkSymbol and p.cur.lex == ",":
          discard p.eat()
          if p.cur.kind == tkSymbol and p.cur.lex == "]":
            break
          continue
        else:
          break

  discard p.expect(tkSymbol, "]")
  return Pattern(kind: pkArray, pos: startPos, arrayPatterns: elements, hasSpread: hasSpread, spreadName: spreadName)


proc parsePrimaryPattern(p: Parser): Pattern =
  let t = p.cur
  let pos = p.posOf(t)

  case t.kind
  of tkSymbol:
    case t.lex
    of "(":
      return parseTupleOrGroupPattern(p)
    of "[":
      return parseArrayPattern(p)
    of "_":
      discard p.eat()
      return Pattern(kind: pkWildcard, pos: pos)
    else:
      let actual = friendlyTokenName(t.kind, t.lex)
      raise newParseError(pos, &"unexpected symbol in pattern: {actual}")

  of tkInt, tkFloat, tkString, tkChar:
    discard p.eat()
    let lit = literalFromToken(p, t)
    return buildLiteralOrRangePattern(p, lit, pos)

  of tkKeyword:
    case t.lex
    of "true", "false":
      discard p.eat()
      let lit = PatternLiteral(kind: plBool, bval: t.lex == "true")
      return buildLiteralOrRangePattern(p, lit, pos)
    of "some":
      discard p.eat()
      discard p.expect(tkSymbol, "(")
      let inner = p.parsePattern()
      discard p.expect(tkSymbol, ")")
      return Pattern(kind: pkSome, pos: pos, innerPattern: some(inner))
    of "none":
      discard p.eat()
      return Pattern(kind: pkNone, pos: pos)
    of "ok":
      discard p.eat()
      discard p.expect(tkSymbol, "(")
      let inner = p.parsePattern()
      discard p.expect(tkSymbol, ")")
      return Pattern(kind: pkOk, pos: pos, innerPattern: some(inner))
    of "error":
      discard p.eat()
      discard p.expect(tkSymbol, "(")
      let inner = p.parsePattern()
      discard p.expect(tkSymbol, ")")
      return Pattern(kind: pkErr, pos: pos, innerPattern: some(inner))
    else:
      let maybeType = tryParseTypePattern(p)
      if maybeType.isSome:
        return maybeType.get()
      let actual = friendlyTokenName(t.kind, t.lex)
      raise newParseError(pos, &"unexpected keyword in pattern: {actual}")

  of tkIdent:
    if t.lex == "_":
      discard p.eat()
      return Pattern(kind: pkWildcard, pos: pos)

    # Check for enum pattern (TypeName.MemberName)
    let firstIdent = t.lex
    let afterEnumCheckIdx = p.i + 1  # Save position after consuming first identifier
    discard p.eat()  # consume the first identifier

    if p.cur.kind == tkSymbol and p.cur.lex == ".":
      discard p.eat()  # consume "."
      if p.cur.kind == tkIdent:
        let memberName = p.expect(tkIdent).lex
        return Pattern(kind: pkEnum, pos: pos, enumPattern: firstIdent & "." & memberName, enumType: nil, enumMember: none(EnumMember))
      else:
        raise newParseError(p.posOf(p.cur), "expected enum member name after '.'")

    # Reset position to try typed identifier pattern (identifier : type)
    p.i = afterEnumCheckIdx
    let maybeTypedIdent = tryParseTypedIdentifierPattern(p, firstIdent, pos)
    if maybeTypedIdent.isSome:
      return maybeTypedIdent.get()

    # Try type pattern: TypeName(binding)
    let maybeType = tryParseTypePattern(p)
    if maybeType.isSome:
      return maybeType.get()

    # Fall back to simple identifier pattern
    return Pattern(kind: pkIdentifier, pos: pos, bindName: firstIdent)

  else:
    let actual = friendlyTokenName(t.kind, t.lex)
    raise newParseError(pos, &"invalid token in pattern: {actual}")


proc parseAsPattern(p: Parser): Pattern =
  var pat = parsePrimaryPattern(p)
  while p.cur.kind == tkKeyword and p.cur.lex == "as":
    let asPos = p.posOf(p.cur)
    discard p.eat()
    let bindName = p.expect(tkIdent).lex
    pat = Pattern(kind: pkAs, pos: asPos, innerAsPattern: pat, asBind: bindName)
  return pat


proc parseOrPattern(p: Parser): Pattern =
  var pat = parseAsPattern(p)
  while p.cur.kind == tkSymbol and p.cur.lex == "|":
    let orPos = p.posOf(p.cur)
    discard p.eat()
    let rhs = parseAsPattern(p)
    if pat.kind == pkOr:
      pat.orPatterns.add(rhs)
    else:
      pat = Pattern(kind: pkOr, pos: orPos, orPatterns: @[pat, rhs])
  return pat


proc parsePattern(p: Parser): Pattern =
  parseOrPattern(p)


# Parses cast expressions: type(expr)
proc parseCastExpression(p: Parser; t: Token): Expression =
  discard p.eat() # consume (
  if p.cur.kind == tkSymbol and p.cur.lex == ")":
    raise newParseError(p.posOf(t), "cast expression cannot be empty")

  let castExpression = p.parseExpression()
  discard p.expect(tkSymbol, ")")
  let castType = case t.lex:
    of "bool": tBool()
    of "char": tChar()
    of "int": tInt()
    of "float": tFloat()
    of "string": tString()
    else: raise newParseError(p.posOf(t), "unknown cast type")

  # TODO - add error: raise newParseError(p.posOf(t), &"cast to {t.lex} expects 1 argument")

  return Expression(kind: ekCast, castType: castType, castExpression: castExpression, pos: p.posOf(t))


# Parses function call expressions: func(arg1, arg2, ...)
proc parseFunctionCallExpression(p: Parser; t: Token): Expression =
  var args: seq[Expression] = @[]
  discard p.eat() # consume (
  if not (p.cur.kind == tkSymbol and p.cur.lex == ")"):
    args.add p.parseExpression()
    while p.cur.kind == tkSymbol and p.cur.lex == ",":
      discard p.eat()
      args.add p.parseExpression()
  discard p.expect(tkSymbol, ")")
  let calleeExpr = Expression(kind: ekVar, vname: t.lex, pos: p.posOf(t))
  return Expression(kind: ekCall, fname: t.lex, args: args, callTarget: calleeExpr, callIsValue: false, pos: p.posOf(t))


# Parses identifier expressions (variables, function calls, or casts)
proc parseIdentifierExpression(p: Parser; t: Token): Expression =
  # Handle the case where we have identifier "." identifier - this could be:
  # 1. Enum member access: Color.Red (where Color is an enum type)
  # 2. UFCS field access: x.add (where x is a variable and add might be a method)

  # We need to be careful not to break UFCS calls like x.add(y)
  if p.cur.kind == tkSymbol and p.cur.lex == "." and (p.peek(1).kind == tkIdent or p.peek(1).kind == tkKeyword):
    # Look ahead to see if this is followed by parentheses (method call) or not (field access/enum access)
    let afterMember = p.peek(2)
    let looksLikeMethodCall = afterMember.kind == tkSymbol and afterMember.lex == "("

    if not looksLikeMethodCall:
      # This could be either enum member access (TypeName.MemberName) or UFCS field access (variable.field)
      # Let the main parsing loop handle it through parseUFCSCall, which will properly handle both cases
      # For now, just return the variable and let the dot be processed by the main expression parser
      # This preserves UFCS functionality while allowing enum types to be resolved later
      return Expression(kind: ekVar, vname: t.lex, pos: p.posOf(t))

  if p.cur.kind == tkSymbol and p.cur.lex == "(":
    # Check if this is a cast, object literal, or function call
    if t.lex in ["bool", "char", "int", "float", "string"]:
      return p.parseCastExpression(t)

    # Look ahead to distinguish between object literal Type(field: value) and function call func(arg)
    # Object literals have "identifier :" pattern after opening paren
    # Empty parentheses () are treated as function calls, not object literals
    let isObjectLiteral = (p.peek(1).kind == tkIdent and p.peek(2).kind == tkSymbol and p.peek(2).lex == ":")

    if isObjectLiteral:
      # Typed object literal: Type(field: value, ...)
      discard p.eat()  # consume (
      var fieldInits: seq[tuple[name: string, value: Expression]] = @[]
      if not (p.cur.kind == tkSymbol and p.cur.lex == ")"):
        while true:
          let fieldName = p.expect(tkIdent).lex
          discard p.expect(tkSymbol, ":")
          let fieldValue = p.parseExpression()
          fieldInits.add((name: fieldName, value: fieldValue))
          if p.cur.kind == tkSymbol and p.cur.lex == ",":
            discard p.eat()
          elif p.cur.kind == tkSymbol and p.cur.lex == ")":
            break
          else:
            let current = p.cur
            let actualName = friendlyTokenName(current.kind, current.lex)
            raise newParseError(p.posOf(current), &"expected ',' or ')', got {actualName}")
      discard p.expect(tkSymbol, ")")
      # Create typed object literal with the type name
      return Expression(kind: ekObjectLiteral, objectType: tUserDefined(t.lex), fieldInits: fieldInits, pos: p.posOf(t))
    else:
      # Regular function call
      return p.parseFunctionCallExpression(t)
  else:
    return Expression(kind: ekVar, vname: t.lex, pos: p.posOf(t))


# Parses symbol expressions (parentheses, arrays, unary operators)
proc parseSymbolExpression(p: Parser; t: Token): Expression =
  case t.lex
  of "(":
    # Could be either grouped expression (expr) or tuple literal (expr, expr, ...)
    let startPos = p.posOf(t)

    # Handle empty tuple ()
    if p.cur.kind == tkSymbol and p.cur.lex == ")":
      discard p.eat()
      return Expression(kind: ekTuple, tupleElements: @[], pos: startPos)

    # Parse first expression
    let firstExpression = p.parseExpression()

    # Check if it's a tuple (has comma) or just grouped expression
    if p.cur.kind == tkSymbol and p.cur.lex == ",":
      # It's a tuple literal
      var elements: seq[Expression] = @[firstExpression]
      while p.cur.kind == tkSymbol and p.cur.lex == ",":
        discard p.eat()  # consume ","
        # Allow trailing comma before )
        if p.cur.kind == tkSymbol and p.cur.lex == ")":
          break
        elements.add(p.parseExpression())
      discard p.expect(tkSymbol, ")")
      return Expression(kind: ekTuple, tupleElements: elements, pos: startPos)
    else:
      # Just a grouped expression
      discard p.expect(tkSymbol, ")")
      return firstExpression

  of "[":
    # Disambiguate between array literal [expr1, expr2] and lambda with captures [a,b] |x|
    # Look ahead to see if this is a lambda: [ captures ] | params |
    let isLambdaCandidate = tryParseLambdaStart(p)
    if isLambdaCandidate:
      # This is a lambda expression starting with capture list
      # tryParseLambdaStart doesn't change position, so we're still at '['
      return p.parseLambdaExpression(p.posOf(t), hasCaptureList = true)
    else:
      # This is an array literal: [expr1, expr2, ...]
      var elements: seq[Expression] = @[]
      if not (p.cur.kind == tkSymbol and p.cur.lex == "]"):
        elements.add p.parseExpression()
        while p.cur.kind == tkSymbol and p.cur.lex == ",":
          discard p.eat()
          elements.add p.parseExpression()
      discard p.expect(tkSymbol, "]")
      return Expression(kind: ekArray, elements: elements, pos: p.posOf(t))
  of "-":
    let e = p.parseExpression(6) # highest prefix binding
    return Expression(kind: ekUn, uop: uoNeg, ue: e, pos: p.posOf(t))

  of "@":
    let e = p.parseExpression(100)  # Maximum precedence
    return Expression(kind: ekDeref, refExpression: e, pos: p.posOf(t))

  of "#":
    let e = p.parseExpression(6)
    return Expression(kind: ekArrayLen, lenExpression: e, pos: p.posOf(t))

  of "{":
    # Object literal: { field1: expr1, field2: expr2 }
    var fieldInits: seq[tuple[name: string, value: Expression]] = @[]
    if not (p.cur.kind == tkSymbol and p.cur.lex == "}"):
      while true:
        let fieldName = p.expect(tkIdent).lex
        discard p.expect(tkSymbol, ":")
        let fieldValue = p.parseExpression()
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
    return Expression(kind: ekObjectLiteral, objectType: nil, fieldInits: fieldInits, pos: p.posOf(t))

  else:
    let actualName = friendlyTokenName(t.kind, t.lex)
    raise newParseError(p.posOf(t), &"unexpected {actualName}")


# Parses atomic expressions (null denotation - expressions that don't need a left operand)
proc parseAtomicExpression(p: Parser): Expression =
  let t = p.eat()
  case t.kind
  of tkInt, tkFloat, tkString, tkChar, tkBool:
    return p.parseLiteralExpression(t)
  of tkKeyword:
    if t.lex in ["bool", "char", "int", "float", "string"] and p.cur.kind == tkSymbol and p.cur.lex == "(":
      return p.parseCastExpression(t)
    else:
      return p.parseBuiltinKeywordExpression(t)
  of tkIdent:
    return p.parseIdentifierExpression(t)
  of tkSymbol:
    # Handle lambda expressions that start directly with |params|
    if t.lex == "|":
      return p.parseLambdaExpression(p.posOf(t), firstBarConsumed = true)
    else:
      return p.parseSymbolExpression(t)
  of tkEof:
    raise newParseError(Pos(line: t.line, col: t.col), "unexpected end of input")


# Parses array indexing or slicing: expr[index] or expr[start:end] or expr[:end]
proc parseArrayAccessOrSlice(p: Parser; left: Expression; t: Token): Expression =
  if p.cur.kind == tkSymbol and p.cur.lex == ":":
    # Slicing from start: expr[:end]
    discard p.eat()  # consume ":"
    let endExpression = if p.cur.kind == tkSymbol and p.cur.lex == "]": none(Expression) else: some(p.parseExpression())
    discard p.expect(tkSymbol, "]")
    return Expression(kind: ekSlice, sliceExpression: left, startExpression: none(Expression), endExpression: endExpression, pos: p.posOf(t))
  else:
    let firstExpression = p.parseExpression()
    if p.cur.kind == tkSymbol and p.cur.lex == ":":
      # Slicing: expr[start:end]
      discard p.eat()  # consume ":"
      let endExpression = if p.cur.kind == tkSymbol and p.cur.lex == "]": none(Expression) else: some(p.parseExpression())
      discard p.expect(tkSymbol, "]")
      return Expression(kind: ekSlice, sliceExpression: left, startExpression: some(firstExpression), endExpression: endExpression, pos: p.posOf(t))
    else:
      # Simple indexing: expr[index]
      discard p.expect(tkSymbol, "]")
      return Expression(kind: ekIndex, arrayExpression: left, indexExpression: firstExpression, pos: p.posOf(t))


# Parses UFCS method calls: obj.method() or field access: obj.field
proc parseUFCSCall(p: Parser; obj: Expression; t: Token): Expression =
  # Allow keywords (like 'string', 'int') used as cast-like UFCS methods
  var fieldOrMethodNameToken = p.cur
  if not (fieldOrMethodNameToken.kind in {tkIdent, tkKeyword}):
    let actualName = friendlyTokenName(fieldOrMethodNameToken.kind, fieldOrMethodNameToken.lex)
    raise newParseError(p.posOf(fieldOrMethodNameToken), &"expected identifier, got {actualName}")
  discard p.eat()
  let fieldOrMethodName = fieldOrMethodNameToken.lex

  # Check if followed by parentheses (method call) or not (field access)
  if p.cur.kind == tkSymbol and p.cur.lex == "(":
    # Method call: obj.method(args...)
    # Check for UFCS-style cast: obj.string(), obj.int(), etc.
    if fieldOrMethodName in ["bool", "char", "int", "float", "string"]:
      # Parse "()" and ensure there are no arguments for cast-style UFCS
      discard p.eat()  # consume "("
      if not (p.cur.kind == tkSymbol and p.cur.lex == ")"):
        let current = p.cur
        let actualName = friendlyTokenName(current.kind, current.lex)
        raise newParseError(p.posOf(current), &"unexpected argument to cast method {actualName}, expected no arguments")
      discard p.eat()  # consume ")"
      let castType = case fieldOrMethodName
                     of "bool": tBool()
                     of "char": tChar()
                     of "int": tInt()
                     of "float": tFloat()
                     else: tString()
      return Expression(kind: ekCast, castType: castType, castExpression: obj, pos: p.posOf(t))

    # Transform into method(obj, args...)
    var args: seq[Expression] = @[obj]  # object becomes first argument
    discard p.eat()  # consume "("
    if not (p.cur.kind == tkSymbol and p.cur.lex == ")"):
      args.add p.parseExpression()
      while p.cur.kind == tkSymbol and p.cur.lex == ",":
        discard p.eat()
        args.add p.parseExpression()
    discard p.expect(tkSymbol, ")")
    let calleeExpr = Expression(kind: ekVar, vname: fieldOrMethodName, pos: p.posOf(t))
    return Expression(kind: ekCall, fname: fieldOrMethodName, args: args, callTarget: calleeExpr, callIsValue: false, pos: p.posOf(t))
  else:
    # Field access: obj.field
    return Expression(kind: ekFieldAccess, objectExpression: obj, fieldName: fieldOrMethodName, pos: p.posOf(t))


# Parses infix expressions (left denotation - expressions that need a left operand)
proc parseInfixExpression(p: Parser; left: Expression; t: Token): Expression =
  let op = t.lex
  if op in ["+","-","*","/","%","==","!=","<",">","<=",">=","and","or","in"]:
    let binOp = binaryOp(op, p.posOf(t))
    let right = p.parseExpression(getOperatorPrecedence(op))
    return Expression(kind: ekBin, bop: binOp, lhs: left, rhs: right, pos: p.posOf(t))
  if op == "[":
    return p.parseArrayAccessOrSlice(left, t)
  if op == ".":
    return p.parseUFCSCall(left, t)
  if op == "->":
    # Channel send: channel -> value
    let right = p.parseExpression(getOperatorPrecedence(op))
    return Expression(kind: ekChannelSend, sendChannel: left, sendValue: right, pos: p.posOf(t))
  if op == "<-":
    # Channel receive: channel <- (this is a postfix operator, so left is the channel)
    return Expression(kind: ekChannelRecv, recvChannel: left, pos: p.posOf(t))
  raise newParseError(p.posOf(t), &"unexpected operator: {op}")


# Parse expressions using Pratt parsing
proc parseExpression*(p: Parser; rbp=0): Expression =
  var left = p.parseAtomicExpression()
  while true:
    let t = p.cur
    # Check for "not in" operator (two keywords)
    if t.kind == tkKeyword and t.lex == "not" and p.peek().kind == tkKeyword and p.peek().lex == "in":
      if getOperatorPrecedence("not in") <= rbp: break
      discard p.eat()  # consume "not"
      discard p.eat()  # consume "in"
      var right = p.parseExpression(getOperatorPrecedence("not in"))
      left = Expression(kind: ekBin, bop: boNotIn, lhs: left, rhs: right, pos: p.posOf(t))
    elif t.kind == tkSymbol and t.lex == "?":
      let postfixPrec = 9
      if postfixPrec <= rbp:
        break
      discard p.eat()
      left = Expression(kind: ekResultPropagate, propagateExpression: left, pos: p.posOf(t))
    elif (t.kind == tkSymbol and t.lex in ["+","-","*","/","%","==","!=","<",">","<=",">=","[",".","->","<-"]) or (t.kind == tkKeyword and t.lex in ["and", "or", "in"]):
      if getOperatorPrecedence(t.lex) <= rbp: break
      discard p.eat()
      left = p.parseInfixExpression(left, t)
    else:
      break
  left


# Parse blocks and statements
proc parseBlock(p: Parser): seq[Statement] =
  var body: seq[Statement] = @[]
  discard p.expect(tkSymbol, "{")
  while not (p.cur.kind == tkSymbol and p.cur.lex == "}"):
    body.add p.parseStatement()
  discard p.expect(tkSymbol, "}")
  body


# Parses a block used inside expressions (match arms, if branches) where the
# final expression may omit the trailing semicolon.
proc parseExpressionBlock(p: Parser): seq[Statement] =
  var body: seq[Statement] = @[]
  discard p.expect(tkSymbol, "{")
  while true:
    if p.cur.kind == tkSymbol and p.cur.lex == "}":
      discard p.eat()
      break

    var consumedImplicitExpr = false
    let snapshot = p.i
    var expr: Expression
    var parsedExpr = false
    try:
      expr = p.parseExpression()
      parsedExpr = true
    except ParseError:
      parsedExpr = false
      p.i = snapshot

    if parsedExpr:
      if p.cur.kind == tkSymbol and p.cur.lex == "}":
        body.add(Statement(kind: skExpression, sexpr: expr, pos: expr.pos))
        discard p.eat()
        consumedImplicitExpr = true
      else:
        p.i = snapshot

    if consumedImplicitExpr:
      break

    body.add(p.parseStatement())
  body


# Parse var and let declarations
proc parseVarDecl(p: Parser; vflag: VarFlag): Statement =
  # Check for tuple unpacking: let [a, b, c] = ...
  if p.cur.kind == tkSymbol and p.cur.lex == "[":
    let startPos = p.posOf(p.cur)
    discard p.eat()  # consume "["

    var names: seq[string] = @[]
    var types: seq[EtchType] = @[]

    # Parse variable names
    if not (p.cur.kind == tkSymbol and p.cur.lex == "]"):
      names.add(p.expect(tkIdent).lex)
      types.add(nil)  # No type annotation by default

      while p.cur.kind == tkSymbol and p.cur.lex == ",":
        discard p.eat()  # consume ","
        names.add(p.expect(tkIdent).lex)
        types.add(nil)

    discard p.expect(tkSymbol, "]")

    # Tuple unpacking requires initialization
    if not (p.cur.kind == tkSymbol and p.cur.lex == "="):
      raise newParseError(startPos, "tuple unpacking requires initialization")

    discard p.eat()  # consume "="
    let init = p.parseExpression()
    discard p.expect(tkSymbol, ";")

    return Statement(kind: skTupleUnpack, tupFlag: vflag, tupNames: names, tupTypes: types, tupInit: init, pos: startPos)

  # Check for object unpacking: let {x, y} = ... or let {x: newX, y: newY} = ...
  if p.cur.kind == tkSymbol and p.cur.lex == "{":
    let startPos = p.posOf(p.cur)
    discard p.eat()  # consume "{"

    var fieldMappings: seq[tuple[fieldName: string, varName: string]] = @[]

    # Parse field mappings
    if not (p.cur.kind == tkSymbol and p.cur.lex == "}"):
      while true:
        let fieldName = p.expect(tkIdent).lex

        # Check for rename syntax: {field: varName}
        if p.cur.kind == tkSymbol and p.cur.lex == ":":
          discard p.eat()  # consume ":"
          let varName = p.expect(tkIdent).lex
          fieldMappings.add((fieldName: fieldName, varName: varName))
        else:
          # No rename, use field name as variable name
          fieldMappings.add((fieldName: fieldName, varName: fieldName))

        # Check for comma or end
        if p.cur.kind == tkSymbol and p.cur.lex == ",":
          discard p.eat()  # consume ","
        elif p.cur.kind == tkSymbol and p.cur.lex == "}":
          break
        else:
          let current = p.cur
          let actualName = friendlyTokenName(current.kind, current.lex)
          raise newParseError(p.posOf(current), &"expected ',' or '}}', got {actualName}")

    discard p.expect(tkSymbol, "}")

    # Object unpacking requires initialization
    if not (p.cur.kind == tkSymbol and p.cur.lex == "="):
      raise newParseError(startPos, "object unpacking requires initialization")

    discard p.eat()  # consume "="
    let init = p.parseExpression()
    discard p.expect(tkSymbol, ";")

    var types: seq[EtchType] = @[]
    for i in 0..<fieldMappings.len:
      types.add(nil)  # Types will be resolved during type checking

    return Statement(kind: skObjectUnpack, objFlag: vflag, objFieldMappings: fieldMappings, objTypes: types, objInit: init, pos: startPos)

  # Regular single variable declaration
  let tname = p.expect(tkIdent)
  var ty: EtchType = nil
  var ini: Option[Expression] = none(Expression)

  # Check if type annotation is provided
  if p.cur.kind == tkSymbol and p.cur.lex == ":":
    discard p.eat()  # consume ":"
    ty = p.parseType()

  # Check for initialization
  if p.cur.kind == tkSymbol and p.cur.lex == "=":
    discard p.eat()  # consume "="
    ini = some(p.parseExpression())

    # If no type annotation provided, try to infer from initializer
    if ty == nil:
      ty = inferTypeFromExpression(ini.get())
      if ty == nil:
          # Use deferred inference for complex expressions that need type checker context
          ty = tInferred()
  elif ty == nil:
    # No type annotation and no initializer
    raise newParseError(p.posOf(tname), &"variable '{tname.lex}' requires either type annotation or initializer for type inference")

  discard p.expect(tkSymbol, ";")
  Statement(kind: skVar, vflag: vflag, vname: tname.lex, vtype: ty, vinit: ini, pos: p.posOf(tname))


# Parse if statements with elif and else branches
proc parseIf(p: Parser): Statement =
  let k = p.expect(tkKeyword, "if")
  let cond = p.parseExpression()
  let thn = p.parseBlock()

  # Parse elif chain
  var elifChain: seq[tuple[cond: Expression, body: seq[Statement]]] = @[]
  while p.cur.kind == tkKeyword and p.cur.lex == "elif":
    discard p.eat()  # consume "elif"
    let elifCond = p.parseExpression()
    let elifBody = p.parseBlock()
    elifChain.add((cond: elifCond, body: elifBody))

  # Parse else if present
  var els: seq[Statement] = @[]
  if p.cur.kind == tkKeyword and p.cur.lex == "else":
    discard p.eat()
    els = p.parseBlock()

  Statement(kind: skIf, cond: cond, thenBody: thn, elifChain: elifChain, elseBody: els, pos: p.posOf(k))


# Parse while loops
proc parseWhile(p: Parser): Statement =
  let k = p.expect(tkKeyword, "while")
  let c = p.parseExpression()
  let b = p.parseBlock()
  Statement(kind: skWhile, wcond: c, wbody: b, pos: p.posOf(k))


# Parse for loops (both range and array iteration)
proc parseFor(p: Parser): Statement =
  let k = p.expect(tkKeyword, "for")
  let varname = p.expect(tkIdent).lex
  discard p.expect(tkKeyword, "in")

  # Parse the iteration target
  let firstExpression = p.parseExpression()

  # Check if this is a range (..) or (..<) or array iteration
  if p.cur.kind == tkSymbol and (p.cur.lex == ".." or p.cur.lex == "..<"):
    # Range iteration: for x in start..end or for x in start..<end
    let isInclusive = p.cur.lex == ".."
    discard p.eat()  # consume ".." or "..<"
    let endExpression = p.parseExpression()
    let body = p.parseBlock()
    Statement(kind: skFor, fvar: varname, fstart: some(firstExpression), fend: some(endExpression), farray: none(Expression), finclusive: isInclusive, fbody: body, pos: p.posOf(k))
  else:
    # Array iteration: for x in array
    let body = p.parseBlock()
    Statement(kind: skFor, fvar: varname, fstart: none(Expression), fend: none(Expression), farray: some(firstExpression), finclusive: true, fbody: body, pos: p.posOf(k))


# Parse break, return, discard, comptime, and import statements
proc parseBreak(p: Parser): Statement =
  let k = p.expect(tkKeyword, "break")
  discard p.expect(tkSymbol, ";")
  Statement(kind: skBreak, pos: p.posOf(k))


proc parseReturn(p: Parser): Statement =
  let k = p.expect(tkKeyword, "return")
  var e: Option[Expression] = none(Expression)
  if not (p.cur.kind == tkSymbol and p.cur.lex == ";"):
    e = some(p.parseExpression())
  discard p.expect(tkSymbol, ";")
  Statement(kind: skReturn, re: e, pos: p.posOf(k))


proc parseDiscard(p: Parser): Statement =
  let k = p.expect(tkKeyword, "discard")
  var exprs: seq[Expression] = @[]
  if not (p.cur.kind == tkSymbol and p.cur.lex == ";"):
    exprs.add(p.parseExpression())
    while p.cur.kind == tkSymbol and p.cur.lex == ",":
      discard p.eat()  # consume ","
      exprs.add(p.parseExpression())
  discard p.expect(tkSymbol, ";")
  Statement(kind: skDiscard, dexprs: exprs, pos: p.posOf(k))


proc parseComptime(p: Parser): Statement =
  let k = p.expect(tkKeyword, "comptime")
  let body = p.parseBlock()
  Statement(kind: skComptime, cbody: body, pos: p.posOf(k))


proc parseDefer(p: Parser): Statement =
  let k = p.expect(tkKeyword, "defer")
  let body = p.parseBlock()
  Statement(kind: skDefer, deferBody: body, pos: p.posOf(k))


proc parseImport(p: Parser): Statement =
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
  # Check for host function import: "import host" for host-provided functions
  elif p.cur.kind == tkIdent and p.cur.lex == "host":
    discard p.eat()  # consume "host"
    importKind = "host"  # Host functions
    importPath = "host"  # Standard host namespace
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
    if not importPath.endsWith(SOURCE_FILE_EXTENSION) and not importPath.endsWith("/"):
      importPath = importPath & SOURCE_FILE_EXTENSION

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
        alias: "",
        pos: pos
      ))

    # Return with special marker to indicate multi-module import
    return Statement(
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
        alias: "",
        pos: pos
      )

      # Parse function signature if it's a function
      if itemKind == "function" and p.cur.kind == tkSymbol and p.cur.lex == "(":
        discard p.eat()  # consume "("

        var params: seq[Param] = @[]
        while p.cur.kind != tkSymbol or p.cur.lex != ")":
          let paramName = p.expect(tkIdent).lex
          discard p.expect(tkSymbol, ":")
          let paramType = p.parseType()
          params.add(Param(name: paramName, typ: paramType, defaultValue: none(Expression)))

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

  return Statement(
    kind: skImport,
    importKind: importKind,
    importPath: importPath,
    importItems: items,
    pos: pos
  )


# Parse simple statements: assignments or expression statements (assignments or call expressions)
const compoundAssignSymbols = ["+=","-=","*=","/=","%="]

proc binOpFromCompoundSymbol(sym: string): BinOp =
  case sym
  of "+=": boAdd
  of "-=": boSub
  of "*=": boMul
  of "/=": boDiv
  of "%=": boMod
  else:
    raise newException(ValueError, "unsupported compound assignment symbol")
proc parseSimpleStatement(p: Parser): Statement =
  let start = p.cur

  # Try to detect assignment: either simple identifier, field access, or array index followed by =
  # We need to look ahead to see if we have an assignment pattern
  var isAssignment = false
  var lookAheadIdx = 0

  # Check for simple identifier assignment (x = ...)
  if start.kind == tkIdent and p.peek().kind == tkSymbol and (p.peek().lex == "=" or p.peek().lex in compoundAssignSymbols):
    isAssignment = true

  # Check for array index assignment (arr[idx] = ... or arr[idx] op= ...)
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
            # Found matching ], check for assignment operator
            if p.peek(lookAheadIdx + 1).kind == tkSymbol and (p.peek(lookAheadIdx + 1).lex == "=" or p.peek(lookAheadIdx + 1).lex in compoundAssignSymbols):
              isAssignment = true
            break
      lookAheadIdx += 1

  # Check for field assignment (obj.field = ... or obj.field op= ...)
  elif start.kind == tkIdent:
    # Look for pattern: identifier . identifier =
    # We might have multiple field accesses: obj.field1.field2 = ...
    lookAheadIdx = 1
    while p.peek(lookAheadIdx).kind == tkSymbol and p.peek(lookAheadIdx).lex == ".":
      if p.peek(lookAheadIdx + 1).kind != tkIdent:
        break
      lookAheadIdx += 2
      if p.peek(lookAheadIdx).kind == tkSymbol and (p.peek(lookAheadIdx).lex == "=" or p.peek(lookAheadIdx).lex in compoundAssignSymbols):
        isAssignment = true
        break
  elif start.kind == tkSymbol and start.lex == "@":
    # Support assignments to dereferenced references, e.g. @x = value
    var idx = 1
    var depthParen = 0
    var depthBracket = 0
    var depthBrace = 0
    while true:
      let tok = p.peek(idx)
      if tok.kind == tkEof:
        break
      if tok.kind == tkSymbol:
        case tok.lex
        of "(": inc depthParen
        of ")":
          if depthParen > 0: dec depthParen
        of "[": inc depthBracket
        of "]":
          if depthBracket > 0: dec depthBracket
        of "{": inc depthBrace
        of "}":
          if depthBrace > 0: dec depthBrace
        of "=":
          if depthParen == 0 and depthBracket == 0 and depthBrace == 0:
            isAssignment = true
            lookAheadIdx = -1
            break
        else:
          discard
      if tok.kind == tkSymbol and tok.lex == ";":
        break
      inc idx

  if isAssignment:
    if lookAheadIdx == 0:
      # Simple identifier assignment
      let n = p.eat()
      if p.cur.kind == tkSymbol and p.cur.lex in compoundAssignSymbols:
        let opTok = p.eat()
        let rhsExpr = p.parseExpression()
        discard p.expect(tkSymbol, ";")
        return Statement(
          kind: skCompoundAssign,
          caname: n.lex,
          cop: binOpFromCompoundSymbol(opTok.lex),
          crhs: rhsExpr,
          pos: p.posOf(opTok)
        )

      discard p.expect(tkSymbol, "=")
      let e = p.parseExpression()
      discard p.expect(tkSymbol, ";")

      if e.kind == ekBin and e.lhs.kind == ekVar and e.lhs.vname == n.lex and e.bop in {boAdd, boSub, boMul, boDiv, boMod}:
        return Statement(
          kind: skCompoundAssign,
          caname: n.lex,
          cop: e.bop,
          crhs: e.rhs,
          pos: e.pos
        )

      return Statement(kind: skAssign, aname: n.lex, aval: e, pos: p.posOf(n))
    else:
      # Field or array index assignment - parse left side as expression
      let leftExpression = p.parseExpression()

      if p.cur.kind == tkSymbol and p.cur.lex in compoundAssignSymbols:
        let opTok = p.eat()
        let rhsExpression = p.parseExpression()
        discard p.expect(tkSymbol, ";")
        let binExpr = Expression(
          kind: ekBin,
          bop: binOpFromCompoundSymbol(opTok.lex),
          lhs: leftExpression,
          rhs: rhsExpression,
          pos: p.posOf(opTok)
        )
        return Statement(kind: skFieldAssign,
                    faTarget: leftExpression,
                    faValue: binExpr,
                    pos: p.posOf(start))

      discard p.expect(tkSymbol, "=")
      let rightExpression = p.parseExpression()
      discard p.expect(tkSymbol, ";")

      # Create appropriate assignment statement based on left expression type
      if leftExpression.kind in {ekFieldAccess, ekIndex, ekDeref}:
        # Nested field access: p.sub.field = value
        # Array index assignment: arr[idx] = value
        return Statement(kind: skFieldAssign,
                    faTarget: leftExpression,
                    faValue: rightExpression,
                    pos: p.posOf(start))
      else:
        raise newParseError(p.posOf(start), "invalid assignment target")
  else:
    let e = p.parseExpression()
    # If the expression is a match expression, allow it to be used as a
    # statement without requiring a trailing semicolon. This mirrors the
    # behavior of other control flow statements like if/while/for and keeps
    # match expressions convenient to use as statements.
    if e.kind == ekMatch:
      # Consume optional semicolon if present
      if p.cur.kind == tkSymbol and p.cur.lex == ";":
        discard p.eat()
    else:
      discard p.expect(tkSymbol, ";")
    return Statement(kind: skExpression, sexpr: e, pos: p.posOf(start))


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
proc parseTypeDecl(p: Parser): Statement =
  let start = p.expect(tkKeyword, "type")
  let typeName = p.expect(tkIdent).lex
  discard p.expect(tkSymbol, "=")

  # Check if it's a distinct type or enum
  var typeKind = tdkAlias
  var aliasTarget: EtchType = nil
  var objectFields: seq[ObjectField] = @[]
  var enumMembers: seq[EnumMember] = @[]

  if p.cur.kind == tkKeyword and p.cur.lex == "distinct":
    discard p.eat()  # consume "distinct"
    typeKind = tdkDistinct
    aliasTarget = p.parseType()
  elif p.cur.kind == tkKeyword and p.cur.lex == "object":
    discard p.eat()  # consume "object"
    typeKind = tdkObject

    # Parse object body
    discard p.expect(tkSymbol, "{")
    while p.cur.kind != tkSymbol or p.cur.lex != "}":
      let fieldName = p.expect(tkIdent).lex
      discard p.expect(tkSymbol, ":")
      let fieldType = p.parseType()

      # Check for default value
      var defaultValue = none(Expression)
      if p.cur.kind == tkSymbol and p.cur.lex == "=":
        discard p.eat()  # consume "="
        defaultValue = some(p.parseExpression())

      objectFields.add(ObjectField(
        name: fieldName,
        fieldType: fieldType,
        defaultValue: defaultValue
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
  elif p.cur.kind == tkKeyword and p.cur.lex == "enum":
    discard p.eat()  # consume "enum"
    typeKind = tdkEnum

    # Parse enum body
    discard p.expect(tkSymbol, "{")
    var currentValue: int64 = 0

    while p.cur.kind != tkSymbol or p.cur.lex != "}":
      let memberName = p.expect(tkIdent).lex

      var resolvedInt: int64 = currentValue
      var hasExplicitInt = false
      var resolvedString = none(string)

      # Check for explicit value assignment
      if p.cur.kind == tkSymbol and p.cur.lex == "=":
        discard p.eat()  # consume "="

        # Check for tuple syntax: (100, "TheD")
        if p.cur.kind == tkSymbol and p.cur.lex == "(":
          discard p.eat()  # consume "("
          # Parse first part: integer value
          let intToken = p.expect(tkInt)
          resolvedInt = parseBiggestInt(intToken.lex)
          hasExplicitInt = true
          discard p.expect(tkSymbol, ",")  # consume ","
          # Parse second part: string value
          let stringToken = p.expect(tkString)
          resolvedString = some(stringToken.lex)
          discard p.expect(tkSymbol, ")")  # consume ")"
        elif p.cur.kind == tkInt:
          let intToken = p.expect(tkInt)
          resolvedInt = parseBiggestInt(intToken.lex)
          hasExplicitInt = true
        elif p.cur.kind == tkString:
          let stringToken = p.expect(tkString)
          resolvedString = some(stringToken.lex)
        else:
          let t = p.cur
          let actualName = friendlyTokenName(t.kind, t.lex)
          raise newParseError(p.posOf(t), &"expected integer, string, or tuple for enum member value, got {actualName}")
      # Auto-assign integer value if none provided explicitly
      if not hasExplicitInt:
        resolvedInt = currentValue

      currentValue = resolvedInt + 1

      enumMembers.add(EnumMember(
        name: memberName,
        intValue: resolvedInt,
        stringValue: resolvedString
      ))

      # Handle member separator
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

  return Statement(
    kind: skTypeDecl,
    typeName: typeName,
    typeKind: typeKind,
    aliasTarget: aliasTarget,
    objectFields: objectFields,
    enumMembers: enumMembers,
    pos: p.posOf(start)
  )


# Parse function declarations
proc parseFn(p: Parser; prog: Program; isExported: bool = false) =
  let fnPos = p.posOf(p.cur)
  discard p.expect(tkKeyword, "fn")

  # Check for destructor syntax: fn ~(obj: Type)
  var isDestructor = false
  if p.cur.kind == tkSymbol and p.cur.lex == "~":
    isDestructor = true
    discard p.eat()  # consume "~"

  # Allow operator symbols as function names for operator overloading
  let nameToken = p.cur
  var name: string
  if isDestructor:
    name = "~"  # temporary placeholder
  elif nameToken.kind == tkIdent:
    name = p.eat().lex
  elif nameToken.kind == tkSymbol and nameToken.lex in ["+", "-", "*", "/", "%", "==", "!=", "<", "<=", ">", ">="]:
    name = p.eat().lex
  else:
    let actualName = friendlyTokenName(nameToken.kind, nameToken.lex)
    raise newParseError(p.posOf(nameToken), &"expected function name or operator symbol, got {actualName}")

  # Track generic parameters for type parsing
  let tps = p.parseTyParams()
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
      var defaultValue = none(Expression)
      if p.cur.kind == tkSymbol and p.cur.lex == "=":
        discard p.eat()  # consume "="
        defaultValue = some(p.parseExpression())

      ps.add Param(name: pn, typ: pt, defaultValue: defaultValue)
      if p.cur.kind == tkSymbol and p.cur.lex == ",":
        discard p.eat()
      else: break
  discard p.expect(tkSymbol, ")")

  # Validate destructor constraints
  if isDestructor:
    if ps.len != 1:
      raise newParseError(p.posOf(nameToken), "destructor must have exactly one parameter")
    if ps[0].typ.kind != tkObject and ps[0].typ.kind != tkUserDefined:
      raise newParseError(p.posOf(nameToken), "destructor parameter must be an object type")
    # Set destructor name based on type: ~TypeName
    let typeName = ps[0].typ.name
    name = "~" & typeName

  # Return type is optional - if -> is present, parse it, otherwise infer from body
  var rt: EtchType = nil
  var hasExplicitReturnType = false
  if p.cur.kind == tkSymbol and p.cur.lex == "->":
    discard p.eat()  # consume "->"
    let returnTypeStartsWithFn = (p.cur.kind == tkKeyword and p.cur.lex == "fn")
    let returnStartPos = p.posOf(p.cur)
    rt = p.parseType()
    hasExplicitReturnType = true
    if returnTypeStartsWithFn and rt != nil and rt.kind == tkFunction:
      raise newParseError(returnStartPos,
        "function return types that are themselves functions must be parenthesized like '-> (fn(...) -> ...)' to avoid ambiguity")

  # Validate destructor return type
  if isDestructor:
    if rt != nil and rt.kind != tkVoid:
      raise newParseError(p.posOf(nameToken), "destructor must return void")
    rt = tVoid()  # Ensure return type is void
    hasExplicitReturnType = true

  let body = p.parseBlock()
  let fd = FunctionDeclaration(
    name: name,
    typarams: tps,
    params: ps,
    ret: rt,
    hasExplicitReturnType: hasExplicitReturnType,
    body: body,
    isExported: isExported,
    pos: fnPos)
  prog.addFunction(fd)
  # Clear generic parameters after parsing the function
  p.genericParams.setLen(0)


# Parse a single statement
proc parseStatement*(p: Parser): Statement =
  # Handle unnamed scope blocks: { ... }
  if p.cur.kind == tkSymbol and p.cur.lex == "{":
    let startPos = p.posOf(p.cur)
    let blockStatements = p.parseBlock()
    return Statement(
      kind: skBlock,
      blockBody: blockStatements,
      blockHoistedVars: @[],
      pos: startPos
    )

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
    of "defer": return p.parseDefer()
    of "type": return p.parseTypeDecl()
    of "import": return p.parseImport()
    else: discard # fallthrough to simple
  return p.parseSimpleStatement()


# Parse an entire program from a sequence of tokens
proc parseProgram*(toks: seq[Token], filename: string = "<unknown>"): Program =
  var p = Parser(toks: toks, i: 0, filename: filename, genericParams: @[])
  result = Program(
    funs: initTable[string, seq[FunctionDeclaration]](),
    funInstances: initTable[string, FunctionDeclaration](),
    globals: @[],
    types: initTable[string, EtchType](),
    lambdaCounter: 0
  )

  # Register all builtins automatically - they don't need to be imported
  for name in getBuiltinNames():
    let (paramTypes, returnType) = getBuiltinSignature(name)
    var params: seq[Param] = @[]
    for i, pType in paramTypes:
      params.add(Param(name: "arg" & $i, typ: pType, defaultValue: none(Expression)))

    let funcDecl = FunctionDeclaration(
      name: name,
      typarams: @[],
      params: params,
      ret: returnType,
      hasExplicitReturnType: true,
      body: @[],  # Empty body - will be handled as builtin
      isBuiltin: true
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
      let st = p.parseStatement()
      if isExported:
        st.isExported = true
      result.globals.add st
    elif p.cur.kind == tkKeyword and p.cur.lex == "type":
      if isExported:
        let pos = p.posOf(p.cur)
        raise newParseError(pos, "'export' modifier is not allowed on type declarations")
      let typeDecl = p.parseTypeDecl()
      # Process the type declaration and add to types table
      case typeDecl.typeKind
      of tdkAlias:
        result.types[typeDecl.typeName] = typeDecl.aliasTarget
      of tdkDistinct:
        result.types[typeDecl.typeName] = tDistinct(typeDecl.typeName, typeDecl.aliasTarget)
      of tdkObject:
        result.types[typeDecl.typeName] = tObject(typeDecl.typeName, typeDecl.objectFields)
      of tdkEnum:
        result.types[typeDecl.typeName] = tEnum(typeDecl.typeName, typeDecl.enumMembers)

      # Add to globals so the compiler processes type declarations
      result.globals.add typeDecl
    elif p.cur.kind == tkKeyword and p.cur.lex == "import":
      let importStatement = p.parseImport()

      # Handle multi-module imports by expanding them
      if importStatement.importKind == "multi-module":
        # Remove .etch extension from importPath if present for the base path
        let basePath = if importStatement.importPath.endsWith(SOURCE_FILE_EXTENSION):
          importStatement.importPath[0..^6]
        else:
          importStatement.importPath

        # Create individual import statements for each module
        for item in importStatement.importItems:
          if item.itemKind == "module":
            let fullPath = basePath & "/" & item.name & SOURCE_FILE_EXTENSION
            result.globals.add Statement(
              kind: skImport,
              importKind: "module",
              importPath: fullPath,
              importItems: @[],
              pos: importStatement.pos
            )
      else:
        result.globals.add importStatement  # Add import to globals for processing
    else:
      # top-level expr stmt not allowed, give error
      let t = p.cur
      let actualName = friendlyTokenName(t.kind, t.lex)
      raise newParseError(Pos(line: t.line, col: t.col), &"unexpected {actualName} at top-level")
