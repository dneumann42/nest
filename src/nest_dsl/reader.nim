import std/[streams]

import nodes

{.push raises: [].}

type
  ReaderError* = object
    line*: int
    column*: int
    message*: string

  ReadResult* = object
    ok*: bool
    node*: Node
    error*: ReaderError

  TokenKind = enum
    Identifier
    Number
    String
    LParen
    RParen
    Colon
    Equals

  Token = object
    kind: TokenKind
    text: string
    line: int
    column: int

  ParsedLine = object
    indent: int
    line: int
    tokens: seq[Token]

  Reader* = ref object
    stream: Stream
    line: int
    pending: ParsedLine
    hasPending: bool
    failed: bool
    error: ReaderError

proc init*(T: typedesc[Reader]): T =
  T()

proc init*(T: typedesc[Reader], stream: Stream): T =
  T(stream: stream)

proc `$`*(error: ReaderError): string =
  $error.line & ":" & $error.column & ": " & error.message

proc `$`*(read: ReadResult): string =
  if read.ok:
    $read.node
  else:
    "error: " & $read.error

proc `$`*(reader: Reader): string =
  if reader.isNil:
    "Reader(nil)"
  elif reader.failed:
    "Reader(failed: " & $reader.error & ")"
  elif reader.hasPending:
    "Reader(line: " & $reader.line & ", pending: " & $reader.pending.line & ")"
  else:
    "Reader(line: " & $reader.line & ")"

proc isDigit(c: char): bool =
  c >= '0' and c <= '9'

proc isIdentStart(c: char): bool =
  (c >= 'a' and c <= 'z') or
    (c >= 'A' and c <= 'Z') or
    c == '_'

proc isIdentPart(c: char): bool =
  isIdentStart(c) or isDigit(c) or c == '-'

proc setError(reader: Reader; line, column: int; message: string): bool =
  if not reader.failed:
    reader.failed = true
    reader.error = ReaderError(line: line, column: column, message: message)
  false

proc setError(reader: Reader; token: Token; message: string): bool =
  reader.setError(token.line, token.column, message)

proc tokenText(kind: TokenKind): string =
  case kind
  of Identifier: "identifier"
  of Number: "number"
  of String: "string"
  of LParen: "'('"
  of RParen: "')'"
  of Colon: "':'"
  of Equals: "'='"

proc addToken(tokens: var seq[Token]; kind: TokenKind; text: string;
    line, column: int) =
  tokens.add Token(kind: kind, text: text, line: line, column: column)

proc tokenize(reader: Reader; raw: string; lineNo: int;
    parsed: var ParsedLine): bool =
  var i = 0
  while i < raw.len and raw[i] == ' ':
    inc i

  if i < raw.len and raw[i] == '\t':
    return reader.setError(lineNo, i + 1, "tabs are not valid indentation")

  if i >= raw.len:
    return false

  if raw[i] == ';':
    return false

  parsed.indent = i
  parsed.line = lineNo
  parsed.tokens.setLen(0)

  while i < raw.len:
    let c = raw[i]
    let column = i + 1

    case c
    of ' ', '\t':
      inc i
    of '(':
      parsed.tokens.addToken(LParen, "(", lineNo, column)
      inc i
    of ')':
      parsed.tokens.addToken(RParen, ")", lineNo, column)
      inc i
    of ':':
      parsed.tokens.addToken(Colon, ":", lineNo, column)
      inc i
    of '=':
      parsed.tokens.addToken(Equals, "=", lineNo, column)
      inc i
    of '"':
      inc i
      var value = newStringOfCap(raw.len - i)
      var closed = false
      while i < raw.len:
        let ch = raw[i]
        if ch == '"':
          inc i
          closed = true
          break
        if ch == '\\':
          inc i
          if i >= raw.len:
            return reader.setError(lineNo, column, "unterminated string escape")
          case raw[i]
          of '"': value.add '"'
          of '\\': value.add '\\'
          of 'n': value.add '\n'
          of 'r': value.add '\r'
          of 't': value.add '\t'
          else:
            return reader.setError(lineNo, i + 1, "unknown string escape")
        else:
          value.add ch
        inc i

      if not closed:
        return reader.setError(lineNo, column, "unterminated string")

      parsed.tokens.addToken(String, value, lineNo, column)
    of '-':
      if i + 1 >= raw.len or not isDigit(raw[i + 1]):
        return reader.setError(lineNo, column, "expected digit after '-'")

      let start = i
      inc i
      while i < raw.len and isDigit(raw[i]):
        inc i
      if i < raw.len and raw[i] == '.':
        inc i
        if i >= raw.len or not isDigit(raw[i]):
          return reader.setError(lineNo, i + 1, "expected digit after decimal point")
        while i < raw.len and isDigit(raw[i]):
          inc i

      parsed.tokens.addToken(Number, raw[start ..< i], lineNo, column)
    else:
      if isDigit(c):
        let start = i
        while i < raw.len and isDigit(raw[i]):
          inc i
        if i < raw.len and raw[i] == '.':
          inc i
          if i >= raw.len or not isDigit(raw[i]):
            return reader.setError(lineNo, i + 1, "expected digit after decimal point")
          while i < raw.len and isDigit(raw[i]):
            inc i

        parsed.tokens.addToken(Number, raw[start ..< i], lineNo, column)
      elif isIdentStart(c):
        let start = i
        inc i
        while i < raw.len and isIdentPart(raw[i]):
          inc i

        parsed.tokens.addToken(Identifier, raw[start ..< i], lineNo, column)
      else:
        return reader.setError(lineNo, column, "unexpected character")

  parsed.tokens.len > 0

