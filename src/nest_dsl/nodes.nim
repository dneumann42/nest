type
  Node* = ref object of RootObj

  Program* = ref object of Node
    body*: Block

  Block* = ref object of Node
    lines*: seq[Line]

  Line* = ref object of Node

  BlockCommandLine* = ref object of Line
    command*: Command
    body*: Block

  SimpleStatementLine* = ref object of Line
    statement*: SimpleStatement

  SimpleStatement* = ref object of Node

  Assignment* = ref object of SimpleStatement
    identifier*: string
    value*: Value

  Command* = ref object of SimpleStatement
    identifier*: string
    values*: seq[Value]

  Value* = ref object of SimpleStatement
  IdentifierValue* = ref object of Value
    identifier*: string

  NumberValue* = ref object of Value
    lexeme*: string

  StringValue* = ref object of Value
    value*: string

  CallValue* = ref object of Value
    identifier*: string
    values*: seq[Value]
    assignments*: seq[Assignment]

{.push raises: [].}

proc addIndent(result: var string; indent: int) =
  for _ in 0 ..< indent:
    result.add ' '

proc addEscapedString(result: var string; value: string) =
  result.add '"'
  for c in value:
    case c
    of '"':
      result.add "\\\""
    of '\\':
      result.add "\\\\"
    of '\n':
      result.add "\\n"
    of '\r':
      result.add "\\r"
    of '\t':
      result.add "\\t"
    else:
      result.add c
  result.add '"'

proc addBlock(result: var string; body: Block; indent: int)
proc addLine(result: var string; line: Line; indent: int)
proc addStatement(result: var string; statement: SimpleStatement)
proc addValue(result: var string; value: Value)
proc addAssignment(result: var string; assignment: Assignment)
proc addCommand(result: var string; command: Command)

proc addAssignment(result: var string; assignment: Assignment) =
  if assignment.isNil:
    result.add "<nil-assignment>"
    return

  result.add assignment.identifier
  result.add " = "
  result.addValue assignment.value

proc addCommand(result: var string; command: Command) =
  if command.isNil:
    result.add "<nil-command>"
    return

  result.add command.identifier
  for value in command.values:
    result.add ' '
    result.addValue value

proc addValue(result: var string; value: Value) =
  if value.isNil:
    result.add "<nil-value>"
  elif value of IdentifierValue:
    result.add IdentifierValue(value).identifier
  elif value of NumberValue:
    result.add NumberValue(value).lexeme
  elif value of StringValue:
    result.addEscapedString StringValue(value).value
  elif value of CallValue:
    let call = CallValue(value)
    result.add '('
    result.add call.identifier
    for arg in call.values:
      result.add ' '
      result.addValue arg
    if call.assignments.len > 0:
      result.add ":"
      for assignment in call.assignments:
        result.add ' '
        result.addAssignment assignment
    result.add ')'
  else:
    result.add "<unknown-value>"

proc addStatement(result: var string; statement: SimpleStatement) =
  if statement.isNil:
    result.add "<nil-statement>"
  elif statement of Assignment:
    result.addAssignment Assignment(statement)
  elif statement of Command:
    result.addCommand Command(statement)
  elif statement of Value:
    result.addValue Value(statement)
  else:
    result.add "<unknown-statement>"

proc addLine(result: var string; line: Line; indent: int) =
  result.addIndent indent

  if line.isNil:
    result.add "<nil-line>"
  elif line of BlockCommandLine:
    let blockLine = BlockCommandLine(line)
    result.addCommand blockLine.command
    result.add ':'
    if not blockLine.body.isNil and blockLine.body.lines.len > 0:
      result.add '\n'
      result.addBlock(blockLine.body, indent + 2)
  elif line of SimpleStatementLine:
    result.addStatement SimpleStatementLine(line).statement
  else:
    result.add "<unknown-line>"

proc addBlock(result: var string; body: Block; indent: int) =
  if body.isNil:
    result.addIndent indent
    result.add "<nil-block>"
    return

  for i, line in body.lines:
    if i > 0:
      result.add '\n'
    result.addLine(line, indent)

proc `$`*(assignment: Assignment): string =
  result.addAssignment assignment

proc `$`*(command: Command): string =
  result.addCommand command

proc `$`*(value: Value): string =
  result.addValue value

proc `$`*(statement: SimpleStatement): string =
  result.addStatement statement

proc `$`*(line: Line): string =
  result.addLine(line, 0)

proc `$`*(body: Block): string =
  result.addBlock(body, 0)

proc `$`*(program: Program): string =
  if program.isNil:
    "<nil-program>"
  else:
    $program.body

proc `$`*(node: Node): string =
  if node.isNil:
    "<nil-node>"
  elif node of Program:
    $Program(node)
  elif node of Block:
    $Block(node)
  elif node of Line:
    $Line(node)
  elif node of SimpleStatement:
    $SimpleStatement(node)
  else:
    "<unknown-node>"

{.pop.}
