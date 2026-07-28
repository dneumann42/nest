import std/[math, macros, sets, strutils, tables]

import layouts, components, coords, palette, resources, widgets2
export layouts, components
import nest/screen

type
  ComponentWidget = tuple[component: Component, widget: Widget]
  WidgetSlot* = seq[Widget]
  LayoutKind = enum
    RowLayout
    ColumnLayout
    OverlayLayout

  UIPhase = enum
    LayoutPhase
    EventPhase

  LayoutFrame = object
    parent: Widget
    children: seq[Widget]

  ScrollAxis = enum
    NoScroll
    ScrollX
    ScrollY

  ScrollState = object
    scrollX, scrollY: float64
    targetX, targetY: float64
    maxX, maxY: float64
    contentWidth, contentHeight: float64
    dragging: ScrollAxis
    dragStartMouse: float64
    dragStartScroll: float64

  BoxConfig* = object
    width*, height*: SizePolicy
    gap*, padding*: float64
    alignItems*: Alignment
    justifyContent*: Justification
    alignSelf*: Alignment
    scrollX*, scrollY*: bool
    textScroll*: bool
    lineNumbers*: bool
    scrollbars*: bool
    gutterMarkers*: HashSet[int]
    activeLine*: int
    fontName*: string
    syntax*: string
    style*: ComponentStyle

  PendingLayout = object
    kind: LayoutKind
    parent: Widget
    children: seq[Widget]
    gap, padding: float64
    alignItems: Alignment
    justifyContent: Justification
    scrollX, scrollY: bool

  UIContext = object
    update: UpdateContext
    draw: DrawContext

  UI* = object
    layout*: Layout
    root*, parent*: Widget
    context: UIContext
    frames*: seq[LayoutFrame]
    childrenWidgets*: seq[Widget]
    components*: seq[ComponentWidget]
    floatingWidgets: seq[Widget]
    floatingBelowAnchors: Table[WidgetID, WidgetID]
    componentByID: Table[WidgetID, Component]
    intrinsicByID: TableRef[WidgetID, IntrinsicSize]
    pendingLayouts: seq[PendingLayout]
    layoutChildren: Table[WidgetID, seq[Widget]]
    scrollStates: Table[WidgetID, ScrollState]
    scrollContainers: HashSet[WidgetID]
    frameByID: Table[WidgetID, Frame]
    dialogResults: Table[string, string]
    liveWidgetIDs: HashSet[WidgetID]
    previousWidgetIDs: HashSet[WidgetID]
    pointerBlockFrames: seq[Frame]
    renderKeys: Table[WidgetID, string]
    idScopes: seq[string]
    eventActiveWidgets: HashSet[WidgetID]
    eventSubmittedWidgets: HashSet[WidgetID]
    eventFocusedWidget: WidgetID
    scheduledRedrawTicks: int
    hasScheduledRedraw: bool
    frameRedrawn: bool
    phase: UIPhase
    autoIDCounter: uint64
    themeName*: string

  ListItem*[T] = object
    index*: int
    key*: string
    value*: T

  EditLineState* = object
    input*: LineInputState
    inputID*: WidgetID
    key*: string

macro layoutOnly*(definition: untyped): untyped =
  result = definition
  if result.kind notin {nnkProcDef, nnkFuncDef, nnkMethodDef}:
    error("layoutOnly can only be used on routines", definition)

  let params = result[3]
  if params.len < 2 or params[1].kind != nnkIdentDefs:
    error(
      "layoutOnly requires a routine with a UI receiver as the first parameter",
      definition,
    )

  let receiver = params[1][0]
  let body = result[^1]
  result[^1] = quote:
    if `receiver`.phase == EventPhase:
      return
    `body`

proc cfg*(
    width = fill(),
    height = fill(),
    gap = 0.0,
    padding = 0.0,
    alignItems = AlignStretch,
    justifyContent = JustifyStart,
    alignSelf = AlignAuto,
    scrollX = false,
    scrollY = false,
    textScroll = false,
    lineNumbers = false,
    scrollbars = true,
    gutterMarkers: HashSet[int] = initHashSet[int](),
    activeLine = 0,
    fontName = "font",
    syntax = "",
    style = ComponentStyle(),
): BoxConfig =
  BoxConfig(
    width: width,
    height: height,
    gap: gap,
    padding: padding,
    alignItems: alignItems,
    justifyContent: justifyContent,
    alignSelf: alignSelf,
    scrollX: scrollX,
    scrollY: scrollY,
    textScroll: textScroll,
    lineNumbers: lineNumbers,
    scrollbars: scrollbars,
    gutterMarkers: gutterMarkers,
    activeLine: activeLine,
    fontName: fontName,
    syntax: syntax,
    style: style,
  )

proc withBackground*(config: BoxConfig, background: Color): BoxConfig =
  result = config
  result.style.hasBackground = true
  result.style.background = background

proc withOpacity*(config: BoxConfig, opacity: float64): BoxConfig =
  result = config
  result.style.hasOpacity = true
  result.style.opacity = opacity

proc init*(T: typedesc[UI]): T =
  var ui = newLayout()
  result = T(
    layout: ui,
    root: ui.box(nextWidgetID(), width = fill(), height = fill()),
    context: UIContext(
      update: UpdateContext(),
      draw:
    DrawContext(resources: Resources.new(), palette: Palette.init(),
        dirtyAll: true),
  ),
    intrinsicByID: newTable[WidgetID, IntrinsicSize](),
  )

proc setTheme*(self: var UI; themeName: string) =
  self.themeName = themeName
  self.context.draw.palette = Palette.init(themeName)

proc initContext*(self: var UI, windowWidth, windowHeight: int) =
  self.context.update.windowWidth = windowWidth
  self.context.update.windowHeight = windowHeight
  self.context.draw.windowWidth = windowWidth
  self.context.draw.windowHeight = windowHeight
  self.context.draw.palette = Palette.init(self.themeName)

proc resources*(self: UI): Resources =
  self.context.draw.resources

proc palette*(self: UI): Palette =
  self.context.draw.palette

proc font*(self: UI, name = "font"): screen.Font =
  let (font, _) = self.context.draw.resources.get(name)
  screen.Font(font)

proc loadFont*(self: UI, name, path: string, size: Positive) =
  self.context.draw.resources.loadFont(name, path, size)

proc windowWidth*(self: UI): int =
  self.context.draw.windowWidth

proc windowHeight*(self: UI): int =
  self.context.draw.windowHeight

proc widgetFrame*(
    self: UI, id: WidgetID
): tuple[ok: bool, frame: Frame] {.raises: [].} =
  for box in self.layout.boxes:
    if box.id == id:
      return (true, box.frame)
  try:
    if self.frameByID.hasKey(id):
      return (true, self.frameByID[id])
  except KeyError:
    discard
  (false, Frame())

proc pointerInputBlocked*(self: UI, x, y: int): bool {.raises: [].} =
  for frame in self.pointerBlockFrames:
    if x.toFloat >= frame.x and x.toFloat < frame.x + frame.width and
        y.toFloat >= frame.y and y.toFloat < frame.y + frame.height:
      return true

proc wantsTextInput*(self: UI): bool =
  self.context.draw.focusedWidget != InvalidWidgetID

proc requestRedrawAfter*(self: var UI, ms: int) =
  let ticks = input.getTicks() + max(ms, 0)
  if not self.hasScheduledRedraw or ticks < self.scheduledRedrawTicks:
    self.scheduledRedrawTicks = ticks
    self.hasScheduledRedraw = true

proc requestRedrawAfterSafe(self: var UI, ms: int) {.raises: [].} =
  try:
    self.requestRedrawAfter(ms)
  except Exception:
    discard

proc redrawDelayMs*(self: UI): int =
  if not self.hasScheduledRedraw:
    return -1
  max(self.scheduledRedrawTicks - input.getTicks(), 0)

proc clearRedrawRequest*(self: var UI) {.raises: [].} =
  self.hasScheduledRedraw = false

proc markAllDirty*(self: var UI) {.raises: [].} =
  self.context.draw.dirtyAll = true

proc markDirty*(self: var UI, id: WidgetID) {.raises: [].} =
  if id != InvalidWidgetID:
    self.context.draw.dirtyWidgets.incl id

proc redrewFrame*(self: UI): bool {.raises: [].} =
  self.frameRedrawn

proc setDrawTicks*(self: var UI, ticks: int) =
  self.context.draw.ticks = ticks

proc setDrawCommands*(self: var UI, commands: ptr seq[DrawCommand]) =
  self.context.draw.drawCommands = commands

proc setDrawCommandRelays*(
    self: var UI,
    commands: ptr seq[DrawCommand],
    measureText: proc(f: Font, text: string): TextExtent {.nimcall.},
    measureImage: proc(path: string): TextExtent {.nimcall.},
) =
  self.context.draw.drawCommands = commands
  self.context.draw.commandMeasureText = measureText
  self.context.draw.commandMeasureImage = measureImage

proc setIO*(self: var UI, io: IO) =
  self.context.draw.io = io

proc io*(self: UI): IO =
  self.context.draw.io

proc pick*(files: FileIO, id: WidgetID, defaultLocation = ""): bool {.discardable.} =
  if files.openFile.isNil:
    false
  else:
    files.openFile(id, defaultLocation.cstring)

proc value*(files: FileIO, id: WidgetID): string =
  if files.fileValue.isNil:
    ""
  else:
    $files.fileValue(id)

proc error*(files: FileIO, id: WidgetID): string =
  if files.fileError.isNil:
    ""
  else:
    $files.fileError(id)

proc clear*(files: FileIO, id: WidgetID) =
  if not files.clearFile.isNil:
    files.clearFile(id)

proc openDialog*(self: var UI, open: var bool) =
  open = true
  self.requestRedrawAfter(0)

proc closeDialog*(self: var UI, open: var bool) =
  open = false
  self.requestRedrawAfter(0)

proc toggleDialog*(self: var UI, open: var bool): bool {.discardable.} =
  open = not open
  self.requestRedrawAfter(0)
  open

proc returnDialog*(
    self: var UI, key, value: string, open: var bool
): string {.discardable.} =
  self.dialogResults[key] = value
  self.closeDialog(open)
  value

proc hasDialogResult*(self: UI, key: string): bool =
  self.dialogResults.hasKey(key)