proc fillPending(reader: Reader): bool =
  if reader.failed:
    return false
  if reader.hasPending:
    return true
  if reader.stream.isNil:
    discard reader.setError(1, 1, "reader has no stream")
    return false

  var raw = ""
  while true:
    var hasLine = false
    try:
      hasLine = reader.stream.readLine(raw)
    except CatchableError as err:
      discard reader.setError(reader.line + 1, 1, "stream read failed: " & err.msg)
      return false

    if not hasLine:
      return false

    inc reader.line
    var parsed: ParsedLine
    if reader.tokenize(raw, reader.line, parsed):
      reader.pending = parsed
      reader.hasPending = true
      return true

    if reader.failed:
      return false

proc consumePending(reader: Reader): ParsedLine =
  result = reader.pending
  reader.hasPending = false

proc parseValue(reader: Reader; tokens: openArray[Token]; pos: var int;
    value: var Value): bool
proc parseAssignment(reader: Reader; tokens: openArray[Token]; pos: var int;
    assignment: var Assignment): bool

proc expect(reader: Reader; tokens: openArray[Token]; pos: var int;
    kind: TokenKind): bool =
  if pos >= tokens.len:
    if tokens.len == 0:
      return reader.setError(reader.line, 1, "expected " & tokenText(kind))
    let last = tokens[tokens.high]
    return reader.setError(last.line, last.column + last.text.len,
      "expected " & tokenText(kind))

  if tokens[pos].kind != kind:
    return reader.setError(tokens[pos], "expected " & tokenText(kind))

  inc pos
  true

proc parseCommand(reader: Reader; tokens: openArray[Token]; start, stop: int;
    command: var Command): bool =
  var pos = start
  if pos >= stop:
    if tokens.len == 0:
      return reader.setError(reader.line, 1, "expected command")
    return reader.setError(tokens[tokens.high], "expected command")
  if tokens[pos].kind != Identifier:
    return reader.setError(tokens[pos], "expected command identifier")

  command = Command(identifier: tokens[pos].text)
  inc pos

  while pos < stop:
    var value: Value
    if not reader.parseValue(tokens, pos, value):
      return false
    command.values.add value

  true

proc parseAssignment(reader: Reader; tokens: openArray[Token]; pos: var int;
    assignment: var Assignment): bool =
  if pos >= tokens.len:
    return reader.setError(reader.line, 1, "expected assignment")
  if tokens[pos].kind != Identifier:
    return reader.setError(tokens[pos], "expected assignment identifier")

  let name = tokens[pos].text
  inc pos
  if not reader.expect(tokens, pos, Equals):
    return false

  var value: Value
  if not reader.parseValue(tokens, pos, value):
    return false

  assignment = Assignment(identifier: name, value: value)
  true

