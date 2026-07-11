import std/[os, osproc, sets, streams, strutils, tables]

import nest/[dialogs, ui]
import nodes

type
  DslValueKind* = enum
    None
    Text
    Number
    Boolean
    WidgetKey
    List
    Size
    Align
    Justify
    Input
    EditInput

  DslValue* = object
    case kind*: DslValueKind
    of None:
      discard
    of Text:
      stringValue*: string
    of Number:
      numberValue*: float64
    of Boolean:
      boolValue*: bool
    of WidgetKey:
      widgetIDValue*: WidgetID
    of List:
      listValue*: DslList
    of Size:
      sizePolicyValue*: SizePolicy
    of Align:
      alignmentValue*: Alignment
    of Justify:
      justificationValue*: Justification
    of Input:
      lineInputValue*: LineInputState
    of EditInput:
      editLineValue*: EditLineState

  DslList* = ref object
    items*: seq[string]

  DslError* = object
    message*: string

  DslExec* = ref object
    process: Process
    command*: string
    running*: bool
    output*: string
    exitCode*: int

  UserCommand = object
    params: seq[string]
    body: Block

  DslRuntime* = ref object
    env*: Table[string, DslValue]
    commands: Table[string, DslCommand]
    userCommands: Table[string, UserCommand]
    error*: DslError
    hasError*: bool
    exec*: DslExec

  DslCommand* = proc(
    runtime: DslRuntime,
    ui: var UI,
    args: seq[DslValue],
    body: Block,
  ): DslValue {.closure.}

proc init*(T: typedesc[DslRuntime]): T
proc renderBlock*(runtime: DslRuntime; ui: var UI; body: Block)

proc nilValue*(): DslValue =
  DslValue(kind: None)

proc stringValue*(value: string): DslValue =
  DslValue(kind: Text, stringValue: value)

proc numberValue*(value: float64): DslValue =
  DslValue(kind: Number, numberValue: value)

proc boolValue*(value: bool): DslValue =
  DslValue(kind: Boolean, boolValue: value)

proc widgetIDValue*(value: WidgetID): DslValue =
  DslValue(kind: WidgetKey, widgetIDValue: value)

proc sizePolicyValue*(value: SizePolicy): DslValue =
  DslValue(kind: Size, sizePolicyValue: value)

proc listValue*(items: seq[string] = @[]): DslValue =
  DslValue(kind: List, listValue: DslList(items: items))

proc alignmentValue*(value: Alignment): DslValue =
  DslValue(kind: Align, alignmentValue: value)

proc justificationValue*(value: Justification): DslValue =
  DslValue(kind: Justify, justificationValue: value)

proc lineInputValue*(value: LineInputState): DslValue =
  DslValue(kind: Input, lineInputValue: value)

proc editLineValue*(value: EditLineState): DslValue =
  DslValue(kind: EditInput, editLineValue: value)

proc fail(runtime: DslRuntime; message: string): DslValue =
  if not runtime.hasError:
    runtime.hasError = true
    runtime.error = DslError(message: message)
  nilValue()

proc `$`*(error: DslError): string =
  error.message

proc `$`*(value: DslValue): string =
  case value.kind
  of None:
    ""
  of Text:
    value.stringValue
  of Number:
    $value.numberValue
  of Boolean:
    $value.boolValue
  of WidgetKey:
    $value.widgetIDValue
  of List:
    value.listValue.items.join("\n")
  of Size:
    $value.sizePolicyValue
  of Align:
    $value.alignmentValue
  of Justify:
    $value.justificationValue
  of Input:
    value.lineInputValue.text
  of EditInput:
    "<edit-line>"

proc asString(runtime: DslRuntime; value: DslValue): string =
  case value.kind
  of Text:
    value.stringValue
  of Number:
    $value.numberValue
  of Boolean:
    $value.boolValue
  of WidgetKey:
    $value.widgetIDValue
  of List:
    value.listValue.items.join("\n")
  of Input:
    value.lineInputValue.text
  else:
    $value