proc dialogResult*(self: UI, key: string): string =
  self.dialogResults.getOrDefault(key)

proc clearDialogResult*(self: var UI, key: string) =
  self.dialogResults.del key

proc setRenderKey*(self: var UI, id: WidgetID, key: string) =
  let previous = self.renderKeys.getOrDefault(id)
  if previous != key:
    if previous.len > 0:
      self.markAllDirty()
    else:
      self.markDirty(id)
    self.renderKeys[id] = key

proc renderKey(kind: string, config: BoxConfig): string =
  let styleKey =
    "|" & $config.style.hasBackground & "|" & $config.style.background & "|" &
    $config.style.hasOpacity & "|" & $config.style.opacity
  kind & "|" & $config.width & "|" & $config.height & "|" & $config.gap & "|" &
    $config.padding & "|" & $config.alignItems & "|" & $config.justifyContent & "|" &
    $config.alignSelf & "|" & $config.scrollX & "|" & $config.scrollY & "|" &
    $config.textScroll & "|" & $config.lineNumbers & "|" & $config.scrollbars & "|" &
    config.fontName & "|" & config.syntax & styleKey

proc renderKey(kind: string, width, height: SizePolicy,
    alignSelf: Alignment): string =
  kind & "|" & $width & "|" & $height & "|" & $alignSelf

proc beginInputFrame*(self: var UI) =
  self.context.update.keyInputs.setLen(0)
  self.context.update.textInputs.setLen(0)
  self.context.update.mouseWheelX = 0
  self.context.update.mouseWheelY = 0
  self.context.update.submittedWidgets.clear()
  self.context.update.sliderValues.clear()

proc finishInputFrame*(self: var UI) =
  self.context.update.mouseLeftPressed = false
  self.context.update.keyInputs.setLen(0)
  self.context.update.textInputs.setLen(0)
  self.context.update.mouseWheelX = 0
  self.context.update.mouseWheelY = 0
  self.context.update.submittedWidgets.clear()
  self.context.update.sliderValues.clear()

proc mouseMove*(self: var UI, x, y: int) =
  self.context.update.mouseX = x
  self.context.update.mouseY = y
  self.context.draw.mouseX = x
  self.context.draw.mouseY = y

proc mouseDown*(self: var UI) =
  let last = self.context.update.mouseLeftDown
  self.context.update.mouseLeftDown = true
  self.context.update.mouseLeftPressed = not last

proc mouseUp*(self: var UI) =
  self.context.update.mouseLeftDown = false
  self.context.update.mouseLeftPressed = false
  self.context.update.sliderDragging = InvalidWidgetID

proc resizeWindow*(self: var UI, width, height: int) =
  self.context.update.windowWidth = max(width, 0)
  self.context.update.windowHeight = max(height, 0)
  self.context.draw.windowWidth = self.context.update.windowWidth
  self.context.draw.windowHeight = self.context.update.windowHeight

proc keyDown*(self: var UI, key: KeyCode, mods: set[Modifier]) =
  self.context.update.keyInputs.add KeyInput(key: key, mods: mods)

proc textInput*(self: var UI, text: string) =
  if text.len > 0:
    self.context.update.textInputs.add text

proc mouseWheel*(self: var UI, x, y: float64) =
  self.context.update.mouseWheelX += x
  self.context.update.mouseWheelY += y

proc stableHash(text: string): uint64 =
  result = 14_695_981_039_346_656_037'u64
  for ch in text:
    result = result xor uint64(ch.ord)
    result = result * 1_099_511_628_211'u64

