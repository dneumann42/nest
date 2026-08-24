import
  std/[json, locks, math, os, osproc, sets, streams, strformat, strutils,
      tables, times]

import owl, palette, ui, dialogs
import nest/[input, perf, screen]

const MaintenancePollMs = 100

type
  WidgetIDValue* = ref object of NativeValue
    value*: WidgetID
    key*: string

  SizePolicyValue* = ref object of NativeValue
    value*: SizePolicy

  AlignmentValue* = ref object of NativeValue
    value*: Alignment

  JustificationValue* = ref object of NativeValue
    value*: Justification

  ButtonBorderStyleValue* = ref object of NativeValue
    value*: ButtonBorderStyle

  ButtonChromeStyleValue* = ref object of NativeValue
    value*: ButtonChromeStyle

  ColorValue* = ref object of NativeValue
    value*: Color

  InsetsValue* = ref object of NativeValue
    value*: EdgeInsets

  DialogProcess = ref object
    process: Process
    resultPath: string

  DialogLaunchOptions = object
    dismissOnInactive: bool
    inactiveGraceMs: int
    hasValues: bool

  ShellProcess = ref object
    process: Process
    command: string

  ShellCache = object
    output: string
    ticks: int

  StateBinding = object
    env: Environment
    symbol: string
    key: string

  WorkspaceSubscription = ref object
    lock: Lock
    thread: Thread[WorkspaceSubscription]
    process: Process
    output: string
    generation: int
    stopping: bool
    event: string
    query: string

  ErrorLocation* = object
    path*, sourceLine*, label*: string
    line*, column*: int

  ErrorDetails* = object
    message*: string
    primary*: ErrorLocation
    frames*: seq[ErrorLocation]

  NestOwlRuntime* = ref object
    evaluator*: Evaluator
    externalEvents: CountTable[string]
    widgetState: Table[string, Value]
    stateBindings: seq[StateBinding]
    messages: Table[string, seq[Value]]
    loadedFiles*: Table[string, Time]
    loadedModules*: HashSet[string]
    dialogProcesses*: Table[string, DialogProcess]
    dialogResults*: Table[string, string]
    openMenus*: Table[string, string]
    pendingPathCallbacks: seq[PendingPathCallback]
    pathPickerResults: Table[string, string]
    editorStates: Table[string, EditorState]
    shellProcesses*: Table[string, ShellProcess]
    shellCache*: Table[string, ShellCache]
    workspaceSubscriptions*: Table[string, WorkspaceSubscription]
    dialogData*: string
    dialogCloseValue*: string
    dialogCloseRequested*: bool
    requestQuit*: bool
    moduleStack: seq[string]
    currentUi: ptr UI
    hasError*: bool
    lastError*: string
    lastErrorDetails*: ErrorDetails
    dismissedError*: string
    nextFullRenderTicks: int

  NestOwlApp* = ref object
    rootPath*: string
    runtime*: NestOwlRuntime
    program*: SyntaxNode
    lastError*: string
    lastErrorDetails*: ErrorDetails
    errorDialogProcess*: Process
    errorDialogMessage*: string
    lastFullRenderTicks: int
    lastMaintenanceTicks: int

  MenuEntryKind = enum
    MenuEntryItem
    MenuEntryDivider

  MenuEntry = object
    kind: MenuEntryKind
    path: string
    label: string
    body: seq[SyntaxNode]

  MenuSpec = object
    label: string
    path: string
    body: seq[SyntaxNode]

  PendingPathCallback = object
    env: Environment
    command: CommandValue
    path: string

proc errorLocation*(pos: SourcePos, label = ""): ErrorLocation =
  ## Return the error location `pos` points at, tagged with `label`.
  ##
  ## Positions that carry no source information yield an empty path.
  result.label = label
  if pos.hasSource:
    result.path = pos.sourcePath
    result.sourceLine = pos.sourceLine
    result.line = pos.line.int
    result.column = pos.column.int

proc errorDetails*(error: ref EvaluatorError): ErrorDetails =
  ## Turn an evaluator error into the report shown in the error dialog:
  ## its message, the position that failed and the call frames above it.
  result.message = error.msg
  result.primary = error.primary.errorLocation()
  for frame in error.frames:
    result.frames.add frame.pos.errorLocation(frame.label)

proc errorReport*(details: ErrorDetails): string =
  ## Format error details as the plain-text report written to the terminal.
  ##
  ## Returns the message, the failing source position and the source line
  ## when one is known, followed by the call frames.
  result = "error: " & details.message
  if details.primary.path.len > 0:
    result.add "\n" & details.primary.path & ":" & $details.primary.line & ":" &
      $details.primary.column
  if details.primary.sourceLine.len > 0:
    result.add "\n" & details.primary.sourceLine
    if details.primary.column > 0:
      result.add "\n" & repeat(' ', max(details.primary.column - 1, 0)) & "^"
  if details.frames.len > 0:
    result.add "\nStack trace:"
    for frame in details.frames:
      result.add "\n  at " & frame.path & ":" & $frame.line & ":" &
        $frame.column
      if frame.label.len > 0:
        result.add " in " & frame.label

proc init*(T: typedesc[NestOwlRuntime]): T
  ## Create a runtime with a fresh evaluator and Nest's owl builtins.
proc renderNodes(
  runtime: NestOwlRuntime, env: Environment, nodes: seq[SyntaxNode]
): Value

proc renderNodes(runtime: NestOwlRuntime, nodes: seq[SyntaxNode]): Value

type RuntimeWakeProc = proc() {.gcsafe, raises: [].}
type PathSelectedProc* = proc(path: string) {.closure, raises: [].}
type PathPickerProc* = proc(callback: PathSelectedProc) {.closure, raises: [].}

var runtimeWake*: RuntimeWakeProc = proc() {.gcsafe, raises: [].} =
  discard

var pickFileDialog*: PathPickerProc = proc(
    callback: PathSelectedProc) {.closure, raises: [].} =
  try:
    dialogs.browse(callback)
  except CatchableError:
    discard

var pickDirectoryDialog*: PathPickerProc = proc(
    callback: PathSelectedProc) {.closure, raises: [].} =
  try:
    dialogs.browseFolder(callback)
  except CatchableError:
    discard

proc queueExternal*(runtime: NestOwlRuntime, name: string) =
  ## Queue an external event called `name`, to be delivered to the program on
  ## its next frame. Empty names are ignored.
  if name.len > 0:
    runtime.externalEvents.inc(name)

proc consumeExternal(runtime: NestOwlRuntime, name: string): bool =
  let count = runtime.externalEvents.getOrDefault(name)
  if count <= 0:
    return false
  if count == 1:
    runtime.externalEvents.del(name)
  else:
    runtime.externalEvents[name] = count - 1
  true

proc stateKey(scope, field: string): string {.raises: [].} =
  scope & "\x1f" & field

proc receiveMessage(runtime: NestOwlRuntime, topic: string): Value {.raises: [].} =
  var queue = runtime.messages.getOrDefault(topic)
  if queue.len == 0:
    return nothing()
  result = queue[0]
  queue.delete(0)
  if queue.len == 0:
    runtime.messages.del(topic)
  else:
    runtime.messages[topic] = queue

proc commitState(runtime: NestOwlRuntime) {.raises: [].} =
  for binding in runtime.stateBindings:
    let value = binding.env.bindings.getOrDefault(binding.symbol)
    runtime.widgetState[binding.key] = value

proc widgetValue(id: WidgetID, key = ""): Value =
  nativeValue(WidgetIDValue(value: id, key: key))

proc sizeValue(policy: SizePolicy): Value =
  nativeValue(SizePolicyValue(value: policy))

proc alignValue(alignment: Alignment): Value =
  nativeValue(AlignmentValue(value: alignment))

proc justifyValue(justification: Justification): Value =
  nativeValue(JustificationValue(value: justification))

proc buttonBorderStyleValue(style: ButtonBorderStyle): Value =
  nativeValue(ButtonBorderStyleValue(value: style))

proc buttonChromeStyleValue(style: ButtonChromeStyle): Value =
  nativeValue(ButtonChromeStyleValue(value: style))

proc colorValue(color: Color): Value =
  nativeValue(ColorValue(value: color))

proc insetsValue(insets: EdgeInsets): Value =
  nativeValue(InsetsValue(value: insets))

proc requireUi(runtime: NestOwlRuntime): var UI {.raises: [EvaluatorError].} =
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
      let widget = WidgetIDValue(value.native)
      if widget.key.len > 0:
        widget.key
      else:
        $widget.value
    else:
      $value
  else:
    $value

proc asNumber(value: Value, fallback = 0.0): float64 =
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

proc asIntSet(value: Value): HashSet[int] =
  proc addToken(result: var HashSet[int], token: string) =
    let item = token.strip
    if item.len == 0:
      return
    try:
      let parsed = parseInt(item)
      if parsed > 0:
        result.incl parsed
    except ValueError:
      discard

  case value.kind
  of Number:
    let parsed = value.number.int
    if parsed > 0:
      result.incl parsed
  of List:
    for item in value.items:
      for token in item.asString.replace(",", " ").splitWhitespace:
        result.addToken(token)
  else:
    for token in value.asString.replace(",", " ").splitWhitespace:
      result.addToken(token)

proc asWidgetID(runtime: NestOwlRuntime, value: Value): WidgetID =
  if value.kind == Native and value.native of WidgetIDValue:
    WidgetIDValue(value.native).value
  else:
    runtime.requireUi().id(value.asString)

proc asSizePolicy(value: Value, fallback: SizePolicy): SizePolicy =
  if value.kind == Native and value.native of SizePolicyValue:
    SizePolicyValue(value.native).value
  else:
    fallback

proc asAlignment(value: Value, fallback: Alignment): Alignment =
  if value.kind == Native and value.native of AlignmentValue:
    AlignmentValue(value.native).value
  else:
    fallback

proc asJustification(value: Value, fallback: Justification): Justification =
  if value.kind == Native and value.native of JustificationValue:
    JustificationValue(value.native).value
  else:
    fallback

proc asButtonBorderStyle(value: Value,
    fallback: ButtonBorderStyle): ButtonBorderStyle =
  if value.kind == Native and value.native of ButtonBorderStyleValue:
    ButtonBorderStyleValue(value.native).value
  else:
    case value.asString.normalize
    of "none", "no", "off":
      ButtonBorderNone
    of "line", "default", "border":
      ButtonBorderLine
    else:
      fallback

proc asButtonChromeStyle(value: Value,
    fallback: ButtonChromeStyle): ButtonChromeStyle =
  if value.kind == Native and value.native of ButtonChromeStyleValue:
    ButtonChromeStyleValue(value.native).value
  else:
    case value.asString.normalize
    of "flat", "none", "plain":
      ButtonChromeFlat
    of "raised", "default", "chrome":
      ButtonChromeRaised
    else:
      fallback

proc asColor(value: Value, fallback: Color): Color =
  if value.kind == Native and value.native of ColorValue:
    ColorValue(value.native).value
  else:
    fallback

proc asInsets(value: Value, fallback: EdgeInsets): EdgeInsets =
  if value.kind == Native and value.native of InsetsValue:
    InsetsValue(value.native).value
  elif value.kind in {Number, Text}:
    insets(value.asNumber(fallback.left))
  else:
    fallback

proc asCornerStyle(value: Value, fallback: CornerStyle): CornerStyle =
  case value.asString.normalize
  of "rounded", "round":
    RoundedCorners
  of "flat", "square":
    FlatCorners
  else:
    fallback

proc asAnimationCurve(value: Value, fallback: AnimationCurve): AnimationCurve =
  case value.asString.normalize
  of "linear":
    Linear
  of "easein", "in":
    EaseIn
  of "easeout", "out":
    EaseOut
  of "easeinout", "inout":
    EaseInOut
  of "smoothstep", "smooth":
    SmoothStep
  of "spring":
    Spring
  of "backout", "back":
    BackOut
  else:
    fallback

proc normalizedMenuPart(value: string): string =
  for ch in value.normalize:
    if ch in {'a' .. 'z', '0' .. '9', '_', '-'}:
      result.add ch