proc parseCall(reader: Reader; tokens: openArray[Token]; pos: var int;
    call: var CallValue): bool =
  if not reader.expect(tokens, pos, LParen):
    return false
  if pos >= tokens.len or tokens[pos].kind != Identifier:
    if pos < tokens.len:
      return reader.setError(tokens[pos], "expected call identifier")
    return reader.setError(tokens[tokens.high], "expected call identifier")

  call = CallValue(identifier: tokens[pos].text)
  inc pos

  while pos < tokens.len and tokens[pos].kind != RParen and
      tokens[pos].kind != Colon:
    var value: Value
    if not reader.parseValue(tokens, pos, value):
      return false
    call.values.add value

  if pos < tokens.len and tokens[pos].kind == Colon:
    inc pos
    while pos < tokens.len and tokens[pos].kind != RParen:
      var assignment: Assignment
      if not reader.parseAssignment(tokens, pos, assignment):
        return false
      call.assignments.add assignment

  if not reader.expect(tokens, pos, RParen):
    return false

  true

proc parseValue(reader: Reader; tokens: openArray[Token]; pos: var int;
    value: var Value): bool =
  if pos >= tokens.len:
    return reader.setError(reader.line, 1, "expected value")

  let token = tokens[pos]
  case token.kind
  of Identifier:
    value = IdentifierValue(identifier: token.text)
    inc pos
  of Number:
    value = NumberValue(lexeme: token.text)
    inc pos
  of String:
    value = StringValue(value: token.text)
    inc pos
  of LParen:
    var call: CallValue
    if not reader.parseCall(tokens, pos, call):
      return false
    value = call
  else:
    return reader.setError(token, "expected value")

  true

proc parseSimpleStatement(reader: Reader; tokens: openArray[Token];
    statement: var SimpleStatement): bool =
  if tokens.len == 0:
    return reader.setError(reader.line, 1, "expected statement")

  var pos = 0
  if tokens[0].kind == Identifier and tokens.len > 1 and
      tokens[1].kind == Equals:
    var assignment: Assignment
    if not reader.parseAssignment(tokens, pos, assignment):
      return false
    if pos != tokens.len:
      return reader.setError(tokens[pos], "unexpected token after assignment")
    statement = assignment
    return true

  if tokens[0].kind == Identifier:
    var command: Command
    if not reader.parseCommand(tokens, 0, tokens.len, command):
      return false
    statement = command
    return true

  var value: Value
  if not reader.parseValue(tokens, pos, value):
    return false
  if pos != tokens.len:
    return reader.setError(tokens[pos], "unexpected token after value")

  statement = value
  true

proc parseBlock(reader: Reader; indent: int; body: var Block): bool

proc parseLine(reader: Reader; parsed: ParsedLine; line: var Line): bool =
  let tokens = parsed.tokens
  if tokens.len == 0:
    return reader.setError(parsed.line, parsed.indent + 1, "expected line")

  if tokens[tokens.high].kind == Colon:
    var command: Command
    if not reader.parseCommand(tokens, 0, tokens.high, command):
      return false

    if not reader.fillPending():
      if reader.failed:
        return false
      return reader.setError(parsed.line, tokens[tokens.high].column,
        "expected indented block")

    if reader.pending.indent <= parsed.indent:
      return reader.setError(reader.pending.line, reader.pending.indent + 1,
        "expected indented block")

    var body: Block
    if not reader.parseBlock(reader.pending.indent, body):
      return false

    line = BlockCommandLine(command: command, body: body)
    return true

  var statement: SimpleStatement
  if not reader.parseSimpleStatement(tokens, statement):
    return false

  line = SimpleStatementLine(statement: statement)
  true

proc parseBlock(reader: Reader; indent: int; body: var Block): bool =
  body = Block()

  while reader.fillPending():
    if reader.pending.indent < indent:
      return true
    if reader.pending.indent > indent:
      return reader.setError(reader.pending.line, reader.pending.indent + 1,
        "unexpected indentation")

    let parsed = reader.consumePending()
    var line: Line
    if not reader.parseLine(parsed, line):
      return false
    body.lines.add line

  not reader.failed

proc readNodeResult*(stream: Stream): ReadResult =
  let reader = Reader.init(stream)
  var body: Block

  if not reader.parseBlock(0, body):
    return ReadResult(ok: false, error: reader.error)

  let program = Program(body: body)
  ReadResult(ok: true, node: program)

proc readProgram*(stream: Stream): ReadResult =
  readNodeResult(stream)

proc readNode*(stream: Stream): Node =
  let read = readNodeResult(stream)
  if read.ok:
    read.node
  else:
    nil

{.pop.}
