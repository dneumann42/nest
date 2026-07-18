import std/[os, osproc, streams, strformat, strutils, tables, times]

import crow
import ui
import uirelays/[input, screen]

type
  WidgetIDValue* = ref object of NativeValue
    value*: WidgetID

  SizePolicyValue* = ref object of NativeValue
    value*: SizePolicy

  AlignmentValue* = ref object of NativeValue
    value*: Alignment

  JustificationValue* = ref object of NativeValue
    value*: Justification

  DialogProcess = ref object
    process: Process

  NestCrowRuntime* = ref object
    evaluator*: Evaluator
    loadedFiles*: Table[string, Time]
    dialogProcesses*: Table[string, DialogProcess]
    dialogResults*: Table[string, string]
    dialogData*: string
    dialogCloseValue*: string
    requestQuit*: bool
    moduleStack: seq[string]
    currentUi: ptr UI
    hasError*: bool
    lastError*: string
    dismissedError*: string

  NestCrowApp* = ref object
    rootPath*: string
    runtime*: NestCrowRuntime
    program*: SyntaxNode
    lastError*: string
    errorDialogProcess*: Process
    errorDialogMessage*: string

proc init*(T: typedesc[NestCrowRuntime]): T
proc renderNodes(runtime: NestCrowRuntime; env: Environment; nodes: seq[SyntaxNode]): Value
proc renderNodes(runtime: NestCrowRuntime; nodes: seq[SyntaxNode]): Value

proc widgetValue(id: WidgetID): Value =
  nativeValue(WidgetIDValue(value: id))

proc sizeValue(policy: SizePolicy): Value =
  nativeValue(SizePolicyValue(value: policy))

proc alignValue(alignment: Alignment): Value =
  nativeValue(AlignmentValue(value: alignment))

proc justifyValue(justification: Justification): Value =
  nativeValue(JustificationValue(value: justification))

proc requireUi(runtime: NestCrowRuntime): var UI {.raises: [EvaluatorError].} =
  if runtime.currentUi.isNil:
    raise newException(EvaluatorError, "Nest UI is not rendering")
  runtime.currentUi[]

proc asString(value: Value): string =
  case value.kind
  of Text:
    value.text
  of Number:
    if value.number == value.number.int.float:
      $value.number.int
    else:
      $value.number
  of Boolean:
    if value.boolean: "true" else: "false"
  of Native:
    if value.native of WidgetIDValue:
      $WidgetIDValue(value.native).value
    else:
      $value
  else:
    $value

proc asNumber(value: Value; fallback = 0.0): float64 =
  case value.kind
  of Number:
    value.number
  of Text:
    try:
      parseFloat(value.text)
    except ValueError:
      fallback
  else:
    fallback

proc asWidgetID(runtime: NestCrowRuntime; value: Value): WidgetID =
  if value.kind == Native and value.native of WidgetIDValue:
    WidgetIDValue(value.native).value
  else:
    runtime.requireUi().id(value.asString)

proc asSizePolicy(value: Value; fallback: SizePolicy): SizePolicy =
  if value.kind == Native and value.native of SizePolicyValue:
    SizePolicyValue(value.native).value
  else:
    fallback

proc asAlignment(value: Value; fallback: Alignment): Alignment =
  if value.kind == Native and value.native of AlignmentValue:
    AlignmentValue(value.native).value
  else:
    fallback

proc asJustification(value: Value; fallback: Justification): Justification =
  if value.kind == Native and value.native of JustificationValue:
    JustificationValue(value.native).value
  else:
    fallback

proc evalArg(env: Environment; node: SyntaxNode): Value {.raises: [EvaluatorError].} =
  env.eval(node)

proc evalArgs(env: Environment; nodes: seq[SyntaxNode]): seq[Value] {.raises: [EvaluatorError].} =
  for node in nodes:
    result.add env.evalArg(node)

proc evalConfig(env: Environment; body: seq[SyntaxNode]): BoxConfig {.raises: [EvaluatorError].} =
  result = cfg()
  for node in body:
    if node.kind != Binding:
      continue
    let value = env.eval(node.value)
    case node.bindingSymbol
    of "width":
      result.width = value.asSizePolicy(result.width)
    of "height":
      result.height = value.asSizePolicy(result.height)
    of "gap":
      result.gap = value.asNumber(result.gap)
    of "padding":
      result.padding = value.asNumber(result.padding)
    of "alignItems":
      result.alignItems = value.asAlignment(result.alignItems)
    of "justifyContent":
      result.justifyContent = value.asJustification(result.justifyContent)
    of "alignSelf":
      result.alignSelf = value.asAlignment(result.alignSelf)
    of "scrollX":
      result.scrollX = value.isTruthy
    of "scrollY":
      result.scrollY = value.isTruthy
    else:
      discard