proc menuPathJoin(parent, child: string): string =
  if parent.len == 0:
    child
  elif child.len == 0:
    parent
  else:
    parent & "." & child

proc commandSymbol(node: SyntaxNode): string =
  if node.kind == Command and node.callee.kind ==
      Symbol: node.callee.symbol else: ""

proc idKey(
    env: Environment, node: SyntaxNode, fallback: string
): string {.raises: [EvaluatorError].} =
  if node.kind == String:
    return node.stringValue
  if node.kind == Command and node.commandSymbol == "id":
    var parts: seq[string]
    for argument in node.arguments:
      parts.add env.eval(argument).asString
    if parts.len > 0:
      return parts.join(":")
  let value = env.eval(node)
  if value.kind == Native and value.native of WidgetIDValue:
    let widget = WidgetIDValue(value.native)
    if widget.key.len > 0:
      return widget.key
  fallback

proc menuKey(key: string): string =
  "menu:" & key

proc asByte(value: Value, fallback = 0): uint8 =
  uint8(value.asNumber(fallback.float64).int.clamp(0, 255))

proc mixChannel(a, b: uint8, amount: float64): uint8 =
  uint8((a.float64 + (b.float64 - a.float64) * amount).round.int.clamp(0, 255))

proc mixColor(a, b: Color, amount: float64): Color =
  let t = amount.clamp(0.0, 1.0)
  color(
    mixChannel(a.r, b.r, t),
    mixChannel(a.g, b.g, t),
    mixChannel(a.b, b.b, t),
    mixChannel(a.a, b.a, t),
  )

proc evalArg(env: Environment, node: SyntaxNode): Value {.raises: [
    EvaluatorError].} =
  env.eval(node)

proc evalArgs(
    env: Environment, nodes: seq[SyntaxNode]
): seq[Value] {.raises: [EvaluatorError].} =
  for node in nodes:
    result.add env.evalArg(node)

proc evalConfig(
    env: Environment, body: seq[SyntaxNode], defaults: BoxConfig
): BoxConfig {.raises: [EvaluatorError].} =
  result = defaults
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
      result.padding = value.asInsets(result.padding)
    of "paddingLeft":
      result.padding.left = value.asNumber(result.padding.left)
    of "paddingTop":
      result.padding.top = value.asNumber(result.padding.top)
    of "paddingRight":
      result.padding.right = value.asNumber(result.padding.right)
    of "paddingBottom":
      result.padding.bottom = value.asNumber(result.padding.bottom)
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
    of "scrollWheel":
      result.scrollWheel = value.isTruthy
    of "textScroll":
      result.textScroll = value.isTruthy
    of "lineNumbers":
      result.lineNumbers = value.isTruthy
    of "scrollbars":
      result.scrollbars = value.isTruthy
    of "gutterMarkers":
      result.gutterMarkers = value.asIntSet
    of "activeLine":
      result.activeLine = value.asNumber.int
    of "fontName":
      result.fontName = value.asString
    of "fontSize":
      result.fontSize = value.asNumber(result.fontSize.float64).int
    of "buttonPadding":
      result.buttonPadding = value.asInsets(result.buttonPadding)
    of "buttonBorderStyle":
      result.buttonBorderStyle = value.asButtonBorderStyle(
          result.buttonBorderStyle)
    of "buttonChromeStyle", "buttonStyle":
      result.buttonChromeStyle = value.asButtonChromeStyle(
          result.buttonChromeStyle)
    of "buttonTextAlign", "textAlign":
      result.buttonTextAlign = value.asJustification(result.buttonTextAlign)
    of "syntax", "syntaxHighlighter":
      result.syntax = value.asString
    of "background", "backgroundColor":
      result.style.hasBackground = true
      result.style.background = value.asColor(result.style.background)
    of "opacity":
      result.style.hasOpacity = true
      result.style.opacity = value.asNumber(1.0)
    of "cornerStyle", "cornerType", "corners":
      result.style.cornerStyle = value.asCornerStyle(result.style.cornerStyle)
    of "radius", "cornerRadius":
      result.style.cornerRadii = radii(value.asNumber)
    of "radiusTopLeft", "cornerRadiusTopLeft":
      result.style.cornerRadii.topLeft = value.asNumber(
          result.style.cornerRadii.topLeft)
    of "radiusTopRight", "cornerRadiusTopRight":
      result.style.cornerRadii.topRight = value.asNumber(
          result.style.cornerRadii.topRight)
    of "radiusBottomRight", "cornerRadiusBottomRight":
      result.style.cornerRadii.bottomRight = value.asNumber(
          result.style.cornerRadii.bottomRight)
    of "radiusBottomLeft", "cornerRadiusBottomLeft":
      result.style.cornerRadii.bottomLeft = value.asNumber(
          result.style.cornerRadii.bottomLeft)
    of "shadow", "boxShadow":
      result.style.hasShadow = value.isTruthy
      if result.style.shadowColor.a == 0:
        result.style.shadowColor = color(0, 0, 0, 96)
      if result.style.shadowBlur <= 0:
        result.style.shadowBlur = 8
      if result.style.shadowOffsetY == 0:
        result.style.shadowOffsetY = 3
    of "shadowColor":
      result.style.hasShadow = true
      result.style.shadowColor = value.asColor(result.style.shadowColor)
    of "shadowOffsetX":
      result.style.hasShadow = true
      result.style.shadowOffsetX = value.asNumber(result.style.shadowOffsetX)
    of "shadowOffsetY":
      result.style.hasShadow = true
      result.style.shadowOffsetY = value.asNumber(result.style.shadowOffsetY)
    of "shadowBlur":
      result.style.hasShadow = true
      result.style.shadowBlur = value.asNumber(result.style.shadowBlur)
    of "shadowSpread":
      result.style.hasShadow = true
      result.style.shadowSpread = value.asNumber(result.style.shadowSpread)
    else:
      discard

proc evalConfig(
    env: Environment, body: seq[SyntaxNode]
): BoxConfig {.raises: [EvaluatorError].} =
  env.evalConfig(body, cfg())

proc widgetID(runtime: NestOwlRuntime, values: seq[Value]): WidgetID =
  if values.len > 0:
    runtime.asWidgetID(values[0])
  else:
    nextWidgetID()

proc widgetID(runtime: NestOwlRuntime, values: seq[Value],
    fallback: string): WidgetID =
  if values.len > 0:
    runtime.asWidgetID(values[0])
  else:
    runtime.requireUi().id(fallback)

proc textArg(values: seq[Value], index: int, fallback = ""): string =
  if values.len > index:
    values[index].asString
  else:
    fallback

proc fontName(
    runtime: NestOwlRuntime, config: BoxConfig
): string {.raises: [EvaluatorError].} =
  try:
    runtime.currentUi[].fontAtSize(config.fontName, config.fontSize)
  except Exception as error:
    raise newException(EvaluatorError, error.msg)

proc evalAnimationSpec(
    env: Environment, body: seq[SyntaxNode], fallback = dialogPopIn()
): AnimationSpec {.raises: [EvaluatorError].} =
  result = fallback
  for node in body:
    if node.kind != Binding:
      continue
    let value = env.eval(node.value)
    case node.bindingSymbol
    of "duration", "durationMs":
      result.durationMs = max(value.asNumber(result.durationMs.float64).int, 1)
    of "curve", "easing", "formula":
      result.curve = value.asAnimationCurve(result.curve)
    of "fromOpacity":
      result.fromOpacity = value.asNumber(result.fromOpacity)
    of "toOpacity", "opacity", "maxOpacity", "targetOpacity", "finalOpacity":
      result.toOpacity = value.asNumber(result.toOpacity)
    of "fromScale":
      result.fromScale = value.asNumber(result.fromScale)
    of "toScale", "scale":
      result.toScale = value.asNumber(result.toScale)
    of "offsetX":
      result.offsetX = value.asNumber(result.offsetX)
    of "offsetY":
      result.offsetY = value.asNumber(result.offsetY)
    else:
      discard

proc childNodes(nodes: seq[SyntaxNode]): seq[SyntaxNode] =
  for node in nodes:
    if node.kind != Binding:
      result.add node

proc menuArgText(
    env: Environment, node: SyntaxNode
): string {.raises: [EvaluatorError].} =
  case node.kind
  of String:
    node.stringValue
  of Symbol:
    node.symbol
  else:
    env.eval(node).asString

proc menuArgs(
    env: Environment, arguments: seq[SyntaxNode]
): tuple[path, label: string] {.raises: [EvaluatorError].} =
  case arguments.len
  of 0:
    discard
  of 1:
    result.label = env.menuArgText(arguments[0])
    result.path = normalizedMenuPart(result.label)
  else:
    result.path = env.menuArgText(arguments[0])
    result.label = env.menuArgText(arguments[1])
  if result.path.len == 0:
    result.path = normalizedMenuPart(result.label)
  if result.label.len == 0:
    result.label = result.path

proc collectMenuEntries(
    env: Environment, parentPath: string, body: seq[SyntaxNode]
): seq[MenuEntry] {.raises: [EvaluatorError].} =
  for node in body:
    case node.commandSymbol
    of "menuItem":
      let args = env.menuArgs(node.arguments)
      result.add MenuEntry(
        kind: MenuEntryItem,
        path: menuPathJoin(parentPath, args.path),
        label: args.label,
        body: node.body,
      )
    of "menuDivider":
      result.add MenuEntry(kind: MenuEntryDivider)
    else:
      discard

proc collectMenus(
    env: Environment, body: seq[SyntaxNode]
): seq[MenuSpec] {.raises: [EvaluatorError].} =
  for node in body:
    if node.commandSymbol != "menu":
      continue
    let args = env.menuArgs(node.arguments)
    result.add MenuSpec(label: args.label, path: args.path, body: node.body)

proc currentDir(runtime: NestOwlRuntime): string =
  if runtime.moduleStack.len > 0:
    runtime.moduleStack[^1].parentDir
  else:
    getCurrentDir()

proc resolveModulePath(runtime: NestOwlRuntime, path: string): string =
  if path.isAbsolute:
    return path.normalizedPath

  let local = (runtime.currentDir / path).normalizedPath
  if fileExists(local) or dirExists(local):
    return local

  let library = (getCurrentDir() / "lib" / path).normalizedPath
  if fileExists(library) or dirExists(library):
    return library

  (getCurrentDir() / path).normalizedPath

proc rememberFile(runtime: NestOwlRuntime, path: string) =
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
  if pattern.contains("s"): 1000 else: 60_000

proc requestRedrawAfter(
    runtime: NestOwlRuntime, ms: int
) {.raises: [EvaluatorError].} =
  try:
    let due = input.getTicks() + max(ms, 0)
    if runtime.nextFullRenderTicks == 0 or due < runtime.nextFullRenderTicks:
      runtime.nextFullRenderTicks = due
    runtime.requireUi().requestRedrawAfter(ms)
  except EvaluatorError as error:
    raise error
  except Exception:
    discard

proc queuePathCallback(
    runtime: NestOwlRuntime, env: Environment, command: CommandValue, path: string
) =
  runtime.pendingPathCallbacks.add PendingPathCallback(
    env: env, command: command, path: path
  )
  try:
    runtimeWake()
  except Exception:
    discard

proc queuePathEvent(runtime: NestOwlRuntime, eventName, path: string) =
  if eventName.len == 0:
    return
  runtime.pathPickerResults[eventName] = path
  runtime.queueExternal(eventName)
  try:
    runtimeWake()
  except Exception:
    discard

proc pollPathCallbacks(runtime: NestOwlRuntime) =
  if runtime.pendingPathCallbacks.len == 0:
    return
  let callbacks = runtime.pendingPathCallbacks
  runtime.pendingPathCallbacks.setLen(0)
  for callback in callbacks:
    try:
      discard callback.env.call(callback.command, @[stringLiteral(
          callback.path)])
    except EvaluatorError as error:
      runtime.hasError = true
      runtime.lastError = report(error)
      runtime.lastErrorDetails = error.errorDetails()
      return
    except CatchableError as error:
      runtime.hasError = true
      runtime.lastError = error.msg
      return