proc keyedWidgetID(parts: openArray[string]): WidgetID =
  var text: string
  for part in parts:
    text.add part.len.intToStr
    text.add ":"
    text.add part
    text.add "\0"
  WidgetID(0x8000_0000_0000_0000'u64 or stableHash(text))

proc id*(self: UI, parts: varargs[string, `$`]): WidgetID =
  var scoped = self.idScopes
  if parts.len == 0 and scoped.len == 0:
    scoped.add "_nest_empty_id"
  else:
    for part in parts:
      scoped.add part
  keyedWidgetID(scoped)

proc nextAutoID*(self: var UI): WidgetID =
  let key = "_nest_auto_id:" & $self.autoIDCounter
  inc self.autoIDCounter
  self.id(key)

template scope*(self: var UI, key: untyped, body: untyped) =
  block:
    self.idScopes.add($key)
    try:
      body
      discard
    finally:
      self.idScopes.setLen(self.idScopes.len - 1)

proc beginEvents(self: var UI, context: DrawContext) =
  self.phase = EventPhase
  self.autoIDCounter = 0
  self.eventActiveWidgets = context.activeWidgets
  self.eventSubmittedWidgets = context.submittedWidgets
  self.eventFocusedWidget = context.focusedWidget

proc active*(self: UI, id: WidgetID): bool =
  id in self.eventActiveWidgets

proc clicked*(self: UI, id: WidgetID): bool =
  self.active(id)

proc submitted*(self: UI, id: WidgetID): bool =
  id in self.eventSubmittedWidgets

proc sliderValue*(self: UI, id: WidgetID): tuple[active: bool, value: float64] =
  if self.phase == EventPhase and self.context.draw.sliderDragging == id and
      self.context.draw.sliderValues.hasKey(id):
    return (true, self.context.draw.sliderValues[id])
  (false, 0.0)

proc focused*(self: UI, id: WidgetID): bool =
  self.eventFocusedWidget == id

proc inEventPhase*(self: UI): bool =
  self.phase == EventPhase

proc inLayoutPhase*(self: UI): bool =
  self.phase == LayoutPhase

proc normalizedKeyName(value: string): string =
  for ch in value:
    if ch notin {'-', '_', ' '}:
      result.add toLowerAscii(ch)

proc keyPressed*(self: UI, name: string): bool =
  if self.phase != EventPhase:
    return false
  let wanted = normalizedKeyName(name)
  for input in self.context.update.keyInputs:
    let keyName = normalizedKeyName($input.key)
    if keyName == wanted or keyName == "key" & wanted:
      return true
    if wanted == "escape" and keyName == "keyesc":
      return true
    if wanted == "esc" and keyName == "keyesc":
      return true

proc listKey*(index: int, value: string): string =
  $index & ":" & value

proc listItems*[T](
    items: openArray[T],
    key: proc(item: T, index: int): string,
    filter: proc(item: T, index: int): bool = nil,
): seq[ListItem[T]] =
  for index, item in items:
    if filter.isNil or filter(item, index):
      result.add ListItem[T](index: index, key: key(item, index), value: item)

proc editLineState*(): EditLineState =
  EditLineState(input: LineInputState.new(""), inputID: nextWidgetID(), key: "")

proc editing*(state: EditLineState): bool =
  state.key.len > 0

proc editing*(state: EditLineState, key: string): bool =
  state.key == key

proc beginEdit*(state: var EditLineState, key, value: string) =
  state.key = key
  state.input.text = value
  state.input.cursor = value.len

proc cancelEdit*(state: var EditLineState) =
  state.key = ""

proc saveEdit*(state: var EditLineState): string =
  result = state.input.text
  state.cancelEdit()

proc reset*(self: var UI) =
  let rootID =
    if self.root.id == InvalidWidgetID:
      nextWidgetID()
    else:
      self.root.id
  self.layout = newLayout()
  self.root = self.layout.box(rootID, width = fill(), height = fill())
  self.parent = self.root
  self.frames.setLen(0)
  self.childrenWidgets.setLen(0)
  self.components.setLen(0)
  self.floatingWidgets.setLen(0)
  self.floatingBelowAnchors.clear()
  self.componentByID.clear()
  if self.intrinsicByID.isNil:
    self.intrinsicByID = newTable[WidgetID, IntrinsicSize]()
  else:
    self.intrinsicByID.clear()
  self.pendingLayouts.setLen(0)
  self.layoutChildren.clear()
  self.scrollContainers.clear()
  self.idScopes.setLen(0)
  self.eventActiveWidgets.clear()
  self.eventSubmittedWidgets.clear()
  self.eventFocusedWidget = InvalidWidgetID
  self.phase = LayoutPhase

proc beginLayout*(self: var UI, windowWidth, windowHeight: int) =
  self.autoIDCounter = 0
  self.layout.root(self.root)
  self.parent = self.root
  self.frames = @[LayoutFrame(parent: self.root)]
  self.childrenWidgets.setLen(0)
  self.components.setLen(0)
  self.floatingWidgets.setLen(0)
  self.floatingBelowAnchors.clear()
  self.componentByID.clear()
  if self.intrinsicByID.isNil:
    self.intrinsicByID = newTable[WidgetID, IntrinsicSize]()
  else:
    self.intrinsicByID.clear()
  self.pendingLayouts.setLen(0)
  self.layoutChildren.clear()
  self.scrollContainers.clear()
  self.liveWidgetIDs.clear()
  self.liveWidgetIDs.incl self.root.id
  self.idScopes.setLen(0)
  self.layout.resize(windowWidth.toFloat, windowHeight.toFloat)

proc clamp(value, lo, hi: float64): float64 =
  min(max(value, lo), hi)

proc shiftWidget(widget: Widget, dx, dy: float64) =
  widget.x.value = widget.x.value + dx
  widget.y.value = widget.y.value + dy

proc scrollbarSize(): float64 =
  10.0

proc scrollWheelStep(): float64 =
  42.0

proc scrollLerpFactor(): float64 =
  0.35

proc snapBackLerpFactor(): float64 =
  0.22

proc overscrollLimit(viewport: float64): float64 =
  min(72.0, max(viewport * 0.35, 16.0))

proc snapTarget(value, lo, hi: float64): float64 =
  let target = value.clamp(lo, hi)
  result = value.lerp(target, snapBackLerpFactor())
  if abs(result - target) < 0.25:
    result = target

proc horizontalTrack(parent: Widget): Frame =
  let f = parent.frame
  Frame(
    x: f.x,
    y: f.y + max(f.height - scrollbarSize(), 0.0),
    width: max(f.width - scrollbarSize(), 0.0),
    height: min(scrollbarSize(), f.height),
  )

proc verticalTrack(parent: Widget): Frame =
  let f = parent.frame
  Frame(
    x: f.x + max(f.width - scrollbarSize(), 0.0),
    y: f.y,
    width: min(scrollbarSize(), f.width),
    height: max(f.height - scrollbarSize(), 0.0),
  )

proc horizontalThumb(parent: Widget, state: ScrollState): Frame =
  let track = horizontalTrack(parent)
  if state.maxX <= 0 or state.contentWidth <= 0 or track.width <= 0:
    return Frame(x: track.x, y: track.y, width: track.width,
        height: track.height)
  let thumbWidth =
    max(24.0, track.width * min(parent.frame.width / state.contentWidth, 1.0))
  let travel = max(track.width - thumbWidth, 0.0)
  Frame(
    x: track.x + travel * (state.scrollX / state.maxX),
    y: track.y,
    width: thumbWidth,
    height: track.height,
  )

proc verticalThumb(parent: Widget, state: ScrollState): Frame =
  let track = verticalTrack(parent)
  if state.maxY <= 0 or state.contentHeight <= 0 or track.height <= 0:
    return Frame(x: track.x, y: track.y, width: track.width,
        height: track.height)
  let thumbHeight =
    max(24.0, track.height * min(parent.frame.height / state.contentHeight, 1.0))
  let travel = max(track.height - thumbHeight, 0.0)
  Frame(
    x: track.x,
    y: track.y + travel * (state.scrollY / state.maxY),
    width: track.width,
    height: thumbHeight,
  )

proc contains(frame: Frame, x, y: int): bool =
  x.toFloat >= frame.x and x.toFloat < frame.x + frame.width and y.toFloat >=
      frame.y and
    y.toFloat < frame.y + frame.height

proc shiftDescendants(
    self: UI, parent: Widget, dx, dy: float64, visited: var HashSet[WidgetID]
) =
  if not self.layoutChildren.hasKey(parent.id):
    return
  for child in self.layoutChildren[parent.id]:
    if child.id in visited:
      continue
    visited.incl child.id
    child.shiftWidget(dx, dy)
    self.shiftDescendants(child, dx, dy, visited)

proc updateScrollState(self: var UI, parent: Widget) =
  if not self.layoutChildren.hasKey(parent.id):
    return
  var
    minLeft = Inf
    minTop = Inf
    maxRight = -Inf
    maxBottom = -Inf

  for child in self.layoutChildren[parent.id]:
    let f = child.frame
    minLeft = min(minLeft, f.x)
    minTop = min(minTop, f.y)
    maxRight = max(maxRight, f.x + f.width)
    maxBottom = max(maxBottom, f.y + f.height)

  var state = self.scrollStates.getOrDefault(parent.id)
  let
    previousScrollX = state.scrollX
    previousScrollY = state.scrollY
  let parentFrame = parent.frame
  if minLeft == Inf:
    state.contentWidth = parentFrame.width
    state.contentHeight = parentFrame.height
  else:
    state.contentWidth = max(parentFrame.width, maxRight - min(parentFrame.x, minLeft))
    state.contentHeight =
      max(parentFrame.height, maxBottom - min(parentFrame.y, minTop))
  state.maxX = max(state.contentWidth - parentFrame.width, 0.0)
  state.maxY = max(state.contentHeight - parentFrame.height, 0.0)
  let
    overscrollX = overscrollLimit(parentFrame.width)
    overscrollY = overscrollLimit(parentFrame.height)
  state.targetX = state.targetX.clamp(-overscrollX, state.maxX + overscrollX)
  state.targetY = state.targetY.clamp(-overscrollY, state.maxY + overscrollY)
  if state.dragging != ScrollX:
    state.targetX = state.targetX.snapTarget(0.0, state.maxX)
  if state.dragging != ScrollY:
    state.targetY = state.targetY.snapTarget(0.0, state.maxY)
  state.scrollX = state.scrollX.clamp(-overscrollX, state.maxX +
      overscrollX).lerp(state.targetX, scrollLerpFactor()
    )
  state.scrollY = state.scrollY.clamp(-overscrollY, state.maxY +
      overscrollY).lerp(state.targetY, scrollLerpFactor()
    )
  if abs(state.scrollX - previousScrollX) > 0.01 or
      abs(state.scrollY - previousScrollY) > 0.01:
    self.markDirty(parent.id)
    self.requestRedrawAfterSafe(0)
  if state.maxX <= 0 and state.dragging == ScrollX:
    state.dragging = NoScroll
  if state.maxY <= 0 and state.dragging == ScrollY:
    state.dragging = NoScroll
  self.scrollStates[parent.id] = state

proc applyScrollOffsets(self: var UI) =
  for parent in self.layout.boxes:
    if parent.id in self.scrollContainers:
      self.updateScrollState(parent)
      let state = self.scrollStates[parent.id]
      var visited: HashSet[WidgetID]
      visited.incl parent.id
      self.shiftDescendants(parent, -state.scrollX, -state.scrollY, visited)

proc clampPolicy(value: float64, policy: WidgetSizePolicy): float64 =
  min(max(value, policy.min), policy.max)

proc directAlignment(child: Widget, parentAlignment: Alignment): Alignment =
  if child.alignSelf == AlignAuto: parentAlignment else: child.alignSelf

proc directLeafWidth(self: UI, widget: Widget): float64 =
  let intrinsic = self.intrinsicByID.getOrDefault(widget.id)
  case widget.widthPolicy.kind
  of WidgetFixed:
    widget.widthPolicy.value
  of WidgetHug, WidgetPrefer:
    widget.widthPolicy.value.clampPolicy(widget.widthPolicy)
  of WidgetFit:
    (if intrinsic.hasWidth: intrinsic.width else: widget.widthPolicy.min).clampPolicy(
      widget.widthPolicy
    )
  of WidgetFill:
    widget.widthPolicy.min

proc directLeafHeight(self: UI, widget: Widget): float64 =
  let intrinsic = self.intrinsicByID.getOrDefault(widget.id)
  case widget.heightPolicy.kind
  of WidgetFixed:
    widget.heightPolicy.value
  of WidgetHug, WidgetPrefer:
    widget.heightPolicy.value.clampPolicy(widget.heightPolicy)
  of WidgetFit:
    (if intrinsic.hasHeight: intrinsic.height else: widget.heightPolicy.min).clampPolicy(
      widget.heightPolicy
    )
  of WidgetFill:
    widget.heightPolicy.min

proc preferredWidth(
  self: UI, widget: Widget, pendingByParent: Table[WidgetID, PendingLayout]
): float64

proc preferredHeight(
  self: UI, widget: Widget, pendingByParent: Table[WidgetID, PendingLayout]
): float64

proc preferredWidth(
    self: UI, widget: Widget, pendingByParent: Table[WidgetID, PendingLayout]
): float64 =
  if widget.widthPolicy.kind != WidgetFit or not pendingByParent.hasKey(widget.id):
    return self.directLeafWidth(widget)

  let pending = pendingByParent[widget.id]
  case pending.kind
  of RowLayout:
    if pending.children.len == 0:
      return widget.widthPolicy.min
    var width =
      pending.padding * 2.0 + pending.gap * max(pending.children.len - 1, 0).toFloat
    for child in pending.children:
      width += self.preferredWidth(child, pendingByParent)
    width.clampPolicy(widget.widthPolicy)
  of ColumnLayout:
    var width = widget.widthPolicy.min
    for child in pending.children:
      width =
        max(width, self.preferredWidth(child, pendingByParent) +
            pending.padding * 2.0)
    width.clampPolicy(widget.widthPolicy)
  of OverlayLayout:
    var width = widget.widthPolicy.min
    for child in pending.children:
      width =
        max(width, self.preferredWidth(child, pendingByParent) +
            pending.padding * 2.0)
    width.clampPolicy(widget.widthPolicy)

proc preferredHeight(
    self: UI, widget: Widget, pendingByParent: Table[WidgetID, PendingLayout]
): float64 =
  if widget.heightPolicy.kind != WidgetFit or not pendingByParent.hasKey(widget.id):
    return self.directLeafHeight(widget)

  let pending = pendingByParent[widget.id]
  case pending.kind
  of RowLayout:
    var height = widget.heightPolicy.min
    for child in pending.children:
      height = max(
        height, self.preferredHeight(child, pendingByParent) + pending.padding * 2.0
      )
    height.clampPolicy(widget.heightPolicy)
  of ColumnLayout:
    if pending.children.len == 0:
      return widget.heightPolicy.min
    var height =
      pending.padding * 2.0 + pending.gap * max(pending.children.len - 1, 0).toFloat
    for child in pending.children:
      height += self.preferredHeight(child, pendingByParent)
    height.clampPolicy(widget.heightPolicy)
  of OverlayLayout:
    var height = widget.heightPolicy.min
    for child in pending.children:
      height = max(
        height, self.preferredHeight(child, pendingByParent) + pending.padding * 2.0
      )
    height.clampPolicy(widget.heightPolicy)

proc assignDirectStack(
    self: UI, pending: PendingLayout, pendingByParent: Table[WidgetID, PendingLayout]
) =
  if pending.children.len == 0:
    return

  let parentFrame = pending.parent.frame
  case pending.kind
  of ColumnLayout:
    let
      availableWidth = max(parentFrame.width - pending.padding * 2.0, 0.0)
      availableHeight = max(parentFrame.height - pending.padding * 2.0, 0.0)
    var fixedHeight = pending.gap * max(pending.children.len - 1, 0).toFloat
    var fillCount = 0
    for child in pending.children:
      if child.heightPolicy.kind == WidgetFill and not pending.scrollY:
        inc fillCount
      else:
        fixedHeight += self.preferredHeight(child, pendingByParent)
    let fillHeight =
      if fillCount > 0:
        max((availableHeight - fixedHeight) / fillCount.toFloat, 0.0)
      else:
        0.0
    let contentHeight = fixedHeight + fillHeight * fillCount.toFloat
    var y =
      case pending.justifyContent
      of JustifyCenter:
        parentFrame.y + (parentFrame.height - contentHeight) / 2.0
      of JustifyEnd:
        parentFrame.y + parentFrame.height - pending.padding - contentHeight
      of JustifyStart:
        parentFrame.y + pending.padding
    for child in pending.children:
      let childHeight =
        if child.heightPolicy.kind == WidgetFill and not pending.scrollY:
          fillHeight.clampPolicy(child.heightPolicy)
        else:
          self.preferredHeight(child, pendingByParent)
      var childWidth =
        if child.widthPolicy.kind == WidgetFill or (
          child.directAlignment(pending.alignItems) == AlignStretch and
          child.stretchWidth
        ):
          availableWidth.clampPolicy(child.widthPolicy)
        else:
          self.preferredWidth(child, pendingByParent)
      childWidth = max(childWidth, 0.0)
      let alignment = child.directAlignment(pending.alignItems)
      let x =
        case alignment
        of AlignCenter:
          parentFrame.x + (parentFrame.width - childWidth) / 2.0
        of AlignEnd:
          parentFrame.x + parentFrame.width - pending.padding - childWidth
        else:
          parentFrame.x + pending.padding
      child.setFrame(Frame(x: x, y: y, width: childWidth, height: childHeight))
      if pendingByParent.hasKey(child.id):
        self.assignDirectStack(pendingByParent[child.id], pendingByParent)
      y += childHeight + pending.gap
  of RowLayout:
    let
      availableWidth = max(parentFrame.width - pending.padding * 2.0, 0.0)
      availableHeight = max(parentFrame.height - pending.padding * 2.0, 0.0)
    var fixedWidth = pending.gap * max(pending.children.len - 1, 0).toFloat
    var fillCount = 0
    for child in pending.children:
      if child.widthPolicy.kind == WidgetFill and not pending.scrollX:
        inc fillCount
      else:
        fixedWidth += self.preferredWidth(child, pendingByParent)
    let fillWidth =
      if fillCount > 0:
        max((availableWidth - fixedWidth) / fillCount.toFloat, 0.0)
      else:
        0.0
    let contentWidth = fixedWidth + fillWidth * fillCount.toFloat
    var x =
      case pending.justifyContent
      of JustifyCenter:
        parentFrame.x + (parentFrame.width - contentWidth) / 2.0
      of JustifyEnd:
        parentFrame.x + parentFrame.width - pending.padding - contentWidth
      of JustifyStart:
        parentFrame.x + pending.padding
    for child in pending.children:
      let childWidth =
        if child.widthPolicy.kind == WidgetFill and not pending.scrollX:
          fillWidth.clampPolicy(child.widthPolicy)
        else:
          self.preferredWidth(child, pendingByParent)
      var childHeight =
        if child.heightPolicy.kind == WidgetFill or (
          child.directAlignment(pending.alignItems) == AlignStretch and
          child.stretchHeight
        ):
          availableHeight.clampPolicy(child.heightPolicy)
        else:
          self.preferredHeight(child, pendingByParent)
      childHeight = max(childHeight, 0.0)
      let alignment = child.directAlignment(pending.alignItems)
      let y =
        case alignment
        of AlignCenter:
          parentFrame.y + (parentFrame.height - childHeight) / 2.0
        of AlignEnd:
          parentFrame.y + parentFrame.height - pending.padding - childHeight
        else:
          parentFrame.y + pending.padding
      child.setFrame(Frame(x: x, y: y, width: childWidth, height: childHeight))
      if pendingByParent.hasKey(child.id):
        self.assignDirectStack(pendingByParent[child.id], pendingByParent)
      x += childWidth + pending.gap
  of OverlayLayout:
    let
      availableWidth = max(parentFrame.width - pending.padding * 2.0, 0.0)
      availableHeight = max(parentFrame.height - pending.padding * 2.0, 0.0)
    for child in pending.children:
      var childWidth =
        if child.widthPolicy.kind == WidgetFill or (
          child.directAlignment(pending.alignItems) == AlignStretch and
          child.stretchWidth
        ):
          availableWidth.clampPolicy(child.widthPolicy)
        else:
          self.preferredWidth(child, pendingByParent)
      childWidth = max(childWidth, 0.0)
      var childHeight =
        if child.heightPolicy.kind == WidgetFill or child.stretchHeight:
          availableHeight.clampPolicy(child.heightPolicy)
        else:
          self.preferredHeight(child, pendingByParent)
      childHeight = max(childHeight, 0.0)
      let alignment = child.directAlignment(pending.alignItems)
      let x =
        case alignment
        of AlignCenter:
          parentFrame.x + (parentFrame.width - childWidth) / 2.0
        of AlignEnd:
          parentFrame.x + parentFrame.width - pending.padding - childWidth
        else:
          parentFrame.x + pending.padding
      let y =
        case pending.justifyContent
        of JustifyCenter:
          parentFrame.y + (parentFrame.height - childHeight) / 2.0
        of JustifyEnd:
          parentFrame.y + parentFrame.height - pending.padding - childHeight
        of JustifyStart:
          parentFrame.y + pending.padding
      child.setFrame(Frame(x: x, y: y, width: childWidth, height: childHeight))
      if pendingByParent.hasKey(child.id):
        self.assignDirectStack(pendingByParent[child.id], pendingByParent)

proc endLayout*(self: var UI): bool {.discardable.} =
  if self.frames.len == 1 and self.frames[0].children.len > 0:
    let children = self.frames[0].children
    self.pendingLayouts.add PendingLayout(
      kind: ColumnLayout,
      parent: self.root,
      children: children,
      gap: 0.0,
      padding: 0.0,
      alignItems: AlignStretch,
      justifyContent: JustifyStart,
      scrollX: false,
      scrollY: false,
    )
    self.frames[0].children.setLen(0)

  var
    parentByID: Table[WidgetID, WidgetID]
    pendingByParent: Table[WidgetID, PendingLayout]
    scrollParentIDs: HashSet[WidgetID]
    directParents: HashSet[WidgetID]

  for pending in self.pendingLayouts:
    pendingByParent[pending.parent.id] = pending
    if pending.scrollX or pending.scrollY:
      scrollParentIDs.incl pending.parent.id
    for child in pending.children:
      parentByID[child.id] = pending.parent.id

  proc hasScrollAncestor(id: WidgetID): bool =
    var current = id
    while parentByID.hasKey(current):
      let parentID = parentByID[current]
      if parentID in scrollParentIDs:
        return true
      current = parentID
    false

  for pending in self.pendingLayouts:
    if pending.scrollX or pending.scrollY:
      directParents.incl pending.parent.id
    elif self.floatingBelowAnchors.hasKey(pending.parent.id):
      directParents.incl pending.parent.id
    elif pending.parent.id in scrollParentIDs or
        pending.parent.id.hasScrollAncestor():
      directParents.incl pending.parent.id

  for i in countdown(self.pendingLayouts.high, 0):
    let pending = self.pendingLayouts[i]
    self.layoutChildren[pending.parent.id] = pending.children
    if pending.scrollX or pending.scrollY:
      self.scrollContainers.incl pending.parent.id
    if pending.parent.id in directParents:
      continue
    case pending.kind
    of RowLayout:
      self.layout.row(
        pending.parent,
        pending.children,
        gap = pending.gap,
        padding = pending.padding,
        alignItems = pending.alignItems,
        justifyContent = pending.justifyContent,
        scrollX = pending.scrollX,
        scrollY = pending.scrollY,
      )
    of ColumnLayout:
      self.layout.column(
        pending.parent,
        pending.children,
        gap = pending.gap,
        padding = pending.padding,
        alignItems = pending.alignItems,
        justifyContent = pending.justifyContent,
        scrollX = pending.scrollX,
        scrollY = pending.scrollY,
      )
    of OverlayLayout:
      self.layout.overlay(
        pending.parent,
        pending.children,
        padding = pending.padding,
        alignItems = pending.alignItems,
        justifyContent = pending.justifyContent,
      )

  result = self.layout.solve()
  if result:
    for box in self.layout.boxes:
      self.liveWidgetIDs.incl box.id
    if self.liveWidgetIDs != self.previousWidgetIDs:
      self.markAllDirty()
      var staleKeys: seq[WidgetID]
      for id in self.renderKeys.keys:
        if id notin self.liveWidgetIDs:
          staleKeys.add id
      for id in staleKeys:
        self.renderKeys.del id
    self.previousWidgetIDs = self.liveWidgetIDs
    for parentID in directParents:
      if pendingByParent.hasKey(parentID):
        if self.floatingBelowAnchors.hasKey(parentID):
          let
            parent = pendingByParent[parentID].parent
            anchorID = self.floatingBelowAnchors[parentID]
            anchor = self.widgetFrame(anchorID)
            rootFrame = self.root.frame
            width = self.preferredWidth(parent, pendingByParent)
            height = self.preferredHeight(parent, pendingByParent)
          var x =
            if anchor.ok:
              anchor.frame.x
            else:
              rootFrame.x
          var y =
            if anchor.ok:
              anchor.frame.y + anchor.frame.height
            else:
              rootFrame.y
          x = min(max(x, rootFrame.x), rootFrame.x + max(rootFrame.width -
              width, 0.0))
          y = min(max(y, rootFrame.y), rootFrame.y + max(rootFrame.height -
              height, 0.0))
          parent.setFrame(Frame(x: x, y: y, width: width, height: height))
          self.assignDirectStack(pendingByParent[parentID], pendingByParent)
        elif parentID in self.scrollContainers:
          self.assignDirectStack(pendingByParent[parentID], pendingByParent)
    self.applyScrollOffsets()
    self.frameByID.clear()
    for box in self.layout.boxes:
      self.frameByID[box.id] = box.frame
    self.pointerBlockFrames.setLen(0)
    for (component, widget) in self.components:
      if component of Interactive or component.style.hasBackground:
        self.pointerBlockFrames.add widget.frame

proc addChild(self: var UI, child: Widget) =
  if self.frames.len == 0:
    self.childrenWidgets.add(child)
  else:
    self.frames[^1].children.add(child)

proc addChildren(self: var UI, children: openArray[Widget]) =
  for child in children:
    self.addChild(child)

proc currentParent(self: UI): Widget =
  if self.frames.len == 0:
    self.parent
  else:
    self.frames[^1].parent

proc currentWidget(self: UI, id: WidgetID): tuple[ok: bool, widget: Widget] =
  for box in self.layout.boxes:
    if box.id == id:
      return (true, box)
  (false, Widget())

proc takeChildren(self: var UI): seq[Widget] =
  if self.frames.len == 0:
    result = self.childrenWidgets
    self.childrenWidgets.setLen(0)
  else:
    result = self.frames[^1].children
    self.frames[^1].children.setLen(0)

proc pushLayout(self: var UI, parent: Widget) =
  self.frames.add LayoutFrame(parent: parent)
  self.parent = parent

proc popLayout(self: var UI): Widget =
  result = self.frames[^1].parent
  self.frames.setLen(self.frames.len - 1)
  self.parent = self.currentParent()
  self.addChild(result)

proc popFloatingLayout(self: var UI): Widget =
  result = self.frames[^1].parent
  self.frames.setLen(self.frames.len - 1)
  self.parent = self.currentParent()

template slot*(self: var UI, body: untyped): WidgetSlot =
  block:
    if self.phase == EventPhase:
      body
      WidgetSlot(@[])
    else:
      self.frames.add LayoutFrame(parent: self.currentParent())
      body
      let captured {.gensym.} = self.frames[^1].children
      self.frames.setLen(self.frames.len - 1)
      self.parent = self.currentParent()
      captured

template singleSlot*(self: var UI, body: untyped): Widget =
  block:
    let captured {.gensym.} = self.slot:
      body
    if captured.len != 1:
      raise newException(
        ValueError, "expected exactly one widget in slot, got " & $captured.len
      )
    captured[0]

proc place*(self: var UI, slot: WidgetSlot) {.layoutOnly.} =
  self.addChildren(slot)

proc place*(self: var UI, widget: Widget) {.layoutOnly.} =
  self.addChild(widget)

proc attach*(self: var UI, widget: Widget,
    component: Component) {.layoutOnly.} =
  self.components.add((component, widget))
  self.componentByID[widget.id] = component

proc applyIntrinsicSizes*(self: UI, resources: Resources) =
  for (component, widget) in self.components:
    if not widget.fitWidth and not widget.fitHeight:
      continue
    let size = component.measure(resources)
    self.intrinsicByID[widget.id] = size
    if widget.fitWidth and size.hasWidth:
      discard self.layout.constrain(widget.width == size.width)
    if widget.fitHeight and size.hasHeight:
      discard self.layout.constrain(widget.height == size.height)

template events*(self: var UI, body: untyped) =
  if self.phase == EventPhase:
    body

proc markStateChanges(
    ui: var UI,
    beforeHot, beforeActive, beforeSubmitted: HashSet[WidgetID],
    beforeFocused: WidgetID,
    updateContext: UpdateContext,
) =
  for id in beforeHot:
    if id notin updateContext.hotWidgets:
      ui.markDirty(id)
  for id in updateContext.hotWidgets:
    if id notin beforeHot:
      ui.markDirty(id)

  for id in beforeActive:
    if id notin updateContext.activeWidgets:
      ui.markDirty(id)
  for id in updateContext.activeWidgets:
    if id notin beforeActive:
      ui.markDirty(id)

  for id in beforeSubmitted:
    if id notin updateContext.submittedWidgets:
      ui.markDirty(id)
  for id in updateContext.submittedWidgets:
    if id notin beforeSubmitted:
      ui.markDirty(id)

  if beforeFocused != updateContext.focusedWidget:
    ui.markDirty(beforeFocused)
    ui.markDirty(updateContext.focusedWidget)

template layout*(
    ui: var UI,
    updateContext: var UpdateContext,
    drawContext: var DrawContext,
    blk: untyped,
): auto =
  # This could totally be done at compile time, the only reason I am
  # avoiding doing that, is I want to allow loading ui from a dynamic module
  let previousDrawCommands {.gensym.} = screen.drawCommands
  let previousCommandMeasureText {.gensym.} = screen.commandMeasureText
  let previousCommandMeasureImage {.gensym.} = screen.commandMeasureImage
  screen.drawCommands = drawContext.drawCommands
  screen.commandMeasureText = drawContext.commandMeasureText
  screen.commandMeasureImage = drawContext.commandMeasureImage
  defer:
    screen.drawCommands = previousDrawCommands
    screen.commandMeasureText = previousCommandMeasureText
    screen.commandMeasureImage = previousCommandMeasureImage

  ui.frameRedrawn = false
  ui.beginEvents(drawContext)
  blk

  ui.phase = LayoutPhase
  var layoutOk {.gensym.} = false
  try:
    ui.beginLayout(drawContext.windowWidth, drawContext.windowHeight)
    blk
    ui.applyIntrinsicSizes(drawContext.resources)
    layoutOk = ui.endLayout()
  except InternalSolverError, UnsatisfiableConstraintError:
    layoutOk = false

  if layoutOk:
    let beforeHot {.gensym.} = drawContext.hotWidgets
    let beforeActive {.gensym.} = drawContext.activeWidgets
    let beforeSubmitted {.gensym.} = drawContext.submittedWidgets
    let beforeFocused {.gensym.} = drawContext.focusedWidget
    updateContext.hotWidgets.clear()
    updateContext.activeWidgets.clear()
    updateContext.resources = drawContext.resources
    updateContext.sliderDragging =
      if updateContext.mouseLeftDown: drawContext.sliderDragging else: InvalidWidgetID
    ui.update(updateContext)
    ui.markStateChanges(
      beforeHot, beforeActive, beforeSubmitted, beforeFocused, updateContext
    )
    switchState(updateContext, drawContext)
    ui.frameRedrawn = ui.draw(drawContext)
    if drawContext.hasRedrawRequest:
      ui.requestRedrawAfterSafe(drawContext.redrawDelayMs)
      drawContext.dirtyAll = true
  else:
    updateContext.hotWidgets.clear()
    updateContext.activeWidgets.clear()
  ui.reset()

template layout*(ui: var UI, blk: untyped): auto =
  let previousDrawCommands {.gensym.} = screen.drawCommands
  let previousCommandMeasureText {.gensym.} = screen.commandMeasureText
  let previousCommandMeasureImage {.gensym.} = screen.commandMeasureImage
  screen.drawCommands = ui.context.draw.drawCommands
  screen.commandMeasureText = ui.context.draw.commandMeasureText
  screen.commandMeasureImage = ui.context.draw.commandMeasureImage
  defer:
    screen.drawCommands = previousDrawCommands
    screen.commandMeasureText = previousCommandMeasureText
    screen.commandMeasureImage = previousCommandMeasureImage

  ui.frameRedrawn = false
  ui.beginEvents(ui.context.draw)
  blk

  ui.phase = LayoutPhase
  var layoutOk {.gensym.} = false
  try:
    ui.beginLayout(ui.context.draw.windowWidth, ui.context.draw.windowHeight)
    blk
    ui.applyIntrinsicSizes(ui.context.draw.resources)
    layoutOk = ui.endLayout()
  except InternalSolverError, UnsatisfiableConstraintError:
    layoutOk = false

  if layoutOk:
    let beforeHot {.gensym.} = ui.context.draw.hotWidgets
    let beforeActive {.gensym.} = ui.context.draw.activeWidgets
    let beforeSubmitted {.gensym.} = ui.context.draw.submittedWidgets
    let beforeFocused {.gensym.} = ui.context.draw.focusedWidget
    ui.context.update.hotWidgets.clear()
    ui.context.update.activeWidgets.clear()
    ui.context.update.resources = ui.context.draw.resources
    ui.context.update.sliderDragging =
      if ui.context.update.mouseLeftDown:
        ui.context.draw.sliderDragging
      else:
        InvalidWidgetID
    ui.update(ui.context.update)
    ui.markStateChanges(
      beforeHot, beforeActive, beforeSubmitted, beforeFocused, ui.context.update
    )
    switchState(ui.context.update, ui.context.draw)
    ui.frameRedrawn = ui.draw(ui.context.draw)
    if ui.context.draw.hasRedrawRequest:
      ui.requestRedrawAfterSafe(ui.context.draw.redrawDelayMs)
      ui.markAllDirty()
  else:
    ui.context.update.hotWidgets.clear()
    ui.context.update.activeWidgets.clear()
  ui.reset()

proc updateScrollbarDrag(self: var UI, parent: Widget,
    context: var UpdateContext) =
  if parent.id notin self.scrollContainers:
    return
  var state = self.scrollStates.getOrDefault(parent.id)
  let
    previousTargetX = state.targetX
    previousTargetY = state.targetY
  let
    overscrollX = overscrollLimit(parent.frame.width)
    overscrollY = overscrollLimit(parent.frame.height)
  if parent.frame.contains(context.mouseX, context.mouseY):
    if state.maxY > 0 and context.mouseWheelY != 0:
      state.targetY = (state.targetY - context.mouseWheelY * scrollWheelStep(
        )).clamp(
        -overscrollY, state.maxY + overscrollY
      )
      context.setActive(parent.id)
    if state.maxX > 0 and context.mouseWheelX != 0:
      state.targetX = (state.targetX - context.mouseWheelX * scrollWheelStep(
        )).clamp(
        -overscrollX, state.maxX + overscrollX
      )
      context.setActive(parent.id)

  if not context.mouseLeftDown:
    state.dragging = NoScroll

  if context.mouseLeftPressed:
    if state.maxY > 0 and
        verticalThumb(parent, state).contains(context.mouseX, context.mouseY):
      state.dragging = ScrollY
      state.dragStartMouse = context.mouseY.toFloat
      state.dragStartScroll = state.targetY
      context.setActive(parent.id)
    elif state.maxX > 0 and
        horizontalThumb(parent, state).contains(context.mouseX, context.mouseY):
      state.dragging = ScrollX
      state.dragStartMouse = context.mouseX.toFloat
      state.dragStartScroll = state.targetX
      context.setActive(parent.id)

  case state.dragging
  of ScrollY:
    let track = verticalTrack(parent)
    let thumb = verticalThumb(parent, state)
    let travel = max(track.height - thumb.height, 1.0)
    state.targetY = (
      state.dragStartScroll +
      (context.mouseY.toFloat - state.dragStartMouse) * state.maxY / travel
    ).clamp(-overscrollY, state.maxY + overscrollY)
    context.setActive(parent.id)
  of ScrollX:
    let track = horizontalTrack(parent)
    let thumb = horizontalThumb(parent, state)
    let travel = max(track.width - thumb.width, 1.0)
    state.targetX = (
      state.dragStartScroll +
      (context.mouseX.toFloat - state.dragStartMouse) * state.maxX / travel
    ).clamp(-overscrollX, state.maxX + overscrollX)
    context.setActive(parent.id)
  of NoScroll:
    discard

  self.scrollStates[parent.id] = state
  if abs(state.targetX - previousTargetX) > 0.01 or
      abs(state.targetY - previousTargetY) > 0.01:
    self.markDirty(parent.id)
    self.requestRedrawAfterSafe(0)

proc updateWidgetTree(
    self: var UI,
    widget: Widget,
    components: Table[WidgetID, Component],
    context: var UpdateContext,
    clipped = false,
) =
  self.updateScrollbarDrag(widget, context)
  if components.hasKey(widget.id):
    components[widget.id].update(widget, context)

  let insideClip =
    (not clipped) or widget.frame.contains(context.mouseX, context.mouseY) or
    context.focused(widget.id)
  let childClipped = clipped or widget.id in self.scrollContainers

  if not insideClip and childClipped:
    return
  for child in self.layoutChildren.getOrDefault(widget.id):
    self.updateWidgetTree(child, components, context, childClipped)

proc update*(self: var UI, context: var UpdateContext) =
  self.updateWidgetTree(self.root, self.componentByID, context)
  for widget in self.floatingWidgets:
    self.updateWidgetTree(widget, self.componentByID, context)

proc draw*(self: UI, context: var DrawContext): bool {.discardable.} =
  if not context.dirtyAll and context.dirtyWidgets.len == 0:
    return false

  var drawContext = context
  let previousDrawCommands = screen.drawCommands
  let previousCommandMeasureImage = screen.commandMeasureImage
  screen.drawCommands = drawContext.drawCommands
  screen.commandMeasureImage = drawContext.commandMeasureImage
  defer:
    screen.drawCommands = previousDrawCommands
    screen.commandMeasureImage = previousCommandMeasureImage

  drawContext.hasRedrawRequest = false
  fillRect(
    rect(0, 0, drawContext.windowWidth, drawContext.windowHeight), color(0, 0, 0, 0)
  )
  drawContext.dirtyAll = true

  proc drawScrollbars(widget: Widget) =
    if widget.id notin self.scrollContainers:
      return
    let state = self.scrollStates.getOrDefault(widget.id)
    if state.maxY > 0:
      let track = verticalTrack(widget)
      let thumb = verticalThumb(widget, state)
      fillRect(
        rect(track.x.toInt, track.y.toInt, track.width.toInt,
            track.height.toInt),
        drawContext.palette.panelMuted,
      )
      fillRect(
        rect(thumb.x.toInt, thumb.y.toInt, thumb.width.toInt,
            thumb.height.toInt),
        drawContext.palette.cardAccent,
      )
    if state.maxX > 0:
      let track = horizontalTrack(widget)
      let thumb = horizontalThumb(widget, state)
      fillRect(
        rect(track.x.toInt, track.y.toInt, track.width.toInt,
            track.height.toInt),
        drawContext.palette.panelMuted,
      )
      fillRect(
        rect(thumb.x.toInt, thumb.y.toInt, thumb.width.toInt,
            thumb.height.toInt),
        drawContext.palette.cardAccent,
      )

  proc drawWidgetTree(widget: Widget, inheritedDirty = false) =
    let dirty =
      drawContext.dirtyAll or inheritedDirty or widget.id in
          drawContext.dirtyWidgets
    if dirty and self.componentByID.hasKey(widget.id):
      self.componentByID[widget.id].draw(widget, drawContext)

    if widget.id in self.scrollContainers:
      let f = widget.frame
      let
        previousHasClip = drawContext.hasClip
        previousClip = drawContext.clipRect
        clip = drawContext.clippedRect(
          rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt)
        )
      drawContext.hasClip = true
      drawContext.clipRect = clip
      saveState()
      setClipRect(clip)
      for child in self.layoutChildren.getOrDefault(widget.id):
        drawWidgetTree(child, dirty)
      restoreState()
      drawContext.hasClip = previousHasClip
      drawContext.clipRect = previousClip
      if dirty:
        drawScrollbars(widget)
    else:
      for child in self.layoutChildren.getOrDefault(widget.id):
        drawWidgetTree(child, dirty)

  drawWidgetTree(self.root)
  for widget in self.floatingWidgets:
    drawWidgetTree(widget, true)
  for (component, widget) in self.components:
    component.drawOverlay(widget, drawContext)
  context.hasRedrawRequest = drawContext.hasRedrawRequest
  context.redrawDelayMs = drawContext.redrawDelayMs
  context.dirtyWidgets.clear()
  context.dirtyAll = false
  true