proc childNodes(nodes: seq[SyntaxNode]): seq[SyntaxNode] =
  for node in nodes:
    if node.kind != Binding:
      result.add node

proc currentDir(runtime: NestCrowRuntime): string =
  if runtime.moduleStack.len > 0:
    runtime.moduleStack[^1].parentDir
  else:
    getCurrentDir()

proc resolveModulePath(runtime: NestCrowRuntime; path: string): string =
  if path.isAbsolute:
    return path.normalizedPath

  let local = (runtime.currentDir / path).normalizedPath
  if fileExists(local) or dirExists(local):
    return local

  let library = (getCurrentDir() / "lib" / path).normalizedPath
  if fileExists(library) or dirExists(library):
    return library

  (getCurrentDir() / path).normalizedPath

proc rememberFile(runtime: NestCrowRuntime; path: string) =
  try:
    runtime.loadedFiles[path] = getLastModificationTime(path)
  except OSError:
    discard

proc padInt(value, width: int): string =
  result = $value
  while result.len < width:
    result = "0" & result

proc leapYear(year: int): bool =
  (year mod 4 == 0 and year mod 100 != 0) or year mod 400 == 0

proc daysInMonth(year, month: int): int =
  case month
  of 1, 3, 5, 7, 8, 10, 12:
    31
  of 4, 6, 9, 11:
    30
  of 2:
    if leapYear(year): 29 else: 28
  else:
    0

proc weekday(year, month, day: int): int =
  const offsets = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
  var y = year
  if month < 3:
    dec y
  (y + y div 4 - y div 100 + y div 400 + offsets[month - 1] + day) mod 7

proc dateText(year, month, day: int): string =
  &"{padInt(year, 4)}-{padInt(month, 2)}-{padInt(day, 2)}"

proc clockRedrawMs(pattern: string): int =
  if pattern.contains("s"):
    1000
  else:
    60_000

proc requestRedrawAfter(runtime: NestCrowRuntime, ms: int) {.raises: [EvaluatorError].} =
  try:
    runtime.requireUi().requestRedrawAfter(ms)
  except EvaluatorError as error:
    raise error
  except Exception:
    discard

proc parseDateText(value: string): tuple[ok: bool, year, month, day: int] =
  let parts = value.split("-")
  if parts.len != 3:
    return
  try:
    result.year = parseInt(parts[0])
    result.month = parseInt(parts[1])
    result.day = parseInt(parts[2])
    result.ok =
      result.month >= 1 and result.month <= 12 and result.day >= 1 and
      result.day <= daysInMonth(result.year, result.month)
  except ValueError:
    discard

proc monthName(month: int): string =
  const names = [
    "January", "February", "March", "April", "May", "June", "July",
    "August", "September", "October", "November", "December"
  ]
  if month >= 1 and month <= 12:
    names[month - 1]
  else:
    ""

proc addMonths(value: string; delta: int): string =
  let parsed = parseDateText(value)
  if not parsed.ok:
    return value
  let index = parsed.year * 12 + parsed.month - 1 + delta
  let year = index div 12
  let month = index mod 12 + 1
  let day = min(parsed.day, daysInMonth(year, month))
  dateText(year, month, day)

proc launchDialogProcess(runtime: NestCrowRuntime; key, projectDir, data: string) {.raises: [EvaluatorError].} =
  if key in runtime.dialogProcesses:
    return
  let resolvedProjectDir =
    try:
      runtime.resolveModulePath(projectDir)
    except OSError as error:
      raise newException(EvaluatorError, projectDir & ": " & error.msg)
  if not dirExists(resolvedProjectDir):
    raise newException(EvaluatorError, "dialog project directory does not exist: " & resolvedProjectDir)
  let process =
    try:
      startProcess(
        getAppFilename(),
        args = @["dialog", resolvedProjectDir, data],
        options = {poUsePath, poStdErrToStdOut},
      )
    except OSError as error:
      raise newException(EvaluatorError, "could not start dialog process: " & error.msg)
    except IOError as error:
      raise newException(EvaluatorError, "could not start dialog process: " & error.msg)
  runtime.dialogProcesses[key] = DialogProcess(process: process)