proc pathPickerCallback(
    env: Environment, arguments: seq[SyntaxNode], commandName: string
): tuple[hasCallback: bool, command: CommandValue] {.raises: [
    EvaluatorError].} =
  if arguments.len > 1:
    raise newException(EvaluatorError, commandName & " expects optional callback")
  if arguments.len == 0:
    return
  let callback = env.eval(arguments[0])
  if callback.kind != Command:
    raise newException(EvaluatorError, commandName & " callback must be a command")
  (true, callback.command)

proc launchPathPicker(
    picker: PathPickerProc, callback: PathSelectedProc, commandName: string
) =
  discard commandName
  picker(callback)

proc processOutput(
    command: string, args: openArray[string], timeoutMs = 750
): string {.raises: [].} =
  var process: Process
  try:
    process =
      startProcess(command, args = @args, options = {poUsePath,
          poStdErrToStdOut})
    let deadline = epochTime() + timeoutMs.float / 1000.0
    while process.running and epochTime() < deadline:
      os.sleep(10)
    if process.running:
      try:
        process.terminate
      except OSError:
        discard
      return ""
    process.outputStream.readAll.strip
  except OSError:
    ""
  except IOError:
    ""
  finally:
    if process != nil:
      try:
        if process.running:
          process.terminate
        process.close
      except OSError:
        discard
      except IOError:
        discard

proc shellOutput(command: string): string {.raises: [].} =
  processOutput("sh", ["-c", command], timeoutMs = 1000)

proc shellSingleQuote(value: string): string {.raises: [].} =
  "'" & value.replace("'", "'\\''") & "'"

proc workspaceField(
    node: JsonNode, name: string, fallback = ""
): string {.raises: [].} =
  try:
    if node.kind == JObject and node.hasKey(name):
      let field = node[name]
      if field.kind == JString:
        return field.getStr
      if field.kind in {JInt, JFloat, JBool}:
        return $field
  except KeyError:
    discard
  fallback

proc workspaceBoolField(node: JsonNode, name: string): bool {.raises: [].} =
  try:
    node.kind == JObject and node.hasKey(name) and node[name].kind == JBool and
      node[name].getBool
  except KeyError:
    false

proc workspaceNumField(node: JsonNode, name: string): float64 {.raises: [].} =
  try:
    if node.kind == JObject and node.hasKey(name):
      let field = node[name]
      if field.kind == JInt:
        return field.getInt.float64
      if field.kind == JFloat:
        return field.getFloat
  except KeyError:
    discard
  0

proc parseSwayWorkspaceValues(output: string): Value {.raises: [].} =
  var items: seq[Value]
  try:
    let root = parseJson(output)
    if root.kind != JArray:
      return list(items)
    for node in root.items:
      if node.kind != JObject:
        continue
      var entry = initTable[string, Value]()
      entry["name"] = text(workspaceField(node, "name"))
      entry["num"] = number(workspaceNumField(node, "num"))
      entry["focused"] = boolean(workspaceBoolField(node, "focused"))
      entry["visible"] = boolean(workspaceBoolField(node, "visible"))
      entry["urgent"] = boolean(workspaceBoolField(node, "urgent"))
      items.add dictionary(entry)
  except JsonParsingError:
    discard
  except ValueError:
    discard
  except IOError:
    discard
  except OSError:
    discard
  list(items)

proc tsvCellValue(content: string; row, col: int): string {.raises: [].} =
  if row < 0 or col < 0:
    return ""
  let lines = content.splitLines
  if row >= lines.len:
    return ""
  let cells = lines[row].split('\t')
  if col >= cells.len:
    return ""
  cells[col]

proc textFindValue(
    haystack, needle: string, start = 0, ignoreCase = false
): int {.raises: [].} =
  if needle.len == 0:
    return -1
  let
    source = if ignoreCase: haystack.toLowerAscii else: haystack
    wanted = if ignoreCase: needle.toLowerAscii else: needle
  source.find(wanted, max(start, 0))

proc lineTextAtValue(content: string, line: int): string {.raises: [].} =
  let lines = content.splitLines
  if line < 1 or line > lines.len:
    ""
  else:
    lines[line - 1]

proc lineCountValue(content: string): int {.raises: [].} =
  if content.len == 0:
    1
  else:
    content.count('\n') + 1

proc wakeRuntimeUi() {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    runtimeWake()

proc stopRequested(subscription: WorkspaceSubscription): bool {.raises: [].} =
  withLock subscription.lock:
    result = subscription.stopping

proc setWorkspaceProcess(
    subscription: WorkspaceSubscription, process: Process
) {.raises: [].} =
  withLock subscription.lock:
    subscription.process = process

proc clearWorkspaceProcess(
    subscription: WorkspaceSubscription, process: Process
) {.raises: [].} =
  withLock subscription.lock:
    if subscription.process == process:
      subscription.process = nil

proc publishWorkspaceOutput(
    subscription: WorkspaceSubscription, output: string
) {.raises: [].} =
  var changed = false
  withLock subscription.lock:
    if subscription.output != output:
      subscription.output = output
      inc subscription.generation
      changed = true
  if changed:
    wakeRuntimeUi()

proc currentWorkspaceOutput(
    subscription: WorkspaceSubscription
): string {.raises: [].} =
  withLock subscription.lock:
    result = subscription.output

proc focusedTreeTitle(node: JsonNode): string {.raises: [].} =
  try:
    if node.kind != JObject:
      return ""
    if node.hasKey("focused") and node["focused"].kind == JBool and
        node["focused"].getBool:
      if node.hasKey("name") and node["name"].kind == JString:
        return node["name"].getStr
      return ""
    for field in ["nodes", "floating_nodes"]:
      if node.hasKey(field) and node[field].kind == JArray:
        for child in node[field].items:
          let title = focusedTreeTitle(child)
          if title.len > 0:
            return title
  except KeyError:
    discard
  ""

proc querySwayJson(kind: string): string {.raises: [].} =
  let output = processOutput("swaymsg", ["-t", kind, "-r"])
  if kind != "get_tree":
    return output
  try:
    focusedTreeTitle(parseJson(output))
  except JsonParsingError:
    ""
  except ValueError:
    ""
  except IOError:
    ""
  except OSError:
    ""

proc runWorkspaceSubscription(subscription: WorkspaceSubscription) {.thread.} =
  while not subscription.stopRequested:
    subscription.publishWorkspaceOutput(querySwayJson(subscription.query))
    if subscription.stopRequested:
      break

    var process: Process
    try:
      process = startProcess(
        "swaymsg",
        args = @["-t", "subscribe", "-m", "[\"" & subscription.event & "\"]"],
        options = {poUsePath, poStdErrToStdOut},
      )
      subscription.setWorkspaceProcess(process)
      let stream = process.outputStream
      while not subscription.stopRequested:
        let line =
          try:
            stream.readLine()
          except IOError:
            break
        if line.len == 0 and not process.running:
          break
        subscription.publishWorkspaceOutput(querySwayJson(subscription.query))
    except OSError:
      discard
    except IOError:
      discard
    finally:
      if process != nil:
        subscription.clearWorkspaceProcess(process)
        try:
          if process.running:
            process.terminate
          process.close
        except OSError:
          discard
        except IOError:
          discard

    if not subscription.stopRequested:
      os.sleep(1000)

proc startWorkspaceSubscription(
    event, query: string
): WorkspaceSubscription {.raises: [].} =
  try:
    result =
      WorkspaceSubscription(event: event, query: query, output: querySwayJson(query))
    initLock(result.lock)
    createThread(result.thread, runWorkspaceSubscription, result)
  except CatchableError:
    result = nil

proc stopWorkspaceSubscription(subscription: WorkspaceSubscription) {.raises: [].} =
  var process: Process
  withLock subscription.lock:
    subscription.stopping = true
    process = subscription.process
  if process != nil:
    try:
      if process.running:
        process.terminate
    except OSError:
      discard

  try:
    joinThread(subscription.thread)
  except Exception:
    discard
  deinitLock(subscription.lock)

proc subscribedSwayWorkspaces(
    runtime: NestOwlRuntime, key: string
): Value {.raises: [].} =
  let subscriptionKey = "workspace:" & key
  if subscriptionKey notin runtime.workspaceSubscriptions:
    let subscription = startWorkspaceSubscription("workspace", "get_workspaces")
    if subscription == nil:
      return list(@[])
    runtime.workspaceSubscriptions[subscriptionKey] = subscription
  let subscription = runtime.workspaceSubscriptions.getOrDefault(subscriptionKey)
  if subscription == nil:
    return list(@[])
  parseSwayWorkspaceValues(subscription.currentWorkspaceOutput())

proc subscribedSwayActiveWindow(
    runtime: NestOwlRuntime, key: string
): string {.raises: [].} =
  let subscriptionKey = "window:" & key
  if subscriptionKey notin runtime.workspaceSubscriptions:
    let subscription = startWorkspaceSubscription("window", "get_tree")
    if subscription == nil:
      return ""
    runtime.workspaceSubscriptions[subscriptionKey] = subscription
  let subscription = runtime.workspaceSubscriptions.getOrDefault(subscriptionKey)
  if subscription == nil:
    return ""
  subscription.currentWorkspaceOutput()

proc currentTicks(): int {.raises: [].} =
  try:
    input.getTicks()
  except Exception:
    0

proc pollShellProcesses*(runtime: NestOwlRuntime, ui: var UI) =
  ## Collect the output of finished shell commands.
  ##
  ## Each command's output is cached for the owl program to read, and the
  ## frame is marked dirty when the output changed, so a `shell` value
  ## refreshes on screen.
  var finished: seq[string]
  for key, shell in runtime.shellProcesses.pairs:
    if not shell.process.running:
      let output =
        try:
          shell.process.outputStream.readAll.strip
        except IOError:
          ""
        except OSError:
          ""
      if runtime.shellCache.getOrDefault(key).output != output:
        ui.markAllDirty()
      runtime.shellCache[key] = ShellCache(output: output, ticks: currentTicks())
      try:
        shell.process.close
      except OSError:
        discard
      except IOError:
        discard
      finished.add key
  for key in finished:
    runtime.shellProcesses.del key

proc closeShellProcesses*(runtime: NestOwlRuntime) =
  ## Terminate every running shell command and forget them all.
  for shell in runtime.shellProcesses.values:
    if shell.process.running:
      shell.process.terminate
    shell.process.close
  runtime.shellProcesses.clear()

proc launchShellCommand(command: string): bool {.raises: [].} =
  try:
    let process = startProcess(
      "sh", args = @["-c", command], options = {poUsePath, poDaemon, poParentStreams}
    )
    process.close
    true
  except OSError:
    false
  except IOError:
    false

proc closeWorkspaceSubscriptions*(runtime: NestOwlRuntime) =
  ## Stop every workspace subscription and forget them all.
  for subscription in runtime.workspaceSubscriptions.values:
    subscription.stopWorkspaceSubscription()
  runtime.workspaceSubscriptions.clear()

proc asyncShellOutput(
    runtime: NestOwlRuntime, key, command: string, intervalMs: int
): string {.raises: [].} =
  let runningShell = runtime.shellProcesses.getOrDefault(key)
  if intervalMs <= 0 and runningShell != nil and runningShell.command != command:
    let shell = runningShell
    try:
      if shell.process.running:
        shell.process.terminate
      shell.process.close
    except OSError:
      discard
    except IOError:
      discard
    runtime.shellProcesses.del key

  let
    nowTicks = currentTicks()
    cache = runtime.shellCache.getOrDefault(key)
    stale =
      key notin runtime.shellCache or intervalMs <= 0 or
      nowTicks - cache.ticks >= intervalMs

  if key notin runtime.shellProcesses and stale:
    try:
      runtime.shellProcesses[key] = ShellProcess(
        process: startProcess(
          "sh", args = @["-c", command], options = {poUsePath, poStdErrToStdOut}
        ),
        command: command,
      )
    except OSError:
      discard
    except IOError:
      discard

  if key in runtime.shellProcesses:
    try:
      runtime.requestRedrawAfter(50)
    except Exception:
      discard

  runtime.shellCache.getOrDefault(key).output

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
    "January", "February", "March", "April", "May", "June", "July", "August",
    "September", "October", "November", "December",
  ]
  if month >= 1 and month <= 12:
    names[month - 1]
  else:
    ""