proc row*(self: var UI, config: BoxConfig) {.layoutOnly.} =
  let components = self.takeChildren()
  self.pendingLayouts.add PendingLayout(
    kind: RowLayout,
    parent: self.currentParent(),
    children: components,
    gap: config.gap,
    padding: config.padding,
    alignItems: config.alignItems,
    justifyContent: config.justifyContent,
    scrollX: config.scrollX,
    scrollY: config.scrollY,
  )

proc column*(self: var UI, config: BoxConfig) {.layoutOnly.} =
  let components = self.takeChildren()
  self.pendingLayouts.add PendingLayout(
    kind: ColumnLayout,
    parent: self.currentParent(),
    children: components,
    gap: config.gap,
    padding: config.padding,
    alignItems: config.alignItems,
    justifyContent: config.justifyContent,
    scrollX: config.scrollX,
    scrollY: config.scrollY,
  )

proc overlay*(self: var UI, config: BoxConfig) {.layoutOnly.} =
  let components = self.takeChildren()
  self.pendingLayouts.add PendingLayout(
    kind: OverlayLayout,
    parent: self.currentParent(),
    children: components,
    gap: config.gap,
    padding: config.padding,
    alignItems: config.alignItems,
    justifyContent: config.justifyContent,
    scrollX: config.scrollX,
    scrollY: config.scrollY,
  )