proc pollDialogProcesses*(runtime: NestCrowRuntime) =
  var finished: seq[string]
  for key, dialog in runtime.dialogProcesses.pairs:
    if not dialog.process.running:
      let output = dialog.process.outputStream.readAll.strip
      runtime.dialogResults[key] = output
      dialog.process.close
      finished.add key
  for key in finished:
    runtime.dialogProcesses.del key

proc closeDialogProcesses*(runtime: NestCrowRuntime) =
  for dialog in runtime.dialogProcesses.values:
    if dialog.process.running:
      dialog.process.terminate
    dialog.process.close
  runtime.dialogProcesses.clear()

proc crowErrorLines*(message: string; maxLineLen = 68; maxLines = 7): seq[string] =
  for rawLine in message.splitLines:
    var line = rawLine
    if line.len == 0:
      result.add ""
    while line.len > maxLineLen:
      result.add line[0 ..< maxLineLen]
      line = line[maxLineLen .. ^1]
      if result.len >= maxLines:
        result[^1] = result[^1] & "..."
        return
    result.add line
    if result.len >= maxLines:
      if rawLine.len > line.len:
        result[^1] = result[^1] & "..."
      return

proc diagnosticLocation*(line: string): tuple[ok: bool, path: string, line: int, column: int] =
  var text = line.strip
  if text.startsWith("at "):
    text = text[3 .. ^1]
  let inIndex = text.find(" in ")
  if inIndex >= 0:
    text = text[0 ..< inIndex]
  let errorIndex = text.find(": error:")
  if errorIndex >= 0:
    text = text[0 ..< errorIndex]
  let columnSep = text.rfind(':')
  if columnSep < 0:
    return
  let lineSep = text.rfind(':', 0, columnSep - 1)
  if lineSep < 0:
    return
  try:
    result.line = parseInt(text[lineSep + 1 ..< columnSep])
    result.column = parseInt(text[columnSep + 1 .. ^1])
    result.path = text[0 ..< lineSep]
    result.ok = result.path.len > 0 and result.line > 0 and result.column > 0
  except ValueError:
    discard

proc openDiagnosticLocation*(line: string) =
  let location = diagnosticLocation(line)
  if not location.ok:
    return
  try:
    let process = startProcess(
      "emacsclient",
      args = @["-n", &"+{location.line}:{location.column}", location.path],
      options = {poUsePath},
    )
    process.close()
  except OSError:
    discard
  except IOError:
    discard

proc isErrorHighlightLine(line: string): bool =
  line.contains("error:") or line.strip.startsWith("^")

proc renderCrowErrorLine*(ui: var UI; index: int; line: string; width, height: SizePolicy) =
  let
    location = diagnosticLocation(line)
    fg =
      if isErrorHighlightLine(line):
        color(255, 92, 92)
      elif location.ok:
        color(255, 150, 150)
      else:
        ui.palette.textColor
  if ui.diagnosticLabel(ui.id("_nest_error_line", $index), line, fg, width, height, clickable = location.ok):
    openDiagnosticLocation(line)

proc renderErrorDialog*(runtime: NestCrowRuntime; ui: var UI; message: string) =
  if message.len == 0 or runtime.dismissedError == message:
    return

  let
    closeID = ui.id("_nest_error_close")
    copyID = ui.id("_nest_error_copy")

  ui.events:
    if ui.clicked(copyID):
      putClipboardText(message)
    if ui.clicked(closeID):
      runtime.dismissedError = message

  if runtime.dismissedError == message:
    return

  ui.center(ui.id("_nest_error_scrim"), fill(), fill()):
    ui.card(
      ui.id("_nest_error_dialog"),
      cfg(width = fixed(560), height = fit(), padding = 12, gap = 10, alignItems = AlignStretch),
    ):
      ui.dialogHeader(
        ui.id("_nest_error_header"),
        cfg(width = fill(), height = fit(), padding = 8, gap = 8, alignItems = AlignCenter),
      ):
        ui.label(ui.id("_nest_error_title"), "Crow error", fill(), fit())
        discard ui.button(closeID, "Close", fit(), fit())
      ui.column(
        ui.id("_nest_error_body"),
        cfg(width = fill(), height = fit(), padding = 8, gap = 4, alignItems = AlignStretch),
      ):
        for index, line in crowErrorLines(message):
          renderCrowErrorLine(ui, index, line, fill(), fit())
      ui.row(
        ui.id("_nest_error_actions"),
        cfg(width = fill(), height = fit(), gap = 8, justifyContent = JustifyEnd),
      ):
        discard ui.button(copyID, "Copy", fit(), fit())