proc addMonths(value: string, delta: int): string =
  let parsed = parseDateText(value)
  if not parsed.ok:
    return value
  let index = parsed.year * 12 + parsed.month - 1 + delta
  let year = index div 12
  let month = index mod 12 + 1
  let day = min(parsed.day, daysInMonth(year, month))
  dateText(year, month, day)

proc dialogResultPath(key: string): string =
  var safeKey: string
  for ch in key:
    if ch.isAlphaNumeric:
      safeKey.add ch
    else:
      safeKey.add '-'
  let ticks = $currentTicks()
  getTempDir() / ("nest-dialog-" & $getCurrentProcessId() & "-" & ticks & "-" & safeKey)

proc dialogAnchorJson(runtime: NestOwlRuntime, anchorID: WidgetID): string =
  if runtime.currentUi.isNil or anchorID == InvalidWidgetID:
    return ""
  let
    ui = runtime.currentUi[]
    located = ui.widgetFrame(anchorID)
  if not located.ok:
    return ""
  $(
    %*{
      "x": located.frame.x,
      "y": located.frame.y,
      "width": located.frame.width,
      "height": located.frame.height,
      "windowWidth": ui.windowWidth,
      "windowHeight": ui.windowHeight,
    }
  )

proc dialogLaunchOptions(value: Value): DialogLaunchOptions {.raises: [
    EvaluatorError].} =
  case value.kind
  of Boolean:
    result.dismissOnInactive = value.boolean
    result.inactiveGraceMs = 350
    result.hasValues = true
  of Dictionary:
    result.inactiveGraceMs = 350
    result.hasValues = true
    if value.entries.hasKey("dismissOnInactive"):
      result.dismissOnInactive = value.entries.getOrDefault(
          "dismissOnInactive").isTruthy
    elif value.entries.hasKey("autoDismiss"):
      result.dismissOnInactive = value.entries.getOrDefault(
          "autoDismiss").isTruthy
    elif value.entries.hasKey("dismissWhenInactive"):
      result.dismissOnInactive = value.entries.getOrDefault(
          "dismissWhenInactive").isTruthy
    if value.entries.hasKey("inactiveGraceMs"):
      result.inactiveGraceMs = max(
        value.entries.getOrDefault("inactiveGraceMs").asNumber.int, 0
      )
    elif value.entries.hasKey("graceMs"):
      result.inactiveGraceMs = max(value.entries.getOrDefault(
          "graceMs").asNumber.int, 0)
    elif value.entries.hasKey("dismissGraceMs"):
      result.inactiveGraceMs = max(
        value.entries.getOrDefault("dismissGraceMs").asNumber.int, 0
      )
  else:
    raise newException(
      EvaluatorError,
      "dialog options expects a boolean or dictionary",
    )

proc dialogLaunchOptionsJson(options: DialogLaunchOptions): string =
  if not options.hasValues:
    return ""
  $(
    %*{
      "dismissOnInactive": options.dismissOnInactive,
      "inactiveGraceMs": options.inactiveGraceMs,
    }
  )

proc requestDialogClose*(runtime: NestOwlRuntime, value = "") =
  ## Ask a dialog process to close after its UI has had a chance to animate out.
  runtime.dialogCloseValue = value
  runtime.dialogCloseRequested = true
  try:
    if not runtime.currentUi.isNil:
      runtime.currentUi[].markAllDirty()
      runtime.currentUi[].requestRedrawAfter(0)
  except Exception:
    discard

proc launchDialogProcess(
    runtime: NestOwlRuntime, key, projectDir, data: string,
        anchorID = InvalidWidgetID, options = DialogLaunchOptions()
) {.raises: [EvaluatorError].} =
  if key in runtime.dialogProcesses:
    return
  let resolvedProjectDir =
    try:
      runtime.resolveModulePath(projectDir)
    except OSError as error:
      raise newException(EvaluatorError, projectDir & ": " & error.msg)
  if not dirExists(resolvedProjectDir):
    raise newException(
      EvaluatorError, "dialog project directory does not exist: " & resolvedProjectDir
    )
  let resultPath = dialogResultPath(key)
  let anchor = runtime.dialogAnchorJson(anchorID)
  let optionsJson = dialogLaunchOptionsJson(options)
  var args = @["dialog", resolvedProjectDir, data, resultPath]
  if optionsJson.len > 0:
    args.add anchor
    args.add optionsJson
  elif anchor.len > 0:
    args.add anchor
  let process =
    try:
      startProcess(
        getAppFilename(), args = args, options = {poUsePath, poParentStreams}
      )
    except OSError as error:
      raise newException(EvaluatorError, "could not start dialog process: " & error.msg)
    except IOError as error:
      raise newException(EvaluatorError, "could not start dialog process: " & error.msg)
  runtime.dialogProcesses[key] = DialogProcess(process: process,
      resultPath: resultPath)

proc pollDialogProcesses*(runtime: NestOwlRuntime) =
  ## Reap dialog processes that have exited, recording each one's result for
  ## the owl program to read.
  var finished: seq[string]
  for key, dialog in runtime.dialogProcesses.pairs:
    if not dialog.process.running:
      let output =
        try:
          if fileExists(dialog.resultPath):
            readFile(dialog.resultPath).strip
          else:
            ""
        except OSError:
          ""
        except IOError:
          ""
      runtime.dialogResults[key] = output
      try:
        if fileExists(dialog.resultPath):
          removeFile(dialog.resultPath)
      except OSError:
        discard
      dialog.process.close
      finished.add key
  for key in finished:
    runtime.dialogProcesses.del key

proc closeManagedDialog*(runtime: NestOwlRuntime, key: string) =
  ## Ask the managed dialog stored under `key` to close. Unknown keys are ignored.
  if key notin runtime.dialogProcesses:
    return
  let dialog = runtime.dialogProcesses[key]
  if dialog.process.running:
    dialog.process.terminate
    return
  try:
    if fileExists(dialog.resultPath):
      removeFile(dialog.resultPath)
  except OSError:
    discard
  except IOError:
    discard
  dialog.process.close
  runtime.dialogProcesses.del key

proc closeDialogProcesses*(runtime: NestOwlRuntime) =
  ## Terminate every running dialog process and forget them all.
  for dialog in runtime.dialogProcesses.values:
    if dialog.process.running:
      dialog.process.terminate
      try:
        if fileExists(dialog.resultPath):
          removeFile(dialog.resultPath)
      except OSError:
        discard
    dialog.process.close
  runtime.dialogProcesses.clear()
  runtime.closeShellProcesses()
  runtime.closeWorkspaceSubscriptions()

proc owlErrorLines*(message: string, maxLineLen = 68, maxLines = 7): seq[string] =
  ## Split `message` into at most `maxLines` display lines of at most
  ## `maxLineLen` characters, for the error dialog.
  ##
  ## Longer lines are wrapped and anything past the line budget is dropped.
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

proc diagnosticLocation*(
    line: string
): tuple[ok: bool, path: string, line: int, column: int] =
  ## Parse a `path:line:column` reference out of a diagnostic line.
  ##
  ## A leading `at ` is ignored, and `ok` is false when the line carries no
  ## location. A missing column defaults to one.
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
  ## Open the source location named in a diagnostic line in the user's
  ## editor, through `emacsclient`.
  ##
  ## Does nothing when the line carries no location or the editor cannot be
  ## started.
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

proc renderOwlErrorLine*(
    ui: var UI, index: int, line: string, width, height: SizePolicy
) =
  ## Lay out one line of an error report as row `index`, colouring the
  ## message and underline lines and making a line that names a source
  ## location clickable.
  let
    location = diagnosticLocation(line)
    fg =
      if isErrorHighlightLine(line):
        color(255, 92, 92)
      elif location.ok:
        color(255, 150, 150)
      else:
        ui.palette.textColor
  if ui.diagnosticLabel(
    ui.id("_nest_error_line", $index), line, fg, width, height,
        clickable = location.ok
  ):
    openDiagnosticLocation(line)

proc renderErrorDialog*(runtime: NestOwlRuntime, ui: var UI, message: string) =
  ## Lay out the in-window error dialog for `message`.
  ##
  ## Does nothing for an empty message or one the user has already dismissed.
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
      cfg(
        width = fixed(560),
        height = fit(),
        padding = 12,
        gap = 10,
        alignItems = AlignStretch,
      ),
    ):
      ui.dialogHeader(
        ui.id("_nest_error_header"),
        cfg(
          width = fill(), height = fit(), padding = 8, gap = 8,
              alignItems = AlignCenter
        ),
      ):
        ui.label(ui.id("_nest_error_title"), "Owl error", fill(), fit())
        discard ui.button(closeID, "Close", fit(), fit())
      ui.column(
        ui.id("_nest_error_body"),
        cfg(
          width = fill(),
          height = fit(),
          padding = 8,
          gap = 4,
          alignItems = AlignStretch,
        ),
      ):
        for index, line in owlErrorLines(message):
          renderOwlErrorLine(ui, index, line, fill(), fit())
      ui.row(
        ui.id("_nest_error_actions"),
        cfg(width = fill(), height = fit(), gap = 8,
            justifyContent = JustifyEnd),
      ):
        discard ui.button(copyID, "Copy", fit(), fit())

proc loadSyntaxFile*(
    runtime: NestOwlRuntime, path: string
): SyntaxNode {.raises: [EvaluatorError].} =
  ## Read and parse the owl source file at `path` and return its syntax tree.
  ##
  ## `path` is resolved as a module path, and the file is registered as a
  ## dependency so a change to it triggers a reload. Raises
  ## `EvaluatorError` when the file cannot be read or parsed.
  var resolved = path
  try:
    resolved = runtime.resolveModulePath(path)
    result = owl.parse(readFile(resolved), resolved)
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

proc importModule(
    runtime: NestOwlRuntime, env: Environment, path: string, pos = noSourcePos()
) {.raises: [EvaluatorError].} =
  let resolved =
    try:
      if not path.isAbsolute and runtime.moduleStack.len == 0 and pos.hasSource:
        (pos.sourcePath.parentDir / path).normalizedPath
      else:
        runtime.resolveModulePath(path)
    except OSError as error:
      raise newException(EvaluatorError, path & ": " & error.msg)
  if resolved in runtime.loadedModules:
    return
  let node = runtime.loadSyntaxFile(resolved)
  runtime.moduleStack.add resolved
  try:
    try:
      discard runtime.renderNodes(env, node.statements)
    except EvaluatorError as error:
      raise error
    except Exception as error:
      raise newException(EvaluatorError, error.msg)
    runtime.loadedModules.incl resolved
  finally:
    runtime.moduleStack.setLen(runtime.moduleStack.len - 1)

proc renderNodes(
    runtime: NestOwlRuntime, env: Environment, nodes: seq[SyntaxNode]
): Value =
  result = nothing()
  for node in nodes:
    if runtime.hasError:
      return
    try:
      result = env.eval(node)
    except EvaluatorError as error:
      runtime.hasError = true
      runtime.lastError = report(error)
      runtime.lastErrorDetails = error.errorDetails()
      return nothing()

proc renderNodes(runtime: NestOwlRuntime, nodes: seq[SyntaxNode]): Value =
  runtime.renderNodes(runtime.evaluator.env, nodes)

proc refreshPerfOverlay(runtime: NestOwlRuntime) {.raises: [].} =
  if not runtime.currentUi.isNil:
    runtime.currentUi[].markAllDirty()
    try:
      runtime.currentUi[].requestRedrawAfter(0)
    except Exception:
      discard