proc asNumber(runtime: DslRuntime; value: DslValue; fallback = 0.0): float64 =
  case value.kind
  of Number:
    value.numberValue
  of Text:
    try:
      parseFloat(value.stringValue)
    except ValueError:
      fallback
  else:
    fallback

proc asBool(runtime: DslRuntime; value: DslValue): bool =
  case value.kind
  of Boolean:
    value.boolValue
  of None:
    false
  of Text:
    value.stringValue.len > 0
  else:
    true

proc asWidgetID(runtime: DslRuntime; ui: UI; value: DslValue): WidgetID =
  case value.kind
  of WidgetKey:
    value.widgetIDValue
  of Text:
    ui.id(value.stringValue)
  else:
    ui.id($value)

proc asSizePolicy(runtime: DslRuntime; value: DslValue; fallback: SizePolicy): SizePolicy =
  if value.kind == Size:
    value.sizePolicyValue
  else:
    fallback

proc asAlignment(runtime: DslRuntime; value: DslValue; fallback: Alignment): Alignment =
  if value.kind == Align:
    value.alignmentValue
  else:
    fallback

proc asJustification(
    runtime: DslRuntime; value: DslValue; fallback: Justification
): Justification =
  if value.kind == Justify:
    value.justificationValue
  else:
    fallback

proc defineValue*(runtime: DslRuntime; name: string; value: DslValue) =
  runtime.env[name] = value

proc registerCommand*(runtime: DslRuntime; name: string; command: DslCommand) =
  runtime.commands[name] = command

proc get*(runtime: DslRuntime; name: string): DslValue =
  runtime.env.getOrDefault(name)

proc widgetID*(runtime: DslRuntime; name: string): WidgetID =
  let value = runtime.get(name)
  if value.kind == WidgetKey:
    value.widgetIDValue
  else:
    InvalidWidgetID

proc lineInputState*(runtime: DslRuntime; name: string): LineInputState =
  let value = runtime.get(name)
  if value.kind == Input:
    value.lineInputValue
  else:
    nil

proc editLineStateValue*(runtime: DslRuntime; name: string): EditLineState =
  let value = runtime.get(name)
  if value.kind == EditInput:
    value.editLineValue
  else:
    editLineState()

proc evalValue(runtime: DslRuntime; ui: var UI; value: Value): DslValue
proc evalCommand(runtime: DslRuntime; ui: var UI; command: Command; body: Block = nil): DslValue
proc evalCall(runtime: DslRuntime; ui: var UI; call: CallValue): DslValue

proc evalArgs(runtime: DslRuntime; ui: var UI; values: openArray[Value]): seq[DslValue] =
  for value in values:
    result.add runtime.evalValue(ui, value)

proc evalAssignmentValue(runtime: DslRuntime; ui: var UI; assignment: Assignment): DslValue =
  if assignment.isNil:
    return runtime.fail("expected assignment")
  runtime.evalValue(ui, assignment.value)

proc callOption(
    runtime: DslRuntime; ui: var UI; call: CallValue; name: string; fallback: float64
): float64 =
  result = fallback
  for assignment in call.assignments:
    if assignment.identifier == name:
      return runtime.asNumber(runtime.evalAssignmentValue(ui, assignment), fallback)

proc evalCall(runtime: DslRuntime; ui: var UI; call: CallValue): DslValue =
  if call.isNil:
    return nilValue()

  let args = runtime.evalArgs(ui, call.values)
  case call.identifier
  of "fill":
    return sizePolicyValue(fill(
      min = runtime.callOption(ui, call, "min", 0.0),
      max = runtime.callOption(ui, call, "max", Inf),
    ))
  of "fit":
    return sizePolicyValue(fit(
      min = runtime.callOption(ui, call, "min", 0.0),
      max = runtime.callOption(ui, call, "max", Inf),
    ))
  of "fixed":
    if args.len > 0:
      return sizePolicyValue(fixed(runtime.asNumber(args[0])))
    return sizePolicyValue(fixed(0))
  of "hug":
    if args.len > 0:
      return sizePolicyValue(hug(
        runtime.asNumber(args[0]),
        min = runtime.callOption(ui, call, "min", 0.0),
        max = runtime.callOption(ui, call, "max", Inf),
      ))
    return sizePolicyValue(hug(0))
  of "prefer":
    if args.len > 0:
      return sizePolicyValue(prefer(
        runtime.asNumber(args[0]),
        min = runtime.callOption(ui, call, "min", 0.0),
        max = runtime.callOption(ui, call, "max", Inf),
      ))
    return sizePolicyValue(prefer(0))
  else:
    return runtime.evalCommand(
      ui,
      Command(identifier: call.identifier, values: call.values),
      nil,
    )

