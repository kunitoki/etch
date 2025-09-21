# lexer.nim
# PEG (npeg) based tokenizer for Etch

import std/[strformat, sequtils, strutils]

type
  TokKind* = enum
    tkIdent, tkInt, tkFloat, tkString, tkBool, tkKeyword, tkSymbol, tkEof
  Token* = object
    kind*: TokKind
    lex*: string
    line*, col*: int

const keywords = [
  "fn","let","var","return","if","elif","else","while",
  "true","false","int","float","string","bool","void","ref","concept",
  "comptime","new","and","or","array","nil"
].toSeq

proc isKeyword(w: string): bool = w in keywords

proc lex*(src: string): seq[Token] =
  var line = 1
  var col  = 1

  var i = 0
  while i < src.len:
    # Skip whitespace manually to track line/col
    if src[i] in {' ', '\t', '\r', '\n'}:
      if src[i] == '\n': inc line; col = 1 else: inc col
      inc i
      continue

    # Skip // comment
    if i+1 < src.len and src[i] == '/' and src[i+1] == '/':
      while i < src.len and src[i] != '\n': inc i
      continue

    var m: int
    # 2-char symbol
    if i+1 < src.len and (src.substr(i, i+1) in ["->","==","!=", "<=",">="]):
      result.add Token(kind: tkSymbol, lex: src.substr(i, i+1), line: line, col: col)
      inc i, 2; inc col, 2
      continue

    # single symbol
    if src[i] in "+-*/%(){}<>=;:,[]@!#":
      result.add Token(kind: tkSymbol, lex: $src[i], line: line, col: col)
      inc i; inc col
      continue

    # numeric literal (int or float)
    m = i
    var had = false
    var isFloat = false
    while m < src.len and src[m].isDigit:
      had = true; inc m

    # check for decimal point
    if had and m < src.len and src[m] == '.':
      inc m
      isFloat = true
      while m < src.len and src[m].isDigit:
        inc m
    if had:
      let kind = if isFloat: tkFloat else: tkInt
      result.add Token(kind: kind, lex: src[i..<m], line: line, col: col)
      col += m-i; i = m
      continue

    # string literal
    if src[i] == '"':
      inc i; inc col # skip opening quote
      m = i
      var content = ""
      while m < src.len and src[m] != '"':
        if src[m] == '\\' and m+1 < src.len:
          # simple escape handling
          inc m
          case src[m]
          of 'n': content.add '\n'
          of 't': content.add '\t'
          of 'r': content.add '\r'
          of '\\': content.add '\\'
          of '"': content.add '"'
          else: content.add src[m]
          inc m
        else:
          content.add src[m]
          inc m
      if m >= src.len:
        raise newException(ValueError, &"Unterminated string at {line}:{col}")
      inc m # skip closing quote
      result.add Token(kind: tkString, lex: content, line: line, col: col)
      col += m-i+1; i = m
      continue

    # identifier / keyword
    m = i
    if src[m].isAlphaAscii or src[m] == '_':
      inc m
      while m < src.len and (src[m].isAlphaNumeric or src[m] == '_'): inc m
      let w = src[i..<m]
      result.add Token(kind: (if isKeyword(w): tkKeyword else: tkIdent), lex: w, line: line, col: col)
      col += m-i; i = m
      continue

    # fallback: unknown char -> symbol token
    result.add Token(kind: tkSymbol, lex: $src[i], line: line, col: col)
    inc i; inc col

  result.add Token(kind: tkEof, lex: "<eof>", line: line, col: col)