proc registerNestCommands(runtime: NestOwlRuntime) =
  let widgetCommand = runtime.evaluator.env.get("component")
  runtime.evaluator.env.define("widget", widgetCommand)
  if runtime.evaluator.env.fallback != nil:
    runtime.evaluator.env.fallback.define("widget", widgetCommand)

  runtime.evaluator.native "import":
    discard layout
    discard bodyNodes
    if arguments.len != 1:
      raise newException(EvaluatorError, "import expects one path")
    runtime.importModule(env, env.eval(arguments[0]).asString, arguments[0].pos)
    nothing()

  runtime.evaluator.native "id":
    discard layout
    discard bodyNodes
    if arguments.len == 0:
      return widgetValue(runtime.requireUi().nextAutoID())
    var parts: seq[string]
    for value in env.evalArgs(arguments):
      parts.add value.asString
    widgetValue(runtime.requireUi().id(parts), parts.join(":"))

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

  runtime.evaluator.native "middleClicked":
    discard layout
    discard bodyNodes
    if arguments.len != 1:
      raise newException(EvaluatorError, "middleClicked expects one widget ID")
    let clicked = runtime.requireUi().inEventPhase() and
      runtime.requireUi().middleClicked(runtime.asWidgetID(env.eval(arguments[0])))
    if clicked:
      runtime.requireUi().markAllDirty()
    boolean(clicked)

  runtime.evaluator.native "focused":
    discard layout
    discard bodyNodes
    if arguments.len != 1:
      raise newException(EvaluatorError, "focused expects one widget ID")
    boolean(runtime.requireUi().focused(runtime.asWidgetID(env.eval(arguments[0]))))

  runtime.evaluator.native "submitted":
    discard layout
    discard bodyNodes
    if arguments.len == 0:
      return boolean(false)
    let submitted =
      runtime.requireUi().inEventPhase() and
      runtime.requireUi().submitted(runtime.asWidgetID(env.eval(arguments[0])))
    if submitted:
      runtime.requireUi().markAllDirty()
    boolean(submitted)

  runtime.evaluator.native "tooltip":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 2:
      raise newException(EvaluatorError, "tooltip expects widget id and text")
    runtime.requireUi().tooltip(runtime.asWidgetID(values[0]), values[1].asString)
    nothing()

  runtime.evaluator.native "keyPressed":
    discard layout
    discard bodyNodes
    if arguments.len != 1:
      raise newException(EvaluatorError, "keyPressed expects one key name")
    let pressed = runtime.requireUi().keyPressed(env.eval(arguments[0]).asString)
    if pressed:
      runtime.requireUi().markAllDirty()
    boolean(pressed)

  runtime.evaluator.native "external":
    discard layout
    discard bodyNodes
    if arguments.len != 1:
      raise newException(EvaluatorError, "external expects one event name")
    let matched =
      runtime.requireUi().inEventPhase() and
      runtime.consumeExternal(env.eval(arguments[0]).asString)
    if matched:
      runtime.requireUi().markAllDirty()
    boolean(matched)

  runtime.evaluator.native "state":
    discard layout
    if arguments.len != 1:
      raise newException(EvaluatorError, "state expects one widget key")
    if bodyNodes.len == 0:
      raise newException(EvaluatorError, "state expects field bindings")
    let scope = env.eval(arguments[0]).asString
    for binding in bodyNodes:
      if binding.kind != Binding:
        raise newException(EvaluatorError, "state entries must be bindings")
      let key = stateKey(scope, binding.bindingSymbol)
      let value =
        if key in runtime.widgetState:
          runtime.widgetState[key]
        else:
          env.eval(binding.value)
      if key notin runtime.widgetState:
        runtime.widgetState[key] = value
      if env.bindings.hasKey(binding.bindingSymbol):
        env.bindings[binding.bindingSymbol] = value
      else:
        env.define(binding.bindingSymbol, value)
      runtime.stateBindings.add StateBinding(env: env,
          symbol: binding.bindingSymbol, key: key)
    nothing()

  runtime.evaluator.native "send":
    discard layout
    discard bodyNodes
    if arguments.len != 2:
      raise newException(EvaluatorError, "send expects a topic and payload")
    let topic = env.eval(arguments[0]).asString
    let payload = env.eval(arguments[1])
    runtime.messages.mgetOrPut(topic, @[]).add(payload)
    runtime.refreshPerfOverlay()
    payload

  runtime.evaluator.native "received":
    discard layout
    discard bodyNodes
    if arguments.len != 1:
      raise newException(EvaluatorError, "received expects a topic")
    let topic = env.eval(arguments[0]).asString
    boolean(runtime.messages.getOrDefault(topic).len > 0)

  runtime.evaluator.native "receive":
    discard layout
    discard bodyNodes
    if arguments.len != 1:
      raise newException(EvaluatorError, "receive expects a topic")
    runtime.receiveMessage(env.eval(arguments[0]).asString)

  runtime.evaluator.native "perfOverlay":
    discard env
    discard arguments
    discard layout
    discard bodyNodes
    boolean(perfOverlayEnabled())

  runtime.evaluator.native "togglePerfOverlay":
    discard env
    discard arguments
    discard layout
    discard bodyNodes
    let enabled = togglePerfOverlay()
    runtime.refreshPerfOverlay()
    boolean(enabled)

  runtime.evaluator.native "setPerfOverlay":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "setPerfOverlay expects one boolean")
    setPerfOverlay(values[0].isTruthy)
    runtime.refreshPerfOverlay()
    boolean(perfOverlayEnabled())

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

  runtime.evaluator.native "insets":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    case values.len
    of 0:
      insetsValue(insets(0.0))
    of 1:
      insetsValue(insets(values[0].asNumber))
    of 2:
      let
        vertical = values[0].asNumber
        horizontal = values[1].asNumber
      insetsValue(insets(horizontal, vertical, horizontal, vertical))
    of 3:
      let
        top = values[0].asNumber
        horizontal = values[1].asNumber
        bottom = values[2].asNumber
      insetsValue(insets(horizontal, top, horizontal, bottom))
    else:
      insetsValue(
        insets(
          values[0].asNumber,
          values[1].asNumber,
          values[2].asNumber,
          values[3].asNumber,
        )
      )

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

  runtime.evaluator.native "redrawAfter":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "redrawAfter expects milliseconds")
    runtime.requestRedrawAfter(values[0].asNumber.int)
    nothing()

  runtime.evaluator.native "animation":
    discard layout
    let values = env.evalArgs(arguments)
    if values.len < 1 or values.len > 2:
      raise newException(EvaluatorError, "animation expects id and optional open")
    let
      id = runtime.asWidgetID(values[0])
      open =
        if values.len == 2:
          values[1].isTruthy
        else:
          true
      spec = env.evalAnimationSpec(bodyNodes)
    if runtime.requireUi().inLayoutPhase():
      discard runtime.requireUi().animate(id, open, spec)
    runtime.renderNodes(env, childNodes(bodyNodes))

  runtime.evaluator.native "pickFile":
    discard layout
    discard bodyNodes
    let callback = pathPickerCallback(env, arguments, "pickFile")
    if callback.hasCallback:
      launchPathPicker(
        pickFileDialog,
        proc(path: string) =
        runtime.queuePathCallback(env, callback.command, path),
        "pickFile",
      )
    else:
      launchPathPicker(pickFileDialog, nil, "pickFile")
    boolean(true)

  runtime.evaluator.native "pickDirectory":
    discard layout
    discard bodyNodes
    let callback = pathPickerCallback(env, arguments, "pickDirectory")
    if callback.hasCallback:
      launchPathPicker(
        pickDirectoryDialog,
        proc(path: string) =
        runtime.queuePathCallback(env, callback.command, path),
        "pickDirectory",
      )
    else:
      launchPathPicker(pickDirectoryDialog, nil, "pickDirectory")
    boolean(true)

  runtime.evaluator.native "pickFileEvent":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "pickFileEvent expects event name")
    let eventName = values[0].asString
    launchPathPicker(
      pickFileDialog,
      proc(path: string) =
      runtime.queuePathEvent(eventName, path),
      "pickFileEvent",
    )
    boolean(true)

  runtime.evaluator.native "pickDirectoryEvent":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "pickDirectoryEvent expects event name")
    let eventName = values[0].asString
    launchPathPicker(
      pickDirectoryDialog,
      proc(path: string) =
      runtime.queuePathEvent(eventName, path),
      "pickDirectoryEvent",
    )
    boolean(true)

  runtime.evaluator.native "pickResult":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "pickResult expects event name")
    let eventName = values[0].asString
    if eventName in runtime.pathPickerResults:
      text(runtime.pathPickerResults[eventName])
    else:
      nothing()

  runtime.evaluator.native "clearPickResult":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "clearPickResult expects event name")
    runtime.pathPickerResults.del values[0].asString
    nothing()

  runtime.evaluator.native "shell":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "shell expects one command")
    text(shellOutput(values[0].asString))

  runtime.evaluator.native "shellQuote":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "shellQuote expects one value")
    text(shellSingleQuote(values[0].asString))

  runtime.evaluator.native "copyText":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "copyText expects one value")
    try:
      putClipboardText(values[0].asString)
      boolean(true)
    except Exception:
      boolean(false)

  runtime.evaluator.native "clipboardText":
    discard env
    discard arguments
    discard layout
    discard bodyNodes
    try:
      text(getClipboardText())
    except Exception:
      text("")

  runtime.evaluator.native "windowWidth":
    discard env
    discard arguments
    discard layout
    discard bodyNodes
    number(runtime.requireUi().windowWidth.float64)

  runtime.evaluator.native "windowHeight":
    discard env
    discard arguments
    discard layout
    discard bodyNodes
    number(runtime.requireUi().windowHeight.float64)

  runtime.evaluator.native "scrollY":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "scrollY expects widget id")
    number(runtime.requireUi().scrollOffset(runtime.asWidgetID(values[0])).y)

  runtime.evaluator.native "widgetHeight":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "widgetHeight expects widget id")
    let frame = runtime.requireUi().widgetFrame(runtime.asWidgetID(values[0]))
    number(if frame.ok: frame.frame.height else: 0.0)

  runtime.evaluator.native "shellAsync":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len < 2 or values.len > 3:
      raise newException(
        EvaluatorError,
        "shellAsync expects key, command, and optional interval milliseconds",
      )
    let intervalMs =
      if values.len == 3:
        values[2].asNumber.int
      else:
        0
    text(runtime.asyncShellOutput(values[0].asString, values[1].asString, intervalMs))

  runtime.evaluator.native "shellLaunch":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "shellLaunch expects one command")
    boolean(launchShellCommand(values[0].asString))

  runtime.evaluator.native "tsvCell":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 3:
      raise newException(EvaluatorError, "tsvCell expects text, row, and column")
    text(tsvCellValue(values[0].asString, values[1].asNumber.int, values[
        2].asNumber.int))

  runtime.evaluator.native "swayWorkspaces":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "swayWorkspaces expects swaymsg JSON output")
    parseSwayWorkspaceValues(values[0].asString)

  runtime.evaluator.native "swayWorkspaceSubscription":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "swayWorkspaceSubscription expects one key")
    runtime.subscribedSwayWorkspaces(values[0].asString)

  runtime.evaluator.native "swayActiveWindowSubscription":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "swayActiveWindowSubscription expects one key")
    text(runtime.subscribedSwayActiveWindow(values[0].asString))

  runtime.evaluator.native "swayWorkspaceCommand":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise
        newException(EvaluatorError, "swayWorkspaceCommand expects one workspace name")
    text("swaymsg workspace " & shellSingleQuote(values[0].asString))

  runtime.evaluator.native "string":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    var output: string
    for value in values:
      output.add value.asString
    text(output)

  runtime.evaluator.native "textLines":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "textLines expects one text value")
    var items: seq[Value]
    for line in values[0].asString.splitLines:
      if line.len > 0:
        items.add text(line)
    list(items)

  runtime.evaluator.native "listAppend":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 2:
      raise newException(EvaluatorError, "listAppend expects list and value")
    if values[0].kind != List:
      raise newException(EvaluatorError, "listAppend expects list and value")
    var items = values[0].items
    items.add values[1]
    list(items)

  runtime.evaluator.native "textFind":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len < 2 or values.len > 4:
      raise newException(
        EvaluatorError, "textFind expects text, needle, optional start, and optional ignoreCase"
      )
    number(
      textFindValue(
        values[0].asString,
        values[1].asString,
        if values.len > 2: values[2].asNumber.int else: 0,
        if values.len > 3: values[3].isTruthy else: false,
      ).float64
    )

  runtime.evaluator.native "textSlice":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 3:
      raise newException(EvaluatorError, "textSlice expects text, start, and stop")
    let
      source = values[0].asString
      startIndex = values[1].asNumber.int.clamp(0, source.len)
      stopIndex = values[2].asNumber.int.clamp(startIndex, source.len)
    text(if stopIndex > startIndex: source[startIndex ..< stopIndex] else: "")

  runtime.evaluator.native "lineCount":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "lineCount expects text")
    number(lineCountValue(values[0].asString).float64)

  runtime.evaluator.native "lineTextAt":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 2:
      raise newException(EvaluatorError, "lineTextAt expects text and line")
    text(lineTextAtValue(values[0].asString, values[1].asNumber.int))

  runtime.evaluator.native "pathBaseName":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "pathBaseName expects path")
    text(values[0].asString.extractFilename)

  runtime.evaluator.native "formatNow":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "formatNow expects one time format")
    text(now().format(values[0].asString))

  runtime.evaluator.native "editorText":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "editorText expects editor id")
    let key = env.idKey(arguments[0], values[0].asString)
    if key in runtime.editorStates:
      text(runtime.editorStates[key].text)
    else:
      text("")

  runtime.evaluator.native "editorCursor":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "editorCursor expects editor id")
    let key = env.idKey(arguments[0], values[0].asString)
    if key in runtime.editorStates:
      number(runtime.editorStates[key].cursor.float64)
    else:
      number(0)

  runtime.evaluator.native "setEditorCursor":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 2:
      raise newException(EvaluatorError, "setEditorCursor expects editor id and cursor")
    let key = env.idKey(arguments[0], values[0].asString)
    if key notin runtime.editorStates:
      runtime.editorStates[key] = EditorState.new("")
    runtime.editorStates[key].cursor = values[1].asNumber.int.clamp(
      0, runtime.editorStates[key].text.len
    )
    runtime.editorStates[key].preferredColumn = -1
    nothing()

  runtime.evaluator.native "setEditorText":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 2:
      raise newException(EvaluatorError, "setEditorText expects editor id and text")
    let key = env.idKey(arguments[0], values[0].asString)
    if key notin runtime.editorStates:
      runtime.editorStates[key] = EditorState.new("")
    let replacement = values[1].asString
    runtime.editorStates[key].replaceText(replacement)
    nothing()

  runtime.evaluator.native "clearEditor":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "clearEditor expects editor id")
    let key = env.idKey(arguments[0], values[0].asString)
    if key notin runtime.editorStates:
      runtime.editorStates[key] = EditorState.new("")
    runtime.editorStates[key].replaceText("")
    nothing()

  runtime.evaluator.native "insertEditorText":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 2:
      raise newException(EvaluatorError, "insertEditorText expects editor id and text")
    let key = env.idKey(arguments[0], values[0].asString)
    if key notin runtime.editorStates:
      runtime.editorStates[key] = EditorState.new("")
    runtime.editorStates[key].insertText(values[1].asString)
    nothing()

  runtime.evaluator.native "editorLine":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "editorLine expects editor id")
    let key = env.idKey(arguments[0], values[0].asString)
    if key notin runtime.editorStates:
      runtime.editorStates[key] = EditorState.new("")
    number(runtime.editorStates[key].lineColumn.line.float64)

  runtime.evaluator.native "editorColumn":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "editorColumn expects editor id")
    let key = env.idKey(arguments[0], values[0].asString)
    if key notin runtime.editorStates:
      runtime.editorStates[key] = EditorState.new("")
    number(runtime.editorStates[key].lineColumn.column.float64)

  runtime.evaluator.native "setEditorLineColumn":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 3:
      raise newException(EvaluatorError, "setEditorLineColumn expects editor id, line, and column")
    let key = env.idKey(arguments[0], values[0].asString)
    if key notin runtime.editorStates:
      runtime.editorStates[key] = EditorState.new("")
    let cursor = runtime.editorStates[key].cursorForLineColumn(
      values[1].asNumber.int, values[2].asNumber.int
    )
    runtime.editorStates[key].setCursor(cursor)
    runtime.editorStates[key].ensureCursorVisible = true
    nothing()

  runtime.evaluator.native "setEditorSelection":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 3:
      raise newException(EvaluatorError, "setEditorSelection expects editor id, start, and stop")
    let key = env.idKey(arguments[0], values[0].asString)
    if key notin runtime.editorStates:
      runtime.editorStates[key] = EditorState.new("")
    let
      startIndex = values[1].asNumber.int.clamp(0, runtime.editorStates[key].text.len)
      stopIndex = values[2].asNumber.int.clamp(0, runtime.editorStates[key].text.len)
    runtime.editorStates[key].selectionAnchor = startIndex
    runtime.editorStates[key].cursor = stopIndex
    runtime.editorStates[key].ensureCursorVisible = true
    nothing()

  runtime.evaluator.native "selectEditorAll":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "selectEditorAll expects editor id")
    let key = env.idKey(arguments[0], values[0].asString)
    if key notin runtime.editorStates:
      runtime.editorStates[key] = EditorState.new("")
    runtime.editorStates[key].selectAll()
    nothing()

  runtime.evaluator.native "copyEditorSelection":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "copyEditorSelection expects editor id")
    let key = env.idKey(arguments[0], values[0].asString)
    if key notin runtime.editorStates:
      runtime.editorStates[key] = EditorState.new("")
    text(runtime.editorStates[key].copySelection())

  runtime.evaluator.native "cutEditorSelection":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "cutEditorSelection expects editor id")
    let key = env.idKey(arguments[0], values[0].asString)
    if key notin runtime.editorStates:
      runtime.editorStates[key] = EditorState.new("")
    text(runtime.editorStates[key].cutSelection())

  runtime.evaluator.native "pasteEditorClipboard":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "pasteEditorClipboard expects editor id")
    let key = env.idKey(arguments[0], values[0].asString)
    if key notin runtime.editorStates:
      runtime.editorStates[key] = EditorState.new("")
    runtime.editorStates[key].pasteClipboard()
    nothing()

  runtime.evaluator.native "deleteEditorSelection":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "deleteEditorSelection expects editor id")
    let key = env.idKey(arguments[0], values[0].asString)
    if key notin runtime.editorStates:
      runtime.editorStates[key] = EditorState.new("")
    discard runtime.editorStates[key].deleteSelection()
    nothing()

  runtime.evaluator.native "undoEditor":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "undoEditor expects editor id")
    let key = env.idKey(arguments[0], values[0].asString)
    if key in runtime.editorStates:
      runtime.editorStates[key].undo()
    nothing()

  runtime.evaluator.native "redoEditor":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "redoEditor expects editor id")
    let key = env.idKey(arguments[0], values[0].asString)
    if key in runtime.editorStates:
      runtime.editorStates[key].redo()
    nothing()

  runtime.evaluator.native "date":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 3:
      raise newException(EvaluatorError, "date expects year, month, and day")
    text(
      dateText(values[0].asNumber.int, values[1].asNumber.int, values[
          2].asNumber.int)
    )

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

  runtime.evaluator.native "color":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len < 3 or values.len > 4:
      raise newException(
        EvaluatorError, "color expects red, green, blue, and optional alpha"
      )
    colorValue(
      color(
        values[0].asByte,
        values[1].asByte,
        values[2].asByte,
        if values.len > 3:
          values[3].asByte(255)
        else:
          255'u8,
      )
    )

  runtime.evaluator.native "theme-color":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "theme-color expects a color name")
    colorValue(
      runtime.requireUi().palette.colorByName(
        values[0].asString, runtime.requireUi().palette.primary
      )
    )

  runtime.evaluator.native "mix-color":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 3:
      raise newException(EvaluatorError, "mix-color expects two colors and an amount")
    colorValue(
      mixColor(
        values[0].asColor(color(0, 0, 0)),
        values[1].asColor(color(0, 0, 0)),
        values[2].asNumber,
      )
    )

  runtime.evaluator.native "openDialog":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len < 2 or values.len > 5:
      raise newException(
        EvaluatorError,
        "openDialog expects key, projectDir, optional data, optional anchor, and optional options",
      )
    let key = values[0].asString
    let projectDir = values[1].asString
    let data =
      if values.len > 2:
        values[2].asString
      else:
        ""
    var
      anchorID = runtime.requireUi().id(key)
      options = DialogLaunchOptions()
    if values.len > 3:
      if values[3].kind in {Dictionary, Boolean}:
        options = dialogLaunchOptions(values[3])
      else:
        anchorID = runtime.asWidgetID(values[3])
    if values.len > 4:
      options = dialogLaunchOptions(values[4])
    runtime.launchDialogProcess(key, projectDir, data, anchorID, options)
    boolean(true)

  runtime.evaluator.native "toggleDialog":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len < 2 or values.len > 5:
      raise newException(
        EvaluatorError,
        "toggleDialog expects key, projectDir, optional data, optional anchor, and optional options",
      )
    let key = values[0].asString
    if key in runtime.dialogProcesses:
      runtime.closeManagedDialog(key)
      return boolean(false)
    let projectDir = values[1].asString
    let data =
      if values.len > 2:
        values[2].asString
      else:
        ""
    var
      anchorID = runtime.requireUi().id(key)
      options = DialogLaunchOptions()
    if values.len > 3:
      if values[3].kind in {Dictionary, Boolean}:
        options = dialogLaunchOptions(values[3])
      else:
        anchorID = runtime.asWidgetID(values[3])
    if values.len > 4:
      options = dialogLaunchOptions(values[4])
    runtime.launchDialogProcess(key, projectDir, data, anchorID, options)
    boolean(true)

  runtime.evaluator.native "dialogOpen?":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "dialogOpen? expects key")
    boolean(values[0].asString in runtime.dialogProcesses)

  runtime.evaluator.native "closeManagedDialog":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "closeManagedDialog expects key")
    runtime.closeManagedDialog(values[0].asString)
    nothing()

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

  runtime.evaluator.native "requestCloseDialog":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    runtime.requestDialogClose(
      if values.len > 0:
        values[0].asString
      else:
        ""
    )
    text(runtime.dialogCloseValue)

  runtime.evaluator.native "dialogClosing?":
    discard layout
    discard bodyNodes
    if arguments.len != 0:
      raise newException(EvaluatorError, "dialogClosing? expects no arguments")
    boolean(runtime.dialogCloseRequested)

  runtime.evaluator.native "events":
    discard arguments
    discard layout
    if runtime.requireUi().inEventPhase():
      result = runtime.renderNodes(env, bodyNodes)
      runtime.commitState()
    else:
      result = nothing()

  runtime.evaluator.native "scope":
    discard layout
    if arguments.len == 0:
      return runtime.renderNodes(env, bodyNodes)
    let key = env.eval(arguments[0]).asString
    runtime.currentUi[].scope(key):
      result = runtime.renderNodes(env, bodyNodes)

  runtime.evaluator.native "menuBar":
    discard layout
    let values = env.evalArgs(arguments)
    let
      id =
        if values.len > 0:
          runtime.asWidgetID(values[0])
        else:
          nextWidgetID()
      key =
        if arguments.len > 0:
          env.idKey(arguments[0], values[0].asString)
        else:
          $id
      config = env.evalConfig(bodyNodes)
      menus = env.collectMenus(bodyNodes.childNodes)
      dialogKey = menuKey(key)
    runtime.currentUi[].menuBar(id, config):
      for menu in menus:
        let menuID = runtime.requireUi().id(key, menu.path)
        let menuWidth = fixed(max(64, menu.label.len * 10 + 24).float64)
        if runtime.requireUi().menu(menuID, menu.label, menuWidth, fill()):
          if runtime.openMenus.getOrDefault(key) == menu.path:
            runtime.openMenus.del key
          else:
            runtime.openMenus[key] = menu.path
    let openPath = runtime.openMenus.getOrDefault(key)
    if openPath.len > 0:
      for menu in menus:
        if menu.path != openPath:
          continue
        let entries = env.collectMenuEntries(menu.path, menu.body)
        if runtime.requireUi().inEventPhase():
          for index, entry in entries:
            if entry.kind == MenuEntryItem and
                runtime.requireUi().clicked(runtime.requireUi().id(key, "item", $index)):
              runtime.dialogResults[dialogKey] = entry.path
              runtime.openMenus.del key
              runtime.requireUi().markAllDirty()
        else:
          runtime.currentUi[].floatingCardBelow(
            runtime.requireUi().id(key, "popover", menu.path),
            runtime.requireUi().id(key, menu.path),
            cfg(
              width = fixed(260),
              height = fit(),
              padding = 6,
              gap = 0,
              alignItems = AlignStretch,
            )
              .withBackground(color(0, 0, 0))
              .withOpacity(0.9),
          ):
            runtime.currentUi[].column(
              runtime.requireUi().id(key, "items", menu.path),
              cfg(width = fill(), height = fit(), gap = 0,
                  alignItems = AlignStretch),
            ):
              for index, entry in entries:
                case entry.kind
                of MenuEntryDivider:
                  runtime.currentUi[].menuDivider(
                    runtime.requireUi().id(key, "divider", $index), fill(),
                        fixed(9)
                  )
                of MenuEntryItem:
                  runtime.currentUi[].menuItem(
                    runtime.requireUi().id(key, "item", $index),
                    cfg(
                      width = fill(),
                      height = fit(),
                      padding = 4,
                      alignItems = AlignCenter,
                    ),
                  ):
                    if entry.body.len == 0:
                      runtime.currentUi[].label(
                        runtime.requireUi().id(key, "label", $index),
                        entry.label,
                        fill(),
                        fit(),
                      )
                    else:
                      discard runtime.renderNodes(env, entry.body)
    nothing()

  runtime.evaluator.native "menu":
    discard env
    discard arguments
    discard layout
    discard bodyNodes
    nothing()

  runtime.evaluator.native "menuItem":
    discard layout
    let values = env.evalArgs(arguments)
    let
      id = runtime.widgetID(values)
      config = env.evalConfig(bodyNodes, uiDriverRelays.containerConfig())
    runtime.currentUi[].menuItem(id, config):
      discard runtime.renderNodes(env, bodyNodes.childNodes)
    boolean(runtime.requireUi().inEventPhase() and runtime.requireUi().clicked(id))

  runtime.evaluator.native "menuDivider":
    discard layout
    let values = env.evalArgs(arguments)
    let
      id = runtime.widgetID(values)
      config = env.evalConfig(bodyNodes, uiDriverRelays.menuDividerConfig())
    runtime.currentUi[].menuDivider(id, config.width, config.height,
        config.alignSelf)
    nothing()

  runtime.evaluator.native "menuResult":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "menuResult expects key")
    let key = menuKey(values[0].asString)
    if key in runtime.dialogResults:
      text(runtime.dialogResults[key])
    else:
      nothing()

  runtime.evaluator.native "clearMenuResult":
    discard layout
    discard bodyNodes
    let values = env.evalArgs(arguments)
    if values.len != 1:
      raise newException(EvaluatorError, "clearMenuResult expects key")
    runtime.dialogResults.del menuKey(values[0].asString)
    nothing()

  runtime.evaluator.native "panel":
    discard layout
    let values = env.evalArgs(arguments)
    let
      id = runtime.widgetID(values)
      config = env.evalConfig(bodyNodes, uiDriverRelays.containerConfig())
    runtime.currentUi[].panel(id, config):
      discard runtime.renderNodes(env, bodyNodes.childNodes)
    nothing()

  runtime.evaluator.native "card":
    discard layout
    let values = env.evalArgs(arguments)
    let
      id = runtime.widgetID(values)
      config = env.evalConfig(bodyNodes, uiDriverRelays.containerConfig())
    runtime.currentUi[].card(id, config):
      discard runtime.renderNodes(env, bodyNodes.childNodes)
    nothing()

  runtime.evaluator.native "dialogHeader":
    discard layout
    let values = env.evalArgs(arguments)
    let
      id = runtime.widgetID(values)
      config = env.evalConfig(bodyNodes, uiDriverRelays.containerConfig())
    runtime.currentUi[].dialogHeader(id, config):
      discard runtime.renderNodes(env, bodyNodes.childNodes)
    nothing()

  runtime.evaluator.native "table":
    discard layout
    let values = env.evalArgs(arguments)
    let
      id = runtime.widgetID(values)
      config = env.evalConfig(bodyNodes, uiDriverRelays.containerConfig())
    runtime.currentUi[].table(id, config):
      discard runtime.renderNodes(env, bodyNodes.childNodes)
    nothing()

  runtime.evaluator.native "tableHeader":
    discard layout
    let values = env.evalArgs(arguments)
    let
      id = runtime.widgetID(values)
      config = env.evalConfig(bodyNodes, uiDriverRelays.containerConfig())
    runtime.currentUi[].tableHeader(id, config):
      discard runtime.renderNodes(env, bodyNodes.childNodes)
    nothing()

  runtime.evaluator.native "tableRow":
    discard layout
    let values = env.evalArgs(arguments)
    let
      id = runtime.widgetID(values)
      config = env.evalConfig(bodyNodes, uiDriverRelays.containerConfig())
    runtime.currentUi[].tableRow(id, config):
      discard runtime.renderNodes(env, bodyNodes.childNodes)
    nothing()

  runtime.evaluator.native "tableCell":
    discard layout
    let values = env.evalArgs(arguments)
    let
      id = runtime.widgetID(values)
      config = env.evalConfig(bodyNodes, uiDriverRelays.containerConfig())
    runtime.currentUi[].tableCell(id, config):
      discard runtime.renderNodes(env, bodyNodes.childNodes)
    nothing()

  runtime.evaluator.native "row":
    discard layout
    let values = env.evalArgs(arguments)
    let
      id = runtime.widgetID(values)
      config = env.evalConfig(bodyNodes, uiDriverRelays.containerConfig())
    runtime.currentUi[].row(id, config):
      discard runtime.renderNodes(env, bodyNodes.childNodes)
    nothing()

  runtime.evaluator.native "column":
    discard layout
    let values = env.evalArgs(arguments)
    let
      id = runtime.widgetID(values)
      config = env.evalConfig(bodyNodes, uiDriverRelays.containerConfig())
    runtime.currentUi[].column(id, config):
      discard runtime.renderNodes(env, bodyNodes.childNodes)
    nothing()

  runtime.evaluator.native "overlay":
    discard layout
    let values = env.evalArgs(arguments)
    let
      id = runtime.widgetID(values)
      config = env.evalConfig(bodyNodes, uiDriverRelays.containerConfig())
    runtime.currentUi[].overlay(id, config):
      discard runtime.renderNodes(env, bodyNodes.childNodes)
    nothing()

  runtime.evaluator.native "spacer":
    discard layout
    let values = env.evalArgs(arguments)
    let
      id = runtime.widgetID(values)
      config = env.evalConfig(bodyNodes, uiDriverRelays.containerConfig())
    discard
      runtime.currentUi[].spacer(id, config.width, config.height,
          config.alignSelf)
    nothing()

  runtime.evaluator.native "label":
    discard layout
    let values = env.evalArgs(arguments)
    let
      id = runtime.widgetID(values)
      labelText = values.textArg(1)
      config = env.evalConfig(bodyNodes, uiDriverRelays.leafConfig())
      fontName = runtime.fontName(config)
    runtime.currentUi[].label(
      id,
      labelText,
      config.width,
      config.height,
      fontName,
      alignSelf = config.alignSelf,
      textScroll = config.textScroll,
      style = config.style,
    )
    nothing()

  runtime.evaluator.native "button":
    discard layout
    let values = env.evalArgs(arguments)
    let
      id = runtime.widgetID(values)
      labelText = values.textArg(1)
      config = env.evalConfig(bodyNodes, uiDriverRelays.leafConfig())
      fontName = runtime.fontName(config)
    boolean(
      runtime.currentUi[].button(
        id,
        labelText,
        config.width,
        config.height,
        config.alignSelf,
        textScroll = config.textScroll,
        fontName = fontName,
        buttonPadding = config.buttonPadding,
        buttonBorderStyle = config.buttonBorderStyle,
        buttonChromeStyle = config.buttonChromeStyle,
        buttonTextAlign = config.buttonTextAlign,
        style = config.style,
      )
    )

  runtime.evaluator.native "checkbox":
    discard layout
    let values = env.evalArgs(arguments)
    if values.len < 3:
      raise newException(EvaluatorError, "checkbox expects id, label, and checked")
    let
      id = runtime.asWidgetID(values[0])
      labelText = values[1].asString
      checked = values[2].isTruthy
      config = env.evalConfig(bodyNodes, uiDriverRelays.leafConfig())
    runtime.currentUi[].checkbox(
      id,
      labelText,
      checked,
      config.width,
      config.height,
      config.fontName,
      config.alignSelf,
    )
    boolean(runtime.requireUi().inEventPhase() and runtime.requireUi().clicked(id))

  runtime.evaluator.native "combobox":
    discard layout
    let values = env.evalArgs(arguments)
    if values.len < 3:
      raise newException(EvaluatorError, "combobox expects id, selected, and options")
    if values[2].kind != List:
      raise newException(EvaluatorError, "combobox options must be a list")
    let
      id = runtime.asWidgetID(values[0])
      selected = values[1].asNumber.int
      config = env.evalConfig(bodyNodes, uiDriverRelays.leafConfig())
    var options: seq[string]
    for item in values[2].items:
      options.add item.asString
    let picked = runtime.currentUi[].combobox(
      id,
      selected,
      options,
      config.width,
      config.height,
      config.alignSelf,
    )
    if runtime.requireUi().inEventPhase() and picked.changed:
      number(picked.index.float64)
    else:
      nothing()

  runtime.evaluator.native "lineInput":
    discard layout
    let values = env.evalArgs(arguments)
    let
      id =
        runtime.widgetID(values, "lineInput")
      key =
        if arguments.len > 0:
          env.idKey(arguments[0], values[0].asString)
        else:
          "lineInput"
      initial =
        if values.len > 1:
          values[1].asString
        else:
          ""
      config = env.evalConfig(bodyNodes, uiDriverRelays.lineInputConfig())
    if key notin runtime.editorStates:
      runtime.editorStates[key] = EditorState.new(initial)
    runtime.currentUi[].lineInput(
      id,
      runtime.editorStates[key],
      config.width,
      config.height,
      config.fontName,
      config.alignSelf,
    )
    nothing()

  runtime.evaluator.native "modalDialog":
    discard layout
    if arguments.len < 2:
      raise newException(EvaluatorError, "modalDialog expects id and open")
    let values = env.evalArgs(arguments)
    let
      id = runtime.asWidgetID(values[0])
      open = values[1].isTruthy
      config = env.evalConfig(bodyNodes, uiDriverRelays.containerConfig())
    runtime.currentUi[].modalDialog(id, open, config):
      discard runtime.renderNodes(env, bodyNodes.childNodes)
    nothing()

  runtime.evaluator.native "tabs":
    discard layout
    if arguments.len != 3:
      raise newException(EvaluatorError, "tabs expects id, labels, and selected symbol")
    if arguments[2].kind != Symbol:
      raise newException(EvaluatorError, "tabs selected argument must be a symbol")

    let
      values = env.evalArgs(arguments)
      id = runtime.asWidgetID(values[0])
      selectedSymbol = arguments[2].symbol
      config = env.evalConfig(bodyNodes, uiDriverRelays.tabsConfig())

    var labels: seq[string]
    if values[1].kind != List:
      raise newException(EvaluatorError, "tabs labels must be a list")
    for item in values[1].items:
      labels.add item.asString

    var selected = values[2].asNumber.int
    try:
      runtime.currentUi[].tabs(
        id,
        labels,
        selected,
        config.width,
        config.height,
        config.alignSelf,
        config.gap,
        config.padding,
        config.style,
      )
    except Exception as error:
      raise newException(EvaluatorError, error.msg)
    env.set(selectedSymbol, number(selected.float64))
    number(selected.float64)

  runtime.evaluator.native "editor":
    discard layout
    let values = env.evalArgs(arguments)
    let
      id =
        runtime.widgetID(values, "editor")
      key =
        if arguments.len > 1:
          env.idKey(arguments[1], values[1].asString)
        elif arguments.len > 0:
          env.idKey(arguments[0], values[0].asString)
        else:
          "editor"
      config = env.evalConfig(bodyNodes, uiDriverRelays.editorConfig())
    if key notin runtime.editorStates:
      runtime.editorStates[key] = EditorState.new("")
    runtime.currentUi[].textEditor(
      id,
      runtime.editorStates[key],
      config.width,
      config.height,
      fontName = config.fontName,
      alignSelf = config.alignSelf,
      lineNumbers = config.lineNumbers,
      scrollbars = config.scrollbars,
      syntax = config.syntax,
      gutterMarkers = config.gutterMarkers,
      activeLine = config.activeLine,
    )
    nothing()

  runtime.evaluator.native "image":
    discard layout
    let values = env.evalArgs(arguments)
    let id =
      if values.len > 0:
        runtime.asWidgetID(values[0])
      else:
        nextWidgetID()
    let path =
      if values.len > 1:
        values[1].asString
      else:
        ""
    let config = env.evalConfig(bodyNodes, uiDriverRelays.leafConfig())
    runtime.currentUi[].image(id, path, config.width, config.height,
        config.alignSelf)
    nothing()

  runtime.evaluator.native "imageButton":
    discard layout
    let values = env.evalArgs(arguments)
    let id =
      if values.len > 0:
        runtime.asWidgetID(values[0])
      else:
        nextWidgetID()
    let path =
      if values.len > 1:
        values[1].asString
      else:
        ""
    let config = env.evalConfig(bodyNodes, uiDriverRelays.leafConfig())
    boolean(
      runtime.currentUi[].imageButton(
        id, path, config.width, config.height, config.alignSelf, config.style
      )
    )

  runtime.evaluator.native "horizontalSlider":
    discard layout
    let values = env.evalArgs(arguments)
    if values.len < 4:
      raise newException(
        EvaluatorError, "horizontalSlider expects id, value, minimum, and maximum"
      )
    let
      id = runtime.asWidgetID(values[0])
      current = values[1].asNumber
      minimum = values[2].asNumber
      maximum = values[3].asNumber
      config = env.evalConfig(bodyNodes, uiDriverRelays.sliderConfig())
      changed = runtime.currentUi[].slider(
        id, current, minimum, maximum, config.width, config.height,
        SliderHorizontal,
        config.alignSelf,
      )
    if changed.active:
      number(changed.value)
    else:
      nothing()

  runtime.evaluator.native "verticalSlider":
    discard layout
    let values = env.evalArgs(arguments)
    if values.len < 4:
      raise newException(
        EvaluatorError, "verticalSlider expects id, value, minimum, and maximum"
      )
    let
      id = runtime.asWidgetID(values[0])
      current = values[1].asNumber
      minimum = values[2].asNumber
      maximum = values[3].asNumber
      config = env.evalConfig(bodyNodes, uiDriverRelays.sliderConfig())
      changed = runtime.currentUi[].slider(
        id, current, minimum, maximum, config.width, config.height,
        SliderVertical,
        config.alignSelf,
      )
    if changed.active:
      number(changed.value)
    else:
      nothing()

  runtime.evaluator.env.define("AlignAuto", alignValue(AlignAuto))
  runtime.evaluator.env.define("AlignStart", alignValue(AlignStart))
  runtime.evaluator.env.define("AlignCenter", alignValue(AlignCenter))
  runtime.evaluator.env.define("AlignEnd", alignValue(AlignEnd))
  runtime.evaluator.env.define("AlignStretch", alignValue(AlignStretch))
  runtime.evaluator.env.define("JustifyStart", justifyValue(JustifyStart))
  runtime.evaluator.env.define("JustifyCenter", justifyValue(JustifyCenter))
  runtime.evaluator.env.define("JustifyEnd", justifyValue(JustifyEnd))
  runtime.evaluator.env.define("ButtonBorderNone",
      buttonBorderStyleValue(ButtonBorderNone))
  runtime.evaluator.env.define("ButtonBorderLine",
      buttonBorderStyleValue(ButtonBorderLine))
  runtime.evaluator.env.define("ButtonChromeFlat",
      buttonChromeStyleValue(ButtonChromeFlat))
  runtime.evaluator.env.define("ButtonChromeRaised",
      buttonChromeStyleValue(ButtonChromeRaised))