proc loadSyntaxFile*(runtime: NestCrowRuntime; path: string): SyntaxNode {.raises: [EvaluatorError].} =
  var resolved = path
  try:
    resolved = runtime.resolveModulePath(path)
    result = crow.parse(readFile(resolved), resolved)
    runtime.rememberFile(resolved)
  except IOError as error:
    raise newException(EvaluatorError, resolved & ": " & error.msg)
  except OSError as error:
    raise newException(EvaluatorError, resolved & ": " & error.msg)
  except ParserError as error:
    let converted = newException(EvaluatorError, error.msg)
    converted.primary = error.primary
    converted.frames = error.frames
    raise converted

proc renderNodes(runtime: NestCrowRuntime; env: Environment; nodes: seq[SyntaxNode]): Value =
  result = nothing()
  for node in nodes:
    if runtime.hasError:
      return
    try:
      result = env.eval(node)
    except EvaluatorError as error:
      runtime.hasError = true
      runtime.lastError = report(error)
      return nothing()

proc renderNodes(runtime: NestCrowRuntime; nodes: seq[SyntaxNode]): Value =
  runtime.renderNodes(runtime.evaluator.env, nodes)

proc registerNestCommands(runtime: NestCrowRuntime) =
  runtime.evaluator.native "define":
    discard layout
    discard arguments
    result = nothing()
    for node in bodyNodes:
      if node.kind != Binding:
        raise newException(EvaluatorError, "define body entries must be bindings")
      if not env.contains(node.bindingSymbol):
        result = env.eval(node.value)
        env.define(node.bindingSymbol, result)

  runtime.evaluator.native "id":
    discard layout
    discard bodyNodes
    if arguments.len == 0:
      return widgetValue(nextWidgetID())
    var parts: seq[string]
    for value in env.evalArgs(arguments):
      parts.add value.asString
    widgetValue(runtime.requireUi().id(parts))

  runtime.evaluator.native "clicked":
    discard layout
    discard bodyNodes
    if arguments.len == 0:
      return boolean(false)
    let clicked =
      runtime.requireUi().inEventPhase() and
        runtime.requireUi().clicked(runtime.asWidgetID(env.eval(arguments[0])))
    if clicked:
      runtime.requireUi().markAllDirty()
    boolean(clicked)

  runtime.evaluator.native "keyPressed":
    discard layout
    discard bodyNodes
    if arguments.len != 1:
      raise newException(EvaluatorError, "keyPressed expects one key name")
    let pressed = runtime.requireUi().keyPressed(env.eval(arguments[0]).asString)
    if pressed:
      runtime.requireUi().markAllDirty()
    boolean(pressed)

  runtime.evaluator.native "fill":
    discard env
    discard arguments
    discard layout
    discard bodyNodes
    sizeValue(fill())

  runtime.evaluator.native "fit":
    discard env
    discard arguments
    discard layout
    discard bodyNodes
    sizeValue(fit())

  runtime.evaluator.native "fixed":
    discard layout
    discard bodyNodes
    if arguments.len != 1:
      raise newException(EvaluatorError, "fixed expects one size")
    sizeValue(fixed(env.eval(arguments[0]).asNumber))

  runtime.evaluator.native "hug":
    discard layout
    discard bodyNodes
    if arguments.len != 1:
      raise newException(EvaluatorError, "hug expects one size")
    sizeValue(hug(env.eval(arguments[0]).asNumber))

  runtime.evaluator.native "prefer":
    discard layout
    discard bodyNodes
    if arguments.len != 1:
      raise newException(EvaluatorError, "prefer expects one size")
    sizeValue(prefer(env.eval(arguments[0]).asNumber))

  runtime.evaluator.native "clock":
    discard layout
    discard bodyNodes
    let pattern =
      if arguments.len > 0:
        env.eval(arguments[0]).asString
      else:
        "HH:mm"
    runtime.requestRedrawAfter(clockRedrawMs(pattern))
    text(now().format(pattern))

  runtime.evaluator.native "today-date":
    discard env
    discard arguments
    discard layout
    discard bodyNodes
    runtime.requestRedrawAfter(60 * 60 * 1000)
    text(now().format("yyyy-MM-dd"))

  runtime.evaluator.native "date":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 3:
      raise newException(EvaluatorError, "date expects year, month, and day")
    text(dateText(values[0].asNumber.int, values[1].asNumber.int, values[2].asNumber.int))

  runtime.evaluator.native "date-year":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "date-year expects one date")
    let parsed = parseDateText(values[0].asString)
    if not parsed.ok:
      raise newException(EvaluatorError, "date-year expects YYYY-MM-DD")
    number(parsed.year.float64)

  runtime.evaluator.native "date-month":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "date-month expects one date")
    let parsed = parseDateText(values[0].asString)
    if not parsed.ok:
      raise newException(EvaluatorError, "date-month expects YYYY-MM-DD")
    number(parsed.month.float64)

  runtime.evaluator.native "date-day":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "date-day expects one date")
    let parsed = parseDateText(values[0].asString)
    if not parsed.ok:
      raise newException(EvaluatorError, "date-day expects YYYY-MM-DD")
    number(parsed.day.float64)

  runtime.evaluator.native "date-days-in-month":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 2:
      raise newException(EvaluatorError, "date-days-in-month expects year and month")
    let count = daysInMonth(values[0].asNumber.int, values[1].asNumber.int)
    if count == 0:
      raise newException(EvaluatorError, "date-days-in-month expects month 1..12")
    number(count.float64)

  runtime.evaluator.native "date-first-weekday":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 2:
      raise newException(EvaluatorError, "date-first-weekday expects year and month")
    let
      year = values[0].asNumber.int
      month = values[1].asNumber.int
    if month < 1 or month > 12:
      raise newException(EvaluatorError, "date-first-weekday expects month 1..12")
    number(weekday(year, month, 1).float64)

  runtime.evaluator.native "date-month-name":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "date-month-name expects one month")
    let name = monthName(values[0].asNumber.int)
    if name.len == 0:
      raise newException(EvaluatorError, "date-month-name expects month 1..12")
    text(name)

  runtime.evaluator.native "date-month-title":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 2:
      raise newException(EvaluatorError, "date-month-title expects year and month")
    let
      year = values[0].asNumber.int
      name = monthName(values[1].asNumber.int)
    if name.len == 0:
      raise newException(EvaluatorError, "date-month-title expects month 1..12")
    text(&"{name} {year}")

  runtime.evaluator.native "date-add-months":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 2:
      raise newException(EvaluatorError, "date-add-months expects date and month delta")
    text(addMonths(values[0].asString, values[1].asNumber.int))

  runtime.evaluator.native "openDialog":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len < 2 or values.len > 3:
      raise newException(EvaluatorError, "openDialog expects key, projectDir, and optional data")
    let
      key = values[0].asString
      projectDir = values[1].asString
      data = if values.len > 2: values[2].asString else: ""
    runtime.launchDialogProcess(key, projectDir, data)
    boolean(true)

  runtime.evaluator.native "dialogOpen?":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "dialogOpen? expects key")
    boolean(values[0].asString in runtime.dialogProcesses)

  runtime.evaluator.native "dialogResult":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "dialogResult expects key")
    let key = values[0].asString
    if key in runtime.dialogResults:
      text(runtime.dialogResults[key])
    else:
      nothing()

  runtime.evaluator.native "clearDialogResult":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "clearDialogResult expects key")
    runtime.dialogResults.del values[0].asString
    nothing()

  runtime.evaluator.native "dialogData":
    discard env
    discard arguments
    discard layout
    discard bodyNodes
    text(runtime.dialogData)

  runtime.evaluator.native "closeDialog":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    runtime.dialogCloseValue =
      if values.len > 0:
        values[0].asString
      else:
        ""
    runtime.requestQuit = true
    text(runtime.dialogCloseValue)

  runtime.evaluator.native "import":
    discard layout
    discard bodyNodes
    if arguments.len != 1:
      raise newException(EvaluatorError, "import expects one path")
    let path = env.eval(arguments[0]).asString
    var resolved = path
    try:
      resolved = runtime.resolveModulePath(path)
    except OSError as error:
      raise newException(EvaluatorError, path & ": " & error.msg)
    if resolved in runtime.moduleStack:
      return nothing()
    let node = runtime.loadSyntaxFile(resolved)
    runtime.moduleStack.add resolved
    try:
      result = runtime.renderNodes(env, node.statements)
    finally:
      runtime.moduleStack.setLen(runtime.moduleStack.len - 1)

  runtime.evaluator.native "events":
    discard env
    discard arguments
    discard layout
    if runtime.requireUi().inEventPhase():
      runtime.renderNodes(env, bodyNodes)
    else:
      nothing()

  runtime.evaluator.native "scope":
    discard layout
    if arguments.len == 0:
      return runtime.renderNodes(env, bodyNodes)
    let key = env.eval(arguments[0]).asString
    runtime.currentUi[].scope(key):
      result = runtime.renderNodes(env, bodyNodes)

  runtime.evaluator.native "panel":
    discard layout
    let values = env.evalArgs(arguments)
    let id =
      if values.len > 0: runtime.asWidgetID(values[0]) else: nextWidgetID()
    let config = env.evalConfig(bodyNodes)
    runtime.currentUi[].panel(id, config):
      discard runtime.renderNodes(env, bodyNodes.childNodes)
    nothing()

  runtime.evaluator.native "card":
    discard layout
    let values = env.evalArgs(arguments)
    let id =
      if values.len > 0: runtime.asWidgetID(values[0]) else: nextWidgetID()
    let config = env.evalConfig(bodyNodes)
    runtime.currentUi[].card(id, config):
      discard runtime.renderNodes(env, bodyNodes.childNodes)
    nothing()

  runtime.evaluator.native "dialogHeader":
    discard layout
    let values = env.evalArgs(arguments)
    let id =
      if values.len > 0: runtime.asWidgetID(values[0]) else: nextWidgetID()
    let config = env.evalConfig(bodyNodes)
    runtime.currentUi[].dialogHeader(id, config):
      discard runtime.renderNodes(env, bodyNodes.childNodes)
    nothing()

  runtime.evaluator.native "row":
    discard layout
    let values = env.evalArgs(arguments)
    let id =
      if values.len > 0: runtime.asWidgetID(values[0]) else: nextWidgetID()
    let config = env.evalConfig(bodyNodes)
    runtime.currentUi[].row(id, config):
      discard runtime.renderNodes(env, bodyNodes.childNodes)
    nothing()

  runtime.evaluator.native "column":
    discard layout
    let values = env.evalArgs(arguments)
    let id =
      if values.len > 0: runtime.asWidgetID(values[0]) else: nextWidgetID()
    let config = env.evalConfig(bodyNodes)
    runtime.currentUi[].column(id, config):
      discard runtime.renderNodes(env, bodyNodes.childNodes)
    nothing()

  runtime.evaluator.native "spacer":
    discard layout
    let values = env.evalArgs(arguments)
    let id =
      if values.len > 0: runtime.asWidgetID(values[0]) else: nextWidgetID()
    let config = env.evalConfig(bodyNodes)
    discard runtime.currentUi[].spacer(id, config.width, config.height, config.alignSelf)
    nothing()

  runtime.evaluator.native "label":
    discard layout
    let values = env.evalArgs(arguments)
    let id =
      if values.len > 0: runtime.asWidgetID(values[0]) else: nextWidgetID()
    let labelText =
      if values.len > 1:
        values[1].asString
      else:
        ""
    let config = env.evalConfig(bodyNodes)
    runtime.currentUi[].label(id, labelText, config.width, config.height, alignSelf = config.alignSelf)
    nothing()

  runtime.evaluator.native "button":
    discard layout
    let values = env.evalArgs(arguments)
    let id =
      if values.len > 0: runtime.asWidgetID(values[0]) else: nextWidgetID()
    let labelText =
      if values.len > 1:
        values[1].asString
      else:
        ""
    let config = env.evalConfig(bodyNodes)
    boolean(runtime.currentUi[].button(id, labelText, config.width, config.height, config.alignSelf))

  runtime.evaluator.env.define("AlignAuto", alignValue(AlignAuto))
  runtime.evaluator.env.define("AlignStart", alignValue(AlignStart))
  runtime.evaluator.env.define("AlignCenter", alignValue(AlignCenter))
  runtime.evaluator.env.define("AlignEnd", alignValue(AlignEnd))
  runtime.evaluator.env.define("AlignStretch", alignValue(AlignStretch))
  runtime.evaluator.env.define("JustifyStart", justifyValue(JustifyStart))
  runtime.evaluator.env.define("JustifyCenter", justifyValue(JustifyCenter))
  runtime.evaluator.env.define("JustifyEnd", justifyValue(JustifyEnd))