template row*(self: var UI, config: BoxConfig, body: untyped) =
  block:
    if self.phase == EventPhase:
      body
      discard
    else:
      body
      discard
      self.row(config)

template column*(self: var UI, config: BoxConfig, body: untyped) =
  block:
    if self.phase == EventPhase:
      body
      discard
    else:
      body
      discard
      self.column(config)

template overlay*(self: var UI, config: BoxConfig, body: untyped) =
  block:
    if self.phase == EventPhase:
      body
      discard
    else:
      body
      discard
      self.overlay(config)

template row*(self: var UI, id: WidgetID, config: BoxConfig, body: untyped) =
  block:
    if self.phase == EventPhase:
      body
      discard
    else:
      let layoutParent = self.box(
        id, width = config.width, height = config.height,
        alignSelf = config.alignSelf
      )
      self.setRenderKey(id, renderKey("row", config))
      self.pushLayout(layoutParent)
      body
      discard
      self.row(config)
      discard self.popLayout()

template column*(self: var UI, id: WidgetID, config: BoxConfig, body: untyped) =
  block:
    if self.phase == EventPhase:
      body
      discard
    else:
      let layoutParent = self.box(
        id, width = config.width, height = config.height,
        alignSelf = config.alignSelf
      )
      self.setRenderKey(id, renderKey("column", config))
      self.pushLayout(layoutParent)
      body
      discard
      self.column(config)
      discard self.popLayout()