proc init*(T: typedesc[NestOwlRuntime]): T =
  ## Create a runtime with a fresh evaluator and Nest's owl builtins.
  ##
  ## The runtime owns the program's state bindings, its dialog and shell
  ## processes, its workspace subscriptions and its editor states.
  result = T(
    evaluator: Evaluator.init(),
    externalEvents: initCountTable[string](),
    widgetState: initTable[string, Value](),
    messages: initTable[string, seq[Value]](),
    loadedModules: initHashSet[string](),
    dialogProcesses: initTable[string, DialogProcess](),
    dialogResults: initTable[string, string](),
    openMenus: initTable[string, string](),
    editorStates: initTable[string, EditorState](),
    pathPickerResults: initTable[string, string](),
    shellProcesses: initTable[string, ShellProcess](),
    shellCache: initTable[string, ShellCache](),
    workspaceSubscriptions: initTable[string, WorkspaceSubscription](),
  )
  result.registerNestCommands()

proc get*(runtime: NestOwlRuntime, name: string): Value {.raises: [
    EvaluatorError].} =
  ## Return the value bound to `name` in the program's environment.
  ##
  ## Raises `EvaluatorError` when nothing is bound to that name.
  runtime.evaluator.env.get(name)

proc widgetID*(
    runtime: NestOwlRuntime, name: string
): WidgetID {.raises: [EvaluatorError].} =
  ## Return the widget id the program bound to `name`.
  ##
  ## Raises `EvaluatorError` when nothing is bound to that name or the value
  ## is not a widget id.
  runtime.asWidgetID(runtime.get(name))