proc init*(T: typedesc[NestCrowRuntime]): T =
  result = T(
    evaluator: Evaluator.init(),
    dialogProcesses: initTable[string, DialogProcess](),
    dialogResults: initTable[string, string](),
  )
  result.registerNestCommands()

proc get*(runtime: NestCrowRuntime; name: string): Value {.raises: [EvaluatorError].} =
  runtime.evaluator.env.get(name)

proc widgetID*(runtime: NestCrowRuntime; name: string): WidgetID {.raises: [EvaluatorError].} =
  runtime.asWidgetID(runtime.get(name))

proc dependenciesChanged*(runtime: NestCrowRuntime): bool =
  for path, lastTime in runtime.loadedFiles:
    try:
      if getLastModificationTime(path) != lastTime:
        return true
    except OSError:
      return true

proc reload*(app: NestCrowApp): bool {.discardable.} =
  app.runtime = NestCrowRuntime.init()
  app.runtime.loadedFiles.clear()
  try:
    app.program = app.runtime.loadSyntaxFile(app.rootPath)
    app.lastError = ""
    true
  except EvaluatorError as error:
    app.program = nil
    app.lastError = report(error)
    false

proc init*(T: typedesc[NestCrowApp]; rootPath: string): T =
  result = T(rootPath: rootPath.normalizedPath, runtime: NestCrowRuntime.init())
  discard result.reload()