template overlay*(self: var UI, id: WidgetID, config: BoxConfig,
    body: untyped) =
  block:
    if self.phase == EventPhase:
      body
      discard
    else:
      let layoutParent = self.box(
        id, width = config.width, height = config.height,
        alignSelf = config.alignSelf
      )
      self.setRenderKey(id, renderKey("overlay", config))
      self.pushLayout(layoutParent)
      body
      discard
      self.overlay(config)
      discard self.popLayout()

template center*(self: var UI, id: WidgetID, w = fill(), h = fill(),
    body: untyped) =
  block:
    if self.phase == EventPhase:
      body
      discard
    else:
      let layoutParent = self.box(id, width = w, height = h)
      self.setRenderKey(id, renderKey("center", w, h, AlignAuto))
      self.pushLayout(layoutParent)
      body
      discard
      let captured = self.takeChildren()
      if captured.len != 1:
        raise newException(
          ValueError, "expected exactly one centered widget, got " & $captured.len
        )
      let child = captured[0]
      discard self.layout.constrain(child.left >= layoutParent.left)
      discard self.layout.constrain(child.top >= layoutParent.top)
      discard self.layout.constrain(child.right <= layoutParent.right)
      discard self.layout.constrain(child.bottom <= layoutParent.bottom)
      self.layout.alignCenterX(child, layoutParent)
      self.layout.alignCenterY(child, layoutParent)
      discard self.popLayout()

template panel*(self: var UI, id: WidgetID, config: BoxConfig, body: untyped) =
  block:
    if self.phase == EventPhase:
      body
      discard
    else:
      let layoutParent = self.box(
        id, width = config.width, height = config.height,
        alignSelf = config.alignSelf
      )
      self.setRenderKey(id, renderKey("panel", config))
      let component = Panel.new()
      component.style = config.style
      self.attach(layoutParent, Component(component))
      self.pushLayout(layoutParent)
      body
      discard
      self.column(config)
      discard self.popLayout()

template card*(self: var UI, id: WidgetID, config: BoxConfig, body: untyped) =
  block:
    if self.phase == EventPhase:
      body
      discard
    else:
      let layoutParent = self.box(
        id, width = config.width, height = config.height,
        alignSelf = config.alignSelf
      )
      self.setRenderKey(id, renderKey("card", config))
      let component = Card.new()
      component.style = config.style
      self.attach(layoutParent, Component(component))
      self.pushLayout(layoutParent)
      body
      discard
      self.column(config)
      discard self.popLayout()

template floatingCardBelow*(
    self: var UI, id: WidgetID, anchorID: WidgetID, config: BoxConfig, body: untyped
) =
  block:
    if self.phase == EventPhase:
      body
      discard
    else:
      let floatingID {.gensym.} = id
      let layoutParent {.gensym.} = self.box(
        floatingID,
        width = config.width,
        height = config.height,
        alignSelf = config.alignSelf,
      )
      self.setRenderKey(floatingID, renderKey("floatingCardBelow", config))
      let component {.gensym.} = Card.new()
      component.style = config.style
      self.attach(layoutParent, Component(component))
      self.floatingWidgets.add layoutParent
      self.floatingBelowAnchors[floatingID] = anchorID
      self.pushLayout(layoutParent)
      body
      discard
      self.column(config)
      discard self.popFloatingLayout()

