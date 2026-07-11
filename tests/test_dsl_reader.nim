import std/[streams, unittest]

import nest_dsl/[nodes, reader]

suite "DSL reader":
  test "parses the example DSL":
    let stream = newFileStream("docs/dsl")
    require stream != nil
    defer: stream.close()

    let read = readProgram(stream)
    check read.ok

    let program = Program(read.node)
    check program.body.lines.len == 3
    check BlockCommandLine(program.body.lines[0]).command.identifier == "define"
    check BlockCommandLine(program.body.lines[1]).command.identifier == "events"

    let column = BlockCommandLine(program.body.lines[2])
    check column.command.identifier == "column"
    check column.command.values.len == 1
    check CallValue(column.command.values[0]).identifier == "id"
    check column.body.lines.len == 7

  test "parses call keyword assignments":
    let stream = newStringStream("width = (prefer 800: min = 400)\n")
    defer: stream.close()

    let read = readProgram(stream)
    check read.ok

    let program = Program(read.node)
    let line = SimpleStatementLine(program.body.lines[0])
    let assignment = Assignment(line.statement)
    let call = CallValue(assignment.value)

    check assignment.identifier == "width"
    check call.identifier == "prefer"
    check NumberValue(call.values[0]).lexeme == "800"
    check call.assignments.len == 1
    check call.assignments[0].identifier == "min"
    check NumberValue(call.assignments[0].value).lexeme == "400"
    check $read == "width = (prefer 800: min = 400)"

  test "parses bare value statements":
    let stream = newStringStream("\"Search\"\n")
    defer: stream.close()

    let read = readProgram(stream)
    check read.ok

    let program = Program(read.node)
    let line = SimpleStatementLine(program.body.lines[0])
    check StringValue(line.statement).value == "Search"
    check $line == "\"Search\""

  test "renders nested nodes":
    let stream = newStringStream("root (id):\n  label:\n    \"Name\\nValue\"\n")
    defer: stream.close()

    let read = readProgram(stream)
    check read.ok
    check $read == "root (id):\n  label:\n    \"Name\\nValue\""

  test "reports indentation errors":
    let stream = newStringStream("root:\nchild\n")
    defer: stream.close()

    let read = readProgram(stream)
    check not read.ok
    check read.error.line == 2
    check read.error.message == "expected indented block"
    check $read.error == "2:1: expected indented block"
    check $read == "error: 2:1: expected indented block"

  test "reports token errors":
    let stream = newStringStream("name = \"unterminated\n")
    defer: stream.close()

    let read = readProgram(stream)
    check not read.ok
    check read.error.line == 1
    check read.error.message == "unterminated string"