proc dependenciesChanged*(runtime: NestOwlRuntime): bool =
  ## Test whether any loaded owl file has changed on disk since it was read.
  for path, lastTime in runtime.loadedFiles:
    try:
      if getLastModificationTime(path) != lastTime:
        return true
    except OSError:
      return true

proc reload*(app: NestOwlApp): bool {.discardable.} =
  ## Reload the app's owl program from disk and report whether it parsed.
  ##
  ## Dialog and shell processes and workspace subscriptions from the previous
  ## program are closed first. A program that fails to load leaves the error
  ## on `lastError` and `lastErrorDetails`.
  if app.runtime != nil:
    app.runtime.closeDialogProcesses()
    app.runtime.closeShellProcesses()
    app.runtime.closeWorkspaceSubscriptions()
  app.runtime = NestOwlRuntime.init()
  app.runtime.loadedFiles.clear()
  try:
    app.program = app.runtime.loadSyntaxFile(app.rootPath)
    app.lastError = ""
    true
  except EvaluatorError as error:
    app.program = nil
    app.lastError = report(error)
    app.lastErrorDetails = error.errorDetails()
    false

proc init*(T: typedesc[NestOwlApp], rootPath: string): T =
  ## Create an app rooted at the owl file `rootPath` and load its program.
  result = T(rootPath: rootPath.normalizedPath, runtime: NestOwlRuntime.init())
  discard result.reload()