proc render*(runtime: NestCrowRuntime; ui: var UI; program: SyntaxNode) =
  if program.isNil:
    return
  runtime.pollDialogProcesses()
  runtime.hasError = false
  runtime.lastError = ""
  runtime.currentUi = addr ui
  try:
    ui.layout:
      discard runtime.renderNodes(program.statements)
  finally:
    runtime.currentUi = nil

proc loadComponentLibrary*(runtime: NestCrowRuntime; path: string) =
  let resolved = runtime.resolveModulePath(path)
  let node = runtime.loadSyntaxFile(resolved)
  runtime.moduleStack.add resolved
  try:
    discard runtime.renderNodes(node.statements)
  finally:
    runtime.moduleStack.setLen(runtime.moduleStack.len - 1)

proc renderComponent*(
    runtime: NestCrowRuntime;
    ui: var UI;
    libraryPath, componentName: string;
    arguments: openArray[SyntaxNode],
) =
  if runtime.hasError:
    return
  runtime.currentUi = addr ui
  try:
    if libraryPath.len > 0:
      runtime.loadComponentLibrary(libraryPath)
    var nodes: seq[SyntaxNode]
    for argument in arguments:
      nodes.add argument
    discard runtime.renderNodes(@[command(symbol(componentName), nodes)])
  finally:
    runtime.currentUi = nil