proc evalValue(runtime: DslRuntime; ui: var UI; value: Value): DslValue =
  if value.isNil:
    return nilValue()
  if value of IdentifierValue:
    let name = IdentifierValue(value).identifier
    if runtime.env.hasKey(name):
      return runtime.env[name]
    case name
    of "true":
      return boolValue(true)
    of "false":
      return boolValue(false)
    of "AlignAuto":
      return alignmentValue(AlignAuto)
    of "AlignStart":
      return alignmentValue(AlignStart)
    of "AlignCenter":
      return alignmentValue(AlignCenter)
    of "AlignEnd":
      return alignmentValue(AlignEnd)
    of "AlignStretch":
      return alignmentValue(AlignStretch)
    of "JustifyStart":
      return justificationValue(JustifyStart)
    of "JustifyCenter":
      return justificationValue(JustifyCenter)
    of "JustifyEnd":
      return justificationValue(JustifyEnd)
    else:
      return stringValue(name)
  if value of nodes.NumberValue:
    return numberValue(parseFloat(nodes.NumberValue(value).lexeme))
  if value of nodes.StringValue:
    return stringValue(nodes.StringValue(value).value)
  if value of CallValue:
    return runtime.evalCall(ui, CallValue(value))
  nilValue()

proc evalBoxConfig(runtime: DslRuntime; ui: var UI; body: Block): BoxConfig =
  result = cfg()
  if body.isNil:
    return

  for line in body.lines:
    if not (line of SimpleStatementLine):
      continue
    let statement = SimpleStatementLine(line).statement
    if not (statement of Assignment):
      continue

    let assignment = Assignment(statement)
    let value = runtime.evalAssignmentValue(ui, assignment)
    case assignment.identifier
    of "width":
      result.width = runtime.asSizePolicy(value, result.width)
    of "height":
      result.height = runtime.asSizePolicy(value, result.height)
    of "gap":
      result.gap = runtime.asNumber(value, result.gap)
    of "padding":
      result.padding = runtime.asNumber(value, result.padding)
    of "alignItems":
      result.alignItems = runtime.asAlignment(value, result.alignItems)
    of "justifyContent":
      result.justifyContent = runtime.asJustification(value, result.justifyContent)
    of "alignSelf":
      result.alignSelf = runtime.asAlignment(value, result.alignSelf)
    of "scrollX":
      result.scrollX = runtime.asBool(value)
    of "scrollY":
      result.scrollY = runtime.asBool(value)
    else:
      discard

proc renderChildLines(runtime: DslRuntime; ui: var UI; body: Block) =
  if body.isNil:
    return
  for line in body.lines:
    if line of SimpleStatementLine and
        SimpleStatementLine(line).statement of Assignment:
      continue
    runtime.renderBlock(ui, Block(lines: @[line]))

proc textFromBody(runtime: DslRuntime; ui: var UI; body: Block): string =
  if body.isNil:
    return ""
  for line in body.lines:
    if not (line of SimpleStatementLine):
      continue
    let statement = SimpleStatementLine(line).statement
    if statement of Assignment:
      let assignment = Assignment(statement)
      if assignment.identifier == "text":
        return runtime.asString(runtime.evalAssignmentValue(ui, assignment))
    elif statement of Value:
      return runtime.asString(runtime.evalValue(ui, Value(statement)))

