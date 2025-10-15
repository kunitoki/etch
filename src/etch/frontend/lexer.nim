# lexer.nim
# PEG (npeg) based tokenizer for Etch

import std/[sequtils, strutils]
import ../common/[errors, types]

type
  TokKind* = enum
    tkIdent, tkInt, tkFloat, tkString, tkChar, tkBool, tkKeyword, tkSymbol, tkEof
  Token* = object
    kind*: TokKind
    lex*: string
    line*, col*: int

const keywords = [
  "fn","let","var","return","if","elif","else","while","for","break","in",
  "true","false","int","float","string","char","bool","void","ref",
  "comptime","new","and","or","array","nil","option","match",
  "some","none","ok","error","type","distinct","object","import","export","discard"
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

    # Skip /* */ multiline comment
    if i+1 < src.len and src[i] == '/' and src[i+1] == '*':
      let comment_start_line = line
      let comment_start_col = col
      inc i, 2 # skip /*
      inc col, 2
      var found_end = false
      while i+1 < src.len:
        # Check for nested comment start
        if src[i] == '/' and src[i+1] == '*':
          let pos = Pos(line: line, col: col, filename: "")
          raise newParseError(pos, "Nested multiline comments are not supported")
        if src[i] == '*' and src[i+1] == '/':
          inc i, 2 # skip */
          inc col, 2
          found_end = true
          break
        if src[i] == '\n':
          inc line
          col = 1
        else:
          inc col
        inc i
      if not found_end:
        let pos = Pos(line: comment_start_line, col: comment_start_col, filename: "")
        raise newParseError(pos, "Unterminated multiline comment")
      continue

    var m: int
    # 3-char symbol
    if i+2 < src.len and src.substr(i, i+2) == "..<":
      result.add Token(kind: tkSymbol, lex: "..<", line: line, col: col)
      inc i, 3; inc col, 3
      continue

    # 2-char symbol
    if i+1 < src.len and (src.substr(i, i+1) in ["->","==","!=", "<=",">=","..","=>"]):
      result.add Token(kind: tkSymbol, lex: src.substr(i, i+1), line: line, col: col)
      inc i, 2; inc col, 2
      continue

    # single symbol
    if src[i] in "+-*/%(){}<>=;:,[]@!#.":
      result.add Token(kind: tkSymbol, lex: $src[i], line: line, col: col)
      inc i; inc col
      continue

    # numeric literal (int or float)
    m = i
    var had = false
    var isFloat = false
    while m < src.len and src[m].isDigit:
      had = true; inc m

    # check for decimal point (but not if it's part of ..)
    if had and m < src.len and src[m] == '.' and not (m+1 < src.len and src[m+1] == '.'):
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
        let pos = Pos(line: line, col: col, filename: "")
        raise newParseError(pos, "Unterminated string literal")
      inc m # skip closing quote
      result.add Token(kind: tkString, lex: content, line: line, col: col)
      col += m-i+1; i = m
      continue

    # character literal
    if src[i] == '\'':
      inc i; inc col # skip opening quote
      m = i
      var content = ""
      if m < src.len and src[m] != '\'':
        if src[m] == '\\' and m+1 < src.len:
          # simple escape handling
          inc m
          case src[m]
          of 'n': content.add '\n'
          of 't': content.add '\t'
          of 'r': content.add '\r'
          of '\\': content.add '\\'
          of '\'': content.add '\''
          else: content.add src[m]
          inc m
        else:
          content.add src[m]
          inc m
      if m >= src.len:
        let pos = Pos(line: line, col: col, filename: "")
        raise newParseError(pos, "Unterminated character literal")
      if src[m] != '\'':
        let pos = Pos(line: line, col: col, filename: "")
        raise newParseError(pos, "Expected closing quote for character literal")
      if content.len != 1:
        let pos = Pos(line: line, col: col, filename: "")
        raise newParseError(pos, "Character literal must contain exactly one character")
      inc m # skip closing quote
      result.add Token(kind: tkChar, lex: content, line: line, col: col)
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