template dialogHeader*(self: var UI, id: WidgetID, config: BoxConfig,
    body: untyped) =
  block:
    if self.phase == EventPhase:
      body
      discard
    else:
      let layoutParent = self.box(
        id, width = config.width, height = config.height,
        alignSelf = config.alignSelf
      )
      self.setRenderKey(id, renderKey("dialogHeader", config))
      let component = DialogHeader.new()
      component.style = config.style
      self.attach(layoutParent, Component(component))
      self.pushLayout(layoutParent)
      body
      discard
      self.row(config)
      discard self.popLayout()

template modalDialog*(
    self: var UI, id: WidgetID, open: bool, config: BoxConfig, body: untyped
) =
  block:
    if open:
      if self.phase == EventPhase:
        body
        discard
      else:
        let layoutParent {.gensym.} = self.box(
          id, width = config.width, height = config.height,
          alignSelf = config.alignSelf
        )
        self.setRenderKey(id, renderKey("modalDialog", config))
        let component {.gensym.} = Card.new()
        component.style = config.style
        self.attach(layoutParent, Component(component))
        discard self.layout.constrain(layoutParent.left >= self.root.left)
        discard self.layout.constrain(layoutParent.top >= self.root.top)
        discard self.layout.constrain(layoutParent.right <= self.root.right)
        discard self.layout.constrain(layoutParent.bottom <= self.root.bottom)
        self.layout.alignCenterX(layoutParent, self.root)
        self.layout.alignCenterY(layoutParent, self.root)
        self.floatingWidgets.add layoutParent
        self.pushLayout(layoutParent)
        body
        discard
        self.column(config)
        discard self.popFloatingLayout()

template menuBar*(self: var UI, id: WidgetID, config: BoxConfig,
    body: untyped) =
  block:
    if self.phase == EventPhase:
      body
      discard
    else:
      let layoutParent = self.box(
        id, width = config.width, height = config.height,
        alignSelf = config.alignSelf
      )
      self.setRenderKey(id, renderKey("menuBar", config))
      let component = Panel.new()
      component.style = config.style
      self.attach(layoutParent, Component(component))
      self.pushLayout(layoutParent)
      body
      discard
      self.row(config)
      discard self.popLayout()

template table*(self: var UI, id: WidgetID, config: BoxConfig, body: untyped) =
  block:
    if self.phase == EventPhase:
      body
      discard
    else:
      let layoutParent = self.box(
        id, width = config.width, height = config.height,
        alignSelf = config.alignSelf
      )
      self.setRenderKey(id, renderKey("table", config))
      let component = TableView.new()
      component.style = config.style
      self.attach(layoutParent, Component(component))
      self.pushLayout(layoutParent)
      body
      discard
      self.column(config)
      discard self.popLayout()

template tableHeader*(self: var UI, id: WidgetID, config: BoxConfig,
    body: untyped) =
  block:
    if self.phase == EventPhase:
      body
      discard
    else:
      let layoutParent = self.box(
        id, width = config.width, height = config.height,
        alignSelf = config.alignSelf
      )
      self.setRenderKey(id, renderKey("tableHeader", config))
      let component = TableHeaderView.new()
      component.style = config.style
      self.attach(layoutParent, Component(component))
      self.pushLayout(layoutParent)
      body
      discard
      self.row(config)
      discard self.popLayout()

template tableRow*(self: var UI, id: WidgetID, config: BoxConfig,
    body: untyped) =
  block:
    if self.phase == EventPhase:
      body
      discard
    else:
      let layoutParent = self.box(
        id, width = config.width, height = config.height,
        alignSelf = config.alignSelf
      )
      self.setRenderKey(id, renderKey("tableRow", config))
      let component = TableRowView.new()
      component.style = config.style
      self.attach(layoutParent, Component(component))
      self.pushLayout(layoutParent)
      body
      discard
      self.row(config)
      discard self.popLayout()

template tableCell*(self: var UI, id: WidgetID, config: BoxConfig,
    body: untyped) =
  block:
    if self.phase == EventPhase:
      body
      discard
    else:
      let layoutParent = self.box(
        id, width = config.width, height = config.height,
        alignSelf = config.alignSelf
      )
      self.setRenderKey(id, renderKey("tableCell", config))
      let component = TableCellView.new()
      component.style = config.style
      self.attach(layoutParent, Component(component))
      self.pushLayout(layoutParent)
      body
      discard
      self.column(config)
      discard self.popLayout()

proc box*(
    self: var UI, id: WidgetID, width, height: SizePolicy, alignSelf = AlignAuto
): Widget =
  self.liveWidgetIDs.incl id
  self.layout.box(id, width = width, height = height).withAlignSelf(alignSelf)

proc container*(
    self: var UI,
    id: WidgetID,
    component: Container,
    width, height: SizePolicy,
    alignSelf = AlignAuto,
): Widget {.discardable, layoutOnly.} =
  result = self.box(id, width = width, height = height, alignSelf = alignSelf)
  self.setRenderKey(id, renderKey("container", width, height, alignSelf))
  self.attach(result, Component(component))
  self.addChild(result)

proc component*(
    self: var UI,
    id: WidgetID,
    component: Component,
    width, height: SizePolicy,
    alignSelf = AlignAuto,
): Widget {.discardable, layoutOnly.} =
  result = self.box(id, width = width, height = height, alignSelf = alignSelf)
  self.setRenderKey(id, renderKey("component", width, height, alignSelf))
  self.attach(result, component)
  self.addChild(result)

proc spacer*(
    self: var UI, id: WidgetID, width, height: SizePolicy, alignSelf = AlignAuto
): Widget {.discardable, layoutOnly.} =
  result = self.box(id, width = width, height = height, alignSelf = alignSelf)
  self.setRenderKey(id, renderKey("spacer", width, height, alignSelf))
  self.addChild(result)

proc button*(
    ui: var UI,
    id: WidgetID,
    label: string,
    width, height: SizePolicy,
    alignSelf = AlignAuto,
    textScroll = false,
    style = ComponentStyle(),
): bool {.discardable.} =
  if ui.phase == EventPhase:
    return ui.clicked(id)
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(
    id,
    renderKey("button:" & label & ":" & $textScroll, width, height, alignSelf) & "|" &
      $style.hasBackground & "|" & $style.background & "|" & $style.hasOpacity &
          "|" &
      $style.opacity,
  )
  if textScroll:
    ui.markDirty(id)
    ui.requestRedrawAfterSafe(33)
  let btn = Button.new(label, textScroll)
  btn.style = style
  ui.attach(box, Component(btn))
  ui.addChild(box)

proc menu*(
    ui: var UI,
    id: WidgetID,
    label: string,
    width, height: SizePolicy,
    alignSelf = AlignAuto,
): bool {.discardable.} =
  if ui.phase == EventPhase:
    return ui.clicked(id)
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(id, renderKey("menu:" & label, width, height, alignSelf))
  ui.attach(box, Component(Menu.new(label)))
  ui.addChild(box)

template menuItem*(self: var UI, id: WidgetID, config: BoxConfig,
    body: untyped) =
  block:
    if self.phase == EventPhase:
      body
      discard
    else:
      let layoutParent = self.box(
        id, width = config.width, height = config.height,
        alignSelf = config.alignSelf
      )
      self.setRenderKey(id, renderKey("menuItem", config))
      let component = MenuItem.new()
      component.style = config.style
      self.attach(layoutParent, Component(component))
      self.pushLayout(layoutParent)
      body
      discard
      self.row(config)
      discard self.popLayout()

proc menuDivider*(
    ui: var UI, id: WidgetID, width, height: SizePolicy, alignSelf = AlignAuto
) {.layoutOnly.} =
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(id, renderKey("menuDivider", width, height, alignSelf))
  ui.attach(box, Component(MenuDivider.new()))
  ui.addChild(box)

proc button*(
    ui: var UI,
    key: string,
    label: string,
    width, height: SizePolicy,
    alignSelf = AlignAuto,
): bool {.discardable.} =
  ui.button(ui.id(key), label, width, height, alignSelf)

proc tabs*(
    ui: var UI,
    id: WidgetID,
    labels: openArray[string],
    selected: var int,
    width = fill(),
    height = fit(),
    alignSelf = AlignAuto,
    gap = 0.0,
    padding = 0.0,
    style = ComponentStyle(),
    tabStyle = TabStyle(),
) =
  if labels.len == 0:
    return
  selected = max(min(selected, labels.len - 1), 0)

  if ui.phase == EventPhase:
    for i, _ in labels:
      if ui.clicked(ui.id(id, "tab", i)):
        selected = i
        ui.markAllDirty()
        ui.requestRedrawAfter(0)
    return

  let layoutParent = ui.box(id, width = width, height = height,
      alignSelf = alignSelf)
  ui.setRenderKey(
    id,
    renderKey("tabs:" & labels.join("|") & ":" & $selected, width, height, alignSelf) &
      "|" & $gap & "|" & $padding & "|" & $style.hasBackground & "|" &
          $style.background & "|" & $style.hasOpacity & "|" & $style.opacity,
  )
  let panel = Panel.new()
  panel.style = style
  ui.attach(layoutParent, Component(panel))
  ui.pushLayout(layoutParent)
  for i, label in labels:
    let tabID = ui.id(id, "tab", i)
    let box = ui.box(tabID, width = fit(), height = fixed(30))
    ui.setRenderKey(tabID, renderKey("tab:" & label & ":" & $(i == selected),
        fit(), fixed(30), AlignAuto))
    ui.attach(box, Component(TabButton.new(label, i == selected, tabStyle)))
    ui.addChild(box)
  ui.row(cfg(width = fill(), height = fit(), gap = gap, padding = padding))
  discard ui.popLayout()

proc label*(
    ui: var UI,
    id: WidgetID,
    text: string,
    width, height: SizePolicy,
    fontName = "font",
    alignSelf = AlignAuto,
    textScroll = false,
) {.layoutOnly.} =
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(
    id,
    renderKey(
      "label:" & text & ":" & fontName & ":" & $textScroll, width, height, alignSelf
    ),
  )
  if textScroll:
    ui.markDirty(id)
    ui.requestRedrawAfterSafe(33)
  let lbl = Label.new(text, fontName, textScroll = textScroll)
  ui.attach(box, Component(lbl))
  ui.addChild(box)