proc lineInputFromValue(runtime: DslRuntime; value: DslValue): LineInputState =
  if value.kind == Input:
    value.lineInputValue
  else:
    LineInputState.new(runtime.asString(value))

proc listFromValue(value: DslValue): DslList =
  if value.kind == List:
    value.listValue
  else:
    nil

proc identifierName(value: Value): string =
  if value of IdentifierValue:
    IdentifierValue(value).identifier
  else:
    ""

proc setInputText(input: LineInputState; text: string) =
  if input.isNil:
    return
  input.text = text
  input.cursor = text.len

proc splitText(text, separator: string): seq[string] =
  if separator.len == 0:
    return @[text]
  text.split(separator)

proc readLinesFile(path: string): seq[string] =
  if path.len == 0 or not fileExists(path):
    return @[]
  try:
    result = readFile(path).splitLines()
  except CatchableError:
    result = @[]

proc writeLinesFile(path: string; lines: openArray[string]): bool =
  try:
    writeFile(path, lines.join("\n"))
    true
  except CatchableError:
    false

proc pollExec*(runtime: DslRuntime) =
  if runtime.exec.isNil or not runtime.exec.running or runtime.exec.process.isNil:
    return

  var stillRunning = false
  try:
    stillRunning = runtime.exec.process.running()
  except OSError as err:
    runtime.exec.running = false
    runtime.exec.output = err.msg
    echo runtime.exec.output
    return

  if stillRunning:
    return

  runtime.exec.running = false
  try:
    runtime.exec.exitCode = runtime.exec.process.peekExitCode()
    runtime.exec.output = runtime.exec.process.outputStream().readAll()
  except CatchableError as err:
    runtime.exec.output = err.msg
  echo runtime.exec.output
  runtime.exec.process.close()
  runtime.exec.process = nil

proc startExec(runtime: DslRuntime; command: string): DslValue =
  if runtime.exec.isNil:
    runtime.exec = DslExec()
  if runtime.exec.running:
    return boolValue(false)

  try:
    runtime.exec.process = startProcess(
      command,
      options = {poUsePath, poEvalCommand, poStdErrToStdOut},
    )
  except CatchableError as err:
    return runtime.fail("exec failed: " & err.msg)

  runtime.exec.command = command
  runtime.exec.output = ""
  runtime.exec.exitCode = -1
  runtime.exec.running = true
  boolValue(true)