proc renderComponent*(
    runtime: NestCrowRuntime;
    ui: var UI;
    libraryPath, componentName: string;
    arguments: openArray[string] = [],
) =
  var nodes: seq[SyntaxNode]
  for argument in arguments:
    nodes.add stringLiteral(argument)
  runtime.renderComponent(ui, libraryPath, componentName, nodes)

proc renderLayoutOnly*(
    runtime: NestCrowRuntime; ui: var UI; program: SyntaxNode; width, height: int
) =
  if program.isNil:
    return
  runtime.pollDialogProcesses()
  runtime.hasError = false
  runtime.lastError = ""
  runtime.currentUi = addr ui
  try:
    ui.beginLayout(width, height)
    discard runtime.renderNodes(program.statements)
    ui.applyIntrinsicSizes(ui.resources)
    discard ui.endLayout()
  finally:
    runtime.currentUi = nil

proc render*(app: NestCrowApp; ui: var UI) =
  if app.isNil:
    return
  if app.program.isNil or app.runtime.dependenciesChanged():
    discard app.reload()
  if app.program.isNil:
    return
  app.runtime.moduleStack.add app.rootPath
  app.runtime.render(ui, app.program)
  app.runtime.moduleStack.setLen(app.runtime.moduleStack.len - 1)
  if app.runtime.hasError:
    app.lastError = app.runtime.lastError
  else:
    app.lastError = ""