proc checkbox*(
    ui: var UI,
    id: WidgetID,
    label: string,
    checked: bool,
    width, height: SizePolicy,
    fontName = "font",
    alignSelf = AlignAuto,
) {.layoutOnly.} =
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(
    id,
    renderKey(
      "checkbox:" & label & ":" & $checked & ":" & fontName,
      width,
      height,
      alignSelf,
    ),
  )
  ui.attach(box, Component(Checkbox.new(label, checked, fontName)))
  ui.addChild(box)

proc coloredLabel*(
    ui: var UI,
    id: WidgetID,
    text: string,
    color: Color,
    width, height: SizePolicy,
    fontName = "font",
    alignSelf = AlignAuto,
) {.layoutOnly.} =
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(
    id,
    renderKey(
      "coloredLabel:" & text & ":" & fontName & ":" & $color, width, height, alignSelf
    ),
  )
  let lbl = Label.new(text, fontName, color, hasColor = true)
  ui.attach(box, Component(lbl))
  ui.addChild(box)

proc diagnosticLabel*(
    ui: var UI,
    id: WidgetID,
    text: string,
    color: Color,
    width, height: SizePolicy,
    clickable = false,
    fontName = "font",
    alignSelf = AlignAuto,
): bool {.discardable.} =
  if ui.phase == EventPhase:
    return clickable and ui.clicked(id)
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(
    id,
    renderKey(
      "diagnosticLabel:" & text & ":" & fontName & ":" & $color,
      width,
      height,
      alignSelf,
    ),
  )
  let lbl = DiagnosticLabel.new(text, fontName, color, hasColor = true)
  ui.attach(box, Component(lbl))
  ui.addChild(box)

proc image*(
    ui: var UI,
    id: WidgetID,
    path: string,
    width, height: SizePolicy,
    alignSelf = AlignAuto,
) {.layoutOnly.} =
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(id, renderKey("image:" & path, width, height, alignSelf))
  let img = ImageView.new(path)
  ui.attach(box, Component(img))
  ui.addChild(box)

proc image*(
    ui: var UI,
    id: WidgetID,
    path: string,
    source: Rect,
    width, height: SizePolicy,
    alignSelf = AlignAuto,
) {.layoutOnly.} =
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(id, renderKey("image:" & path & ":" & $source, width, height, alignSelf))
  let img = ImageView.new(path, source)
  ui.attach(box, Component(img))
  ui.addChild(box)

proc imageButton*(
    ui: var UI,
    id: WidgetID,
    path: string,
    width, height: SizePolicy,
    alignSelf = AlignAuto,
    style = ComponentStyle(),
): bool {.discardable.} =
  if ui.phase == EventPhase:
    return ui.clicked(id)
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(
    id,
    renderKey("imageButton:" & path, width, height, alignSelf) & "|" &
      $style.hasBackground & "|" & $style.background & "|" & $style.hasOpacity &
          "|" &
      $style.opacity,
  )
  let img = ImageButton.new(path)
  img.style = style
  ui.attach(box, Component(img))
  ui.addChild(box)

proc imageButton*(
    ui: var UI,
    id: WidgetID,
    path: string,
    source: Rect,
    width, height: SizePolicy,
    alignSelf = AlignAuto,
    style = ComponentStyle(),
): bool {.discardable.} =
  if ui.phase == EventPhase:
    return ui.clicked(id)
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(
    id,
    renderKey("imageButton:" & path & ":" & $source, width, height, alignSelf) &
      "|" & $style.hasBackground & "|" & $style.background & "|" &
      $style.hasOpacity & "|" & $style.opacity,
  )
  let img = ImageButton.new(path, source)
  img.style = style
  ui.attach(box, Component(img))
  ui.addChild(box)

proc mesh2d*(
    ui: var UI,
    id: WidgetID,
    state: var Mesh2DState,
    imagePath: string,
    width, height: SizePolicy,
    alignSelf = AlignAuto,
): bool {.discardable.} =
  if ui.phase == EventPhase:
    result = ui.submitted(id)
    if result:
      state.changed = false
    return
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(id, renderKey("mesh2d:" & imagePath & ":" & $state,
      width, height, alignSelf))
  let editor = Mesh2DEditor.new(state, imagePath)
  ui.attach(box, Component(editor))
  ui.addChild(box)

proc slider*(
    ui: var UI,
    id: WidgetID,
    value, minimum, maximum: float64,
    width, height: SizePolicy,
    orientation = SliderHorizontal,
    alignSelf = AlignAuto,
): tuple[active: bool, value: float64] {.discardable.} =
  if ui.phase == EventPhase:
    let located = ui.widgetFrame(id)
    if located.ok:
      let
        f = located.frame
        hot =
          ui.context.update.mouseX.toFloat >= f.x and
          ui.context.update.mouseX.toFloat < f.x + f.width and
          ui.context.update.mouseY.toFloat >= f.y and
          ui.context.update.mouseY.toFloat < f.y + f.height
        dragging = ui.context.draw.sliderDragging == id
      if (ui.context.update.mouseLeftDown and (hot or ui.active(id) or
          dragging)) or ((not ui.context.update.mouseLeftDown) and dragging):
        let value = sliderValueFromMouse(
          f, ui.context.update.mouseX, ui.context.update.mouseY, minimum,
          maximum,
          orientation,
        )
        ui.context.draw.sliderValues[id] = value
        ui.context.draw.sliderDragging = id
        ui.context.update.sliderValues[id] = value
        ui.context.update.sliderDragging = id
        ui.markDirty(id)
        return (true, value)
    return ui.sliderValue(id)
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  let drawValue =
    if ui.context.draw.sliderValues.hasKey(id):
      ui.context.draw.sliderValues[id]
    else:
      value
  ui.setRenderKey(
    id,
    renderKey(
      "slider:" & $drawValue & ":" & $minimum & ":" & $maximum & ":" &
      $orientation,
      width,
      height,
      alignSelf,
    ),
  )
  let view = Slider.new(drawValue, minimum, maximum, orientation)
  ui.attach(box, Component(view))
  ui.addChild(box)

proc comboboxPopupIndex(
    field: Frame,
    optionCount: int,
    optionHeight: float64,
    windowHeight, mouseX, mouseY: int,
): int =
  if optionCount <= 0 or optionHeight <= 0.0:
    return -1
  let
    popupHeight = optionCount.float64 * optionHeight
    belowY = field.y + field.height
    aboveY = field.y - popupHeight
    popupY =
      if belowY + popupHeight <= windowHeight.float64 or aboveY < 0.0:
        belowY
      else:
        aboveY
    inside =
      mouseX.float64 >= field.x and mouseX.float64 < field.x + field.width and
      mouseY.float64 >= popupY and mouseY.float64 < popupY + popupHeight
  if inside:
    result = ((mouseY.float64 - popupY) / optionHeight).int
    if result < 0 or result >= optionCount:
      result = -1
  else:
    result = -1

proc combobox*(
    ui: var UI,
    id: WidgetID,
    selected: int,
    options: openArray[string],
    width, height: SizePolicy,
    alignSelf = AlignAuto,
): tuple[changed: bool, index: int] {.discardable.} =
  result.index = selected
  if options.len == 0:
    return

  let clampedSelected = selected.clamp(0, options.len - 1)

  if ui.phase == EventPhase:
    let open = ui.context.draw.focusedWidget == id
    if open:
      let located = ui.widgetFrame(id)
      if located.ok and ui.context.update.mouseLeftPressed:
        let
          f = located.frame
          inField =
            ui.context.update.mouseX.float64 >= f.x and
            ui.context.update.mouseX.float64 < f.x + f.width and
            ui.context.update.mouseY.float64 >= f.y and
            ui.context.update.mouseY.float64 < f.y + f.height
          optionIndex = comboboxPopupIndex(
            f, options.len, height.value, ui.windowHeight,
            ui.context.update.mouseX,
            ui.context.update.mouseY,
          )
        ui.eventActiveWidgets.clear()
        ui.eventSubmittedWidgets.clear()
        ui.context.draw.activeWidgets.clear()
        ui.context.draw.submittedWidgets.clear()
        if optionIndex >= 0:
          ui.context.draw.focusedWidget = InvalidWidgetID
          ui.eventFocusedWidget = InvalidWidgetID
          return (optionIndex != clampedSelected, optionIndex)
        elif not inField:
          ui.context.draw.focusedWidget = InvalidWidgetID
          ui.eventFocusedWidget = InvalidWidgetID
    return

  let open = ui.context.draw.focusedWidget == id
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(
    id,
    renderKey(
      "combobox:" & options[clampedSelected] & ":" & $open & ":" & $options.len,
      width,
      height,
      alignSelf,
    ),
  )
  ui.attach(
    box,
    Component(
      ComboBox.new(
        options[clampedSelected], options, clampedSelected, open,
            height.value.int
    )
  ),
  )
  ui.addChild(box)
  if open:
    ui.markDirty(id)
    ui.requestRedrawAfterSafe(16)

proc lineInput*(
    ui: var UI,
    id: WidgetID,
    state: LineInputState,
    width, height: SizePolicy,
    fontName = "font",
    alignSelf = AlignAuto,
) =
  if ui.phase == EventPhase:
    return
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(
    id, renderKey("lineInput:" & state.text & ":" & fontName, width, height, alignSelf)
  )
  let input = LineInput.new(state, fontName)
  ui.attach(box, Component(input))
  ui.addChild(box)

proc textEditor*(
    ui: var UI,
    id: WidgetID,
    state: EditorState,
    width, height: SizePolicy,
    fontName = "font",
    alignSelf = AlignAuto,
    lineNumbers = false,
    scrollbars = true,
    syntax = "",
    gutterMarkers: HashSet[int] = initHashSet[int](),
    activeLine = 0,
) {.layoutOnly.} =
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(
    id,
    renderKey(
      "textEditor:" & state.text & ":" & $state.cursor & ":" & fontName & ":" &
        $lineNumbers & ":" & $scrollbars & ":" & syntax & ":" & $gutterMarkers &
        ":" & $activeLine,
      width,
      height,
      alignSelf,
    ),
  )
  ui.attach(
    box,
    Component(
      Editor.new(
        state,
        fontName,
        singleLine = false,
        lineNumbers = lineNumbers,
        scrollbars = scrollbars,
        syntax = syntax,
        gutterMarkers = gutterMarkers,
        activeLine = activeLine,
    )
  ),
  )
  ui.addChild(box)