proc evalCommand(runtime: DslRuntime; ui: var UI; command: Command; body: Block = nil): DslValue =
  if command.isNil:
    return nilValue()

  let args = runtime.evalArgs(ui, command.values)
  if runtime.userCommands.hasKey(command.identifier):
    let userCommand = runtime.userCommands[command.identifier]
    var oldValues: Table[string, DslValue]
    var hadOldValue: Table[string, bool]
    for index, param in userCommand.params:
      oldValues[param] = runtime.env.getOrDefault(param)
      hadOldValue[param] = runtime.env.hasKey(param)
      runtime.env[param] =
        if index < args.len:
          args[index]
        else:
          nilValue()
    runtime.renderBlock(ui, userCommand.body)
    for param in userCommand.params:
      if hadOldValue.getOrDefault(param):
        runtime.env[param] = oldValues[param]
      else:
        runtime.env.del(param)
    return nilValue()

  if runtime.commands.hasKey(command.identifier):
    return runtime.commands[command.identifier](runtime, ui, args, body)

  case command.identifier
  of "id":
    return widgetIDValue(nextWidgetID())
  of "LineInputState":
    if args.len > 0:
      return lineInputValue(LineInputState.new(runtime.asString(args[0])))
    return lineInputValue(LineInputState.new(""))
  of "EditLineState":
    return editLineValue(editLineState())
  of "fill":
    return sizePolicyValue(fill())
  of "fit":
    return sizePolicyValue(fit())
  of "fixed":
    if args.len > 0:
      return sizePolicyValue(fixed(runtime.asNumber(args[0])))
    return sizePolicyValue(fixed(0))
  of "hug":
    if args.len > 0:
      return sizePolicyValue(hug(runtime.asNumber(args[0])))
    return sizePolicyValue(hug(0))
  of "prefer":
    if args.len == 0:
      return sizePolicyValue(prefer(0))
    var minValue = 0.0
    if command.values.len > 0 and command.values[0] of CallValue:
      discard
    return sizePolicyValue(prefer(runtime.asNumber(args[0]), min = minValue))
  of "clicked":
    if args.len == 0:
      return boolValue(false)
    return boolValue(ui.inEventPhase() and ui.clicked(runtime.asWidgetID(ui, args[0])))
  of "submitted":
    if args.len == 0:
      return boolValue(false)
    return boolValue(ui.inEventPhase() and ui.submitted(runtime.asWidgetID(ui, args[0])))
  of "env":
    if args.len == 0:
      return stringValue("")
    return stringValue(getEnv(runtime.asString(args[0])))
  of "split":
    if args.len == 0:
      return listValue()
    let separator =
      if args.len > 1:
        runtime.asString(args[1])
      else:
        "\n"
    return listValue(splitText(runtime.asString(args[0]), separator))
  of "loadLines":
    if args.len == 0:
      return listValue()
    return listValue(readLinesFile(runtime.asString(args[0])))
  of "writeLines":
    if args.len < 2:
      return runtime.fail("writeLines requires path and list")
    let list = listFromValue(args[1])
    if list.isNil:
      return runtime.fail("writeLines requires a list")
    return boolValue(writeLinesFile(runtime.asString(args[0]), list.items))
  of "appendLine":
    if args.len < 2:
      return runtime.fail("appendLine requires list and value")
    let list = listFromValue(args[0])
    if list.isNil:
      return runtime.fail("appendLine requires a list")
    list.items.add runtime.asString(args[1])
    return nilValue()
  of "insertLine":
    if args.len < 3:
      return runtime.fail("insertLine requires list, index, and value")
    let list = listFromValue(args[0])
    if list.isNil:
      return runtime.fail("insertLine requires a list")
    let index = runtime.asNumber(args[1]).int.clamp(0, list.items.len)
    list.items.insert(runtime.asString(args[2]), index)
    return nilValue()
  of "setLine":
    if args.len < 3:
      return runtime.fail("setLine requires list, index, and value")
    let list = listFromValue(args[0])
    if list.isNil:
      return runtime.fail("setLine requires a list")
    let index = runtime.asNumber(args[1]).int
    if index >= 0 and index < list.items.len:
      list.items[index] = runtime.asString(args[2])
    return nilValue()
  of "deleteLine":
    if args.len < 2:
      return runtime.fail("deleteLine requires list and index")
    let list = listFromValue(args[0])
    if list.isNil:
      return runtime.fail("deleteLine requires a list")
    let index = runtime.asNumber(args[1]).int
    if index >= 0 and index < list.items.len:
      list.items.delete(index)
    return nilValue()
  of "setText":
    if args.len < 2:
      return runtime.fail("setText requires input and value")
    if args[0].kind != Input:
      return runtime.fail("setText requires a line input")
    args[0].lineInputValue.setInputText(runtime.asString(args[1]))
    return nilValue()
  of "browseFolder":
    if args.len == 0 or args[0].kind != Input:
      return runtime.fail("browseFolder requires a line input")
    let input = args[0].lineInputValue
    if ui.inEventPhase():
      dialogs.browseFolder proc(path: string) =
        input.setInputText(path)
    return nilValue()
  of "define":
    if body.isNil:
      return nilValue()
    for line in body.lines:
      if not (line of SimpleStatementLine):
        continue
      let statement = SimpleStatementLine(line).statement
      if statement of Command:
        let cmd = Command(statement)
        if not runtime.env.hasKey(cmd.identifier):
          let value =
            if cmd.values.len == 0:
              nilValue()
            elif cmd.values.len == 1:
              runtime.evalValue(ui, cmd.values[0])
            else:
              stringValue($cmd)
          runtime.defineValue(cmd.identifier, value)
      elif statement of Assignment:
        let assignment = Assignment(statement)
        if not runtime.env.hasKey(assignment.identifier):
          runtime.defineValue(assignment.identifier, runtime.evalAssignmentValue(ui, assignment))
    return nilValue()
  of "command":
    if body.isNil:
      return runtime.fail("command requires a block")
    if command.values.len == 0:
      return runtime.fail("command requires a name")
    if not (command.values[0] of IdentifierValue):
      return runtime.fail("command name must be an identifier")
    let name = IdentifierValue(command.values[0]).identifier
    var params: seq[string]
    for index in 1 ..< command.values.len:
      if not (command.values[index] of IdentifierValue):
        return runtime.fail("command parameters must be identifiers")
      params.add IdentifierValue(command.values[index]).identifier
    runtime.userCommands[name] = UserCommand(params: params, body: body)
    return nilValue()
  of "events":
    if ui.inEventPhase():
      runtime.renderBlock(ui, body)
    return nilValue()
  of "when":
    if args.len > 0 and runtime.asBool(args[0]):
      runtime.renderBlock(ui, body)
    return nilValue()
  of "print":
    var parts: seq[string]
    for arg in args:
      parts.add runtime.asString(arg)
    echo parts.join(" ")
    return nilValue()
  of "exec":
    var parts: seq[string]
    for arg in args:
      parts.add runtime.asString(arg)
    return runtime.startExec(parts.join(" "))
  of "execStatus":
    if not runtime.exec.isNil and runtime.exec.running:
      let id =
        if args.len > 0:
          runtime.asWidgetID(ui, args[0])
        else:
          ui.id("exec-status")
      ui.label(id, "Running: " & runtime.exec.command, fit(), fit())
    return nilValue()
  of "row":
    let id =
      if args.len > 0:
        runtime.asWidgetID(ui, args[0])
      else:
        nextWidgetID()
    let config = runtime.evalBoxConfig(ui, body)
    ui.row(id, config):
      runtime.renderChildLines(ui, body)
    return nilValue()
  of "column":
    let id =
      if args.len > 0:
        runtime.asWidgetID(ui, args[0])
      else:
        nextWidgetID()
    let config = runtime.evalBoxConfig(ui, body)
    ui.column(id, config):
      runtime.renderChildLines(ui, body)
    return nilValue()
  of "panel":
    let id =
      if args.len > 0:
        runtime.asWidgetID(ui, args[0])
      else:
        nextWidgetID()
    let config = runtime.evalBoxConfig(ui, body)
    ui.panel(id, config):
      runtime.renderChildLines(ui, body)
    return nilValue()
  of "label":
    let id =
      if args.len > 0:
        runtime.asWidgetID(ui, args[0])
      else:
        nextWidgetID()
    let config = runtime.evalBoxConfig(ui, body)
    let text =
      if args.len > 1:
        runtime.asString(args[1])
      else:
        runtime.textFromBody(ui, body)
    ui.label(id, text, config.width, config.height, alignSelf = config.alignSelf)
    return nilValue()
  of "button":
    let id =
      if args.len > 0:
        runtime.asWidgetID(ui, args[0])
      else:
        nextWidgetID()
    let config = runtime.evalBoxConfig(ui, body)
    let text =
      if args.len > 1:
        runtime.asString(args[1])
      else:
        runtime.textFromBody(ui, body)
    discard ui.button(id, text, config.width, config.height, alignSelf = config.alignSelf)
    return nilValue()
  of "lineInput":
    if args.len < 2:
      return runtime.fail("lineInput requires id and state")
    let config = runtime.evalBoxConfig(ui, body)
    ui.lineInput(
      runtime.asWidgetID(ui, args[0]),
      runtime.lineInputFromValue(args[1]),
      config.width,
      config.height,
      alignSelf = config.alignSelf,
    )
    return nilValue()
  of "pathListBox":
    if args.len < 4:
      return runtime.fail("pathListBox requires id, list, edit state, and search")
    let list = listFromValue(args[1])
    if list.isNil:
      return runtime.fail("pathListBox requires a list")
    var edit =
      if args[2].kind == EditInput:
        args[2].editLineValue
      else:
        editLineState()
    let editName =
      if command.values.len > 2:
        identifierName(command.values[2])
      else:
        ""
    let search = runtime.asString(args[3])
    let rows = listItems[string](
      list.items,
      proc(item: string, index: int): string = listKey(index, item),
      proc(item: string, index: int): bool =
        search.len == 0 or item.contains(search),
    )

    ui.events:
      var deleteIndexes: HashSet[int]
      for row in rows:
        ui.scope(row.key):
          if ui.clicked(ui.id("edit")):
            edit.beginEdit(row.key, row.value)
          if ui.clicked(ui.id("save")) and edit.editing(row.key):
            list.items[row.index] = edit.saveEdit()
          if ui.clicked(ui.id("cancel")) and edit.editing(row.key):
            edit.cancelEdit()
          if ui.clicked(ui.id("delete")):
            deleteIndexes.incl row.index
      if deleteIndexes.len > 0:
        if edit.editing:
          for row in rows:
            if row.index in deleteIndexes and edit.editing(row.key):
              edit.cancelEdit()
        var kept: seq[string]
        for index, item in list.items.pairs:
          if index notin deleteIndexes:
            kept.add item
        list.items = kept

    let config =
      if body.isNil:
        cfg(
          width = prefer(800, min = 400),
          height = fill(),
          gap = 12.0,
          alignItems = AlignStretch,
          justifyContent = JustifyStart,
          scrollX = true,
          scrollY = true,
        )
      else:
        runtime.evalBoxConfig(ui, body)
    ui.panel(runtime.asWidgetID(ui, args[0]), config):
      for row in rows:
        ui.scope(row.key):
          if edit.editing(row.key):
            ui.row(
              ui.id("edit-row"),
              cfg(width = fill(), height = fit(), gap = 12.0, alignItems = AlignCenter),
            ):
              ui.lineInput(edit.inputID, edit.input, fill(), fixed(28))
              ui.button(ui.id("cancel"), "Cancel", fit(), fit())
              ui.button(ui.id("save"), "Save", fit(), fit())
          else:
            ui.row(
              ui.id("row"),
              cfg(
                width = fill(),
                height = fit(),
                gap = 12.0,
                alignItems = AlignCenter,
                justifyContent = JustifyCenter,
              ),
            ):
              ui.label(ui.id("label"), row.value, fill(), fit())
              ui.button(ui.id("edit"), "Edit", fit(), fit())
              ui.button(ui.id("delete"), "Delete", fit(), fit())
          discard
    if editName.len > 0:
      runtime.defineValue(editName, editLineValue(edit))
    return nilValue()
  else:
    return runtime.fail("unknown command: " & command.identifier)

proc renderLine(runtime: DslRuntime; ui: var UI; line: Line) =
  if line of BlockCommandLine:
    let blockLine = BlockCommandLine(line)
    discard runtime.evalCommand(ui, blockLine.command, blockLine.body)
  elif line of SimpleStatementLine:
    let statement = SimpleStatementLine(line).statement
    if statement of Command:
      discard runtime.evalCommand(ui, Command(statement))
    elif statement of Assignment:
      discard runtime.evalAssignmentValue(ui, Assignment(statement))
    elif statement of Value:
      discard runtime.evalValue(ui, Value(statement))

proc renderBlock*(runtime: DslRuntime; ui: var UI; body: Block) =
  if body.isNil:
    return
  runtime.pollExec()
  for line in body.lines:
    if runtime.hasError:
      return
    runtime.renderLine(ui, line)

proc render*(runtime: DslRuntime; ui: var UI; program: Program) =
  if program.isNil:
    return
  ui.layout:
    runtime.renderBlock(ui, program.body)

proc init*(T: typedesc[DslRuntime]): T =
  result = T(exec: DslExec())