proc render*(runtime: NestOwlRuntime, ui: var UI, program: SyntaxNode) =
  ## Render `program` into `ui` for this frame.
  ##
  ## Polls the program's shell and dialog processes, evaluates its event
  ## handlers and widget declarations, and commits the state they changed.
  if program.isNil:
    return
  runtime.pollShellProcesses(ui)
  runtime.pollDialogProcesses()
  runtime.hasError = false
  runtime.lastError = ""
  runtime.lastErrorDetails = ErrorDetails()
  runtime.pollPathCallbacks()
  if runtime.hasError:
    return
  runtime.commitState()
  runtime.currentUi = addr ui
  runtime.stateBindings.setLen(0)
  try:
    ui.layout:
      discard runtime.renderNodes(program.statements)
  finally:
    runtime.commitState()
    runtime.currentUi = nil

proc loadWidgetLibrary*(runtime: NestOwlRuntime, path: string) =
  ## Import the owl widget library at `path` into the program's
  ## environment, making its widgets available to render.
  runtime.importModule(runtime.evaluator.env, path)

proc renderWidget*(
    runtime: NestOwlRuntime,
    ui: var UI,
    libraryPath, widgetName: string,
    arguments: openArray[SyntaxNode],
) =
  ## Render the widget `widgetName` from the library at `libraryPath`
  ## into `ui`, passing `arguments` as owl syntax nodes.
  ##
  ## Does nothing while the runtime is holding an error.
  if runtime.hasError:
    return
  runtime.currentUi = addr ui
  runtime.stateBindings.setLen(0)
  try:
    if libraryPath.len > 0:
      runtime.loadWidgetLibrary(libraryPath)
    var nodes: seq[SyntaxNode]
    for argument in arguments:
      nodes.add argument
    discard runtime.renderNodes(@[command(symbol(widgetName), nodes)])
  finally:
    runtime.commitState()
    runtime.currentUi = nil

proc renderWidget*(
    runtime: NestOwlRuntime,
    ui: var UI,
    libraryPath, widgetName: string,
    arguments: openArray[string] = [],
) =
  ## Render the widget `widgetName` from the library at `libraryPath`
  ## into `ui`, passing `arguments` as owl string literals.
  var nodes: seq[SyntaxNode]
  for argument in arguments:
    nodes.add stringLiteral(argument)
  runtime.renderWidget(ui, libraryPath, widgetName, nodes)

proc renderLayoutOnly*(
    runtime: NestOwlRuntime, ui: var UI, program: SyntaxNode, width, height: int
) =
  ## Lay `program` out in a `width` by `height` window without drawing it.
  ##
  ## Used by tests and by size probes that need the solved layout only.
  if program.isNil:
    return
  runtime.pollShellProcesses(ui)
  runtime.pollDialogProcesses()
  runtime.hasError = false
  runtime.lastError = ""
  runtime.currentUi = addr ui
  runtime.stateBindings.setLen(0)
  try:
    ui.beginLayout(width, height)
    discard runtime.renderNodes(program.statements)
    ui.applyIntrinsicSizes(ui.resources)
    discard ui.endLayout()
  finally:
    runtime.commitState()
    runtime.currentUi = nil

proc render*(app: NestOwlApp, ui: var UI) =
  ## Render the app's program into `ui` for this frame.
  ##
  ## Reloads the program when a source file changed, decides between a full
  ## and an incremental render, and keeps the program's shell and dialog
  ## processes polled. Does nothing when no program is loaded.
  if app.isNil:
    return
  let now = currentTicks()
  let maintenanceDue = app.lastMaintenanceTicks == 0 or
    now - app.lastMaintenanceTicks >= MaintenancePollMs
  if maintenanceDue:
    app.lastMaintenanceTicks = now
    app.runtime.pollShellProcesses(ui)
    app.runtime.pollDialogProcesses()
  if app.program.isNil or (maintenanceDue and app.runtime.dependenciesChanged()):
    discard app.reload()
    ui.requestRedrawAfter(0)
  if app.program.isNil:
    return
  if app.runtime.dialogCloseRequested:
    ui.markAllDirty()
  let fullRenderDue = app.lastFullRenderTicks == 0 or
      ui.hasPendingFullRenderInput() or
    ui.needsFullRender() or
    (app.runtime.nextFullRenderTicks > 0 and now >=
        app.runtime.nextFullRenderTicks)
  if not fullRenderDue and ui.hasRetainedFrame():
    ui.setDrawTicks(now)
    if ui.hasPendingInput():
      discard ui.updateRetainedFrame()
    else:
      discard ui.drawRetainedFrame()
    ui.requestRedrawAfter(MaintenancePollMs)
    return
  app.lastFullRenderTicks = now
  app.runtime.nextFullRenderTicks = 0
  ui.requestRedrawAfter(MaintenancePollMs)
  app.runtime.moduleStack.add app.rootPath
  app.runtime.render(ui, app.program)
  app.runtime.moduleStack.setLen(app.runtime.moduleStack.len - 1)
  if app.runtime.hasError:
    app.lastError = app.runtime.lastError
    app.lastErrorDetails = app.runtime.lastErrorDetails
  else:
    app.lastError = ""
    app.lastErrorDetails = ErrorDetails()
