import std/[json, math, macros, os, osproc, sets, strutils, tables]

import layouts, animations, components, coords, palette, resources, widgets2
export layouts, components
export animations
import nest/screen

const
  TooltipDelayMs = 250
  TooltipCursorInset = 4

var redrawTraceCounts = initTable[string, int]()

proc redrawTraceEnabled(): bool =
  getEnv("NEST_REDRAW_TRACE").normalize in ["1", "true", "yes", "on"]

proc traceRedrawRequest(ms, ticks: int,
    loc: tuple[filename: string, line: int, column: int]) =
  if not redrawTraceEnabled():
    return
  let key = loc.filename & ":" & $loc.line & ":" & $loc.column & ":" & $ms
  let count = redrawTraceCounts.getOrDefault(key) + 1
  redrawTraceCounts[key] = count
  if count <= 5 or count mod 60 == 0:
    echo "[nest redraw trace] " & loc.filename & ":" & $loc.line & ":" &
      $loc.column & " ms=" & $ms & " targetTicks=" & $ticks & " count=" & $count

type
  ComponentWidget = tuple[component: Component, widget: Widget]
  WidgetSlot* = seq[Widget]
  PopoverProcess = ref object
    process: Process
    resultPath: string
    key: string
  LayoutKind = enum
    RowLayout
    ColumnLayout
    OverlayLayout

  ButtonVariant* = enum
    ButtonNormal
    ButtonSmall
    ButtonLarge
    ButtonIcon

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

  AnimationState = object
    target: bool
    startProgress: float64
    startTicks: int
    spec: AnimationSpec
    value: AnimationValue

  BoxConfig* = object
    width*, height*: SizePolicy
    gap*: float64
    padding*: EdgeInsets
    alignItems*: Alignment
    justifyContent*: Justification
    alignSelf*: Alignment
    scrollX*, scrollY*: bool
    scrollWheel*: bool
    dismissOnClickaway*: bool
    textScroll*: bool
    lineNumbers*: bool
    scrollbars*: bool
    readOnly*: bool
    gutterMarkers*: HashSet[int]
    activeLine*: int
    fontName*: string
    fontSize*: int
    buttonPadding*: EdgeInsets
    buttonBorderStyle*: ButtonBorderStyle
    buttonChromeStyle*: ButtonChromeStyle
    buttonTextAlign*: Justification
    syntax*: string
    style*: ComponentStyle

  PendingLayout = object
    kind: LayoutKind
    parent: Widget
    children: seq[Widget]
    gap: float64
    padding: EdgeInsets
    alignItems: Alignment
    justifyContent: Justification
    scrollX, scrollY: bool
    scrollWheel: bool

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
    centeredFloatingWidgets: HashSet[WidgetID]
    componentByID: Table[WidgetID, Component]
    retainedRoot: Widget
    retainedComponents: seq[ComponentWidget]
    retainedComponentByID: Table[WidgetID, Component]
    retainedLayoutChildren: Table[WidgetID, seq[Widget]]
    retainedFloatingWidgets: seq[Widget]
    retainedScrollContainers: HashSet[WidgetID]
    retainedScrollWheelContainers: HashSet[WidgetID]
    retainedFrameValid: bool
    retainedRealtimeWidgets: Table[WidgetID, ComponentWidget]
    forceNextFullRedraw: bool
    intrinsicByID: TableRef[WidgetID, IntrinsicSize]
    pendingLayouts: seq[PendingLayout]
    layoutChildren: Table[WidgetID, seq[Widget]]
    scrollStates: Table[WidgetID, ScrollState]
    animations: Table[WidgetID, AnimationState]
    liveAnimationIDs: HashSet[WidgetID]
    scrollContainers: HashSet[WidgetID]
    scrollWheelContainers: HashSet[WidgetID]
    frameByID: Table[WidgetID, Frame]
    dialogResults: Table[string, string]
    liveWidgetIDs: HashSet[WidgetID]
    previousWidgetIDs: HashSet[WidgetID]
    liveRealtimeWidgetIDs: HashSet[WidgetID]
    pointerBlockFrames: seq[Frame]
    pointerInteractiveFrames: seq[Frame]
    renderKeys: Table[WidgetID, string]
    idScopes: seq[string]
    eventActiveWidgets: HashSet[WidgetID]
    eventSubmittedWidgets: HashSet[WidgetID]
    eventFocusedWidget: WidgetID
    tooltipProcess: PopoverProcess
    tooltipTexts: Table[WidgetID, string]
    tooltipHoverID: WidgetID
    tooltipHoverText: string
    tooltipHoverSince: int
    choicePopovers: Table[WidgetID, PopoverProcess]
    pointerSurfaceWidget: WidgetID
    pointerSurfaceIDs: HashSet[WidgetID]
    modalWidgets: HashSet[WidgetID]
    retainedModalWidgets: HashSet[WidgetID]
    windowDragHandle: WidgetID
    windowDragLastX, windowDragLastY: int
    resizeDragHandle: WidgetID
    resizeDragLastX, resizeDragLastY: int
    scheduledRedrawTicks: int
    hasScheduledRedraw: bool
    inputPending: bool
    fullRenderInputPending: bool
    windowFocused: bool
    windowMouseInside: bool
    windowAutoDismissArmed: bool
    windowInactiveSince: int
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

  UIDriverRelays* = object
    containerConfig*: proc(): BoxConfig {.raises: [].}
    leafConfig*: proc(): BoxConfig {.raises: [].}
    menuDividerConfig*: proc(): BoxConfig {.raises: [].}
    tabsConfig*: proc(): BoxConfig {.raises: [].}
    sliderConfig*: proc(): BoxConfig {.raises: [].}
    lineInputConfig*: proc(): BoxConfig {.raises: [].}
    editorConfig*: proc(): BoxConfig {.raises: [].}

macro layoutOnly*(definition: untyped): untyped =
  ## Pragma macro that turns a routine into a no-op during the event phase.
  ##
  ## A frame's declarations run twice, once to dispatch events and once to
  ## build the widget tree, so anything that only builds widgets carries this
  ## pragma and returns early while events are being dispatched. The routine
  ## must take a `UI` as its first parameter.
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
    paddingLeft = NaN,
    paddingTop = NaN,
    paddingRight = NaN,
    paddingBottom = NaN,
    alignItems = AlignStretch,
    justifyContent = JustifyStart,
    alignSelf = AlignAuto,
    scrollX = false,
    scrollY = false,
    scrollWheel = true,
    dismissOnClickaway = true,
    textScroll = false,
    lineNumbers = false,
    scrollbars = true,
    readOnly = false,
    gutterMarkers: HashSet[int] = initHashSet[int](),
    activeLine = 0,
    fontName = "font",
    fontSize = 0,
    buttonPadding = -1.0,
    buttonBorderStyle = ButtonBorderLine,
    buttonChromeStyle = ButtonChromeRaised,
    buttonTextAlign = JustifyCenter,
    syntax = "",
    style = ComponentStyle(),
    cornerStyle = FlatCorners,
    radius = 0.0,
    radiusTopLeft = NaN,
    radiusTopRight = NaN,
    radiusBottomRight = NaN,
    radiusBottomLeft = NaN,
    shadow = false,
    shadowColor = color(0, 0, 0, 96),
    shadowOffsetX = 0.0,
    shadowOffsetY = 3.0,
    shadowBlur = 8.0,
    shadowSpread = 0.0,
): BoxConfig =
  ## Build the configuration shared by Nest's box widgets.
  ##
  ## `width` and `height` are size policies, `gap` separates children, and
  ## `padding` insets the content on every edge; `paddingLeft` and its
  ## siblings override single edges and default to unset. `alignItems` and
  ## `justifyContent` place the children, and `alignSelf` places the box
  ## itself in its parent. `scrollX`, `scrollY`, `scrollbars`, and `scrollWheel`
  ## control scrolling, `textScroll`, `lineNumbers`, `gutterMarkers`,
  ## `activeLine` and `syntax` configure text widgets, `fontName` and
  ## `fontSize` pick the font, `buttonPadding` overrides the padding inside
  ## buttons, and `style` carries an explicit background or opacity.
  var resolvedPadding = insets(padding)
  if paddingLeft == paddingLeft:
    resolvedPadding.left = paddingLeft
  if paddingTop == paddingTop:
    resolvedPadding.top = paddingTop
  if paddingRight == paddingRight:
    resolvedPadding.right = paddingRight
  if paddingBottom == paddingBottom:
    resolvedPadding.bottom = paddingBottom
  var resolvedStyle = style
  resolvedStyle.cornerStyle = cornerStyle
  resolvedStyle.cornerRadii = radii(radius)
  if radiusTopLeft == radiusTopLeft:
    resolvedStyle.cornerRadii.topLeft = radiusTopLeft
  if radiusTopRight == radiusTopRight:
    resolvedStyle.cornerRadii.topRight = radiusTopRight
  if radiusBottomRight == radiusBottomRight:
    resolvedStyle.cornerRadii.bottomRight = radiusBottomRight
  if radiusBottomLeft == radiusBottomLeft:
    resolvedStyle.cornerRadii.bottomLeft = radiusBottomLeft
  if shadow:
    resolvedStyle.hasShadow = true
    resolvedStyle.shadowColor = shadowColor
    resolvedStyle.shadowOffsetX = shadowOffsetX
    resolvedStyle.shadowOffsetY = shadowOffsetY
    resolvedStyle.shadowBlur = shadowBlur
    resolvedStyle.shadowSpread = shadowSpread
  BoxConfig(
    width: width,
    height: height,
    gap: gap,
    padding: resolvedPadding,
    alignItems: alignItems,
    justifyContent: justifyContent,
    alignSelf: alignSelf,
    scrollX: scrollX,
    scrollY: scrollY,
    scrollWheel: scrollWheel,
    dismissOnClickaway: dismissOnClickaway,
    textScroll: textScroll,
    lineNumbers: lineNumbers,
    scrollbars: scrollbars,
    readOnly: readOnly,
    gutterMarkers: gutterMarkers,
    activeLine: activeLine,
    fontName: fontName,
    fontSize: fontSize,
    buttonPadding: insets(buttonPadding),
    buttonBorderStyle: buttonBorderStyle,
    buttonChromeStyle: buttonChromeStyle,
    buttonTextAlign: buttonTextAlign,
    syntax: syntax,
    style: resolvedStyle,
  )

proc applyButtonVariant*(config: BoxConfig, variant: ButtonVariant): BoxConfig =
  ## Return `config` with Nest's shared button sizing and chrome variant.
  result = config
  case variant
  of ButtonNormal:
    result.buttonPadding = insets(-1.0)
    result.buttonBorderStyle = ButtonBorderLine
    result.buttonChromeStyle = ButtonChromeRaised
  of ButtonSmall:
    result.buttonPadding = insets(6, 2, 6, 2)
    result.buttonBorderStyle = ButtonBorderLine
    result.buttonChromeStyle = ButtonChromeRaised
  of ButtonLarge:
    result.buttonPadding = insets(12, 5, 12, 5)
    result.buttonBorderStyle = ButtonBorderLine
    result.buttonChromeStyle = ButtonChromeRaised
  of ButtonIcon:
    result.buttonPadding = insets(0)
    result.buttonBorderStyle = ButtonBorderNone
    result.buttonChromeStyle = ButtonChromeFlat
    result.style.hasBackground = true
    result.style.background = color(0, 0, 0, 0)
    result.style.hasShadow = true
    result.style.shadowColor = color(0, 0, 0, 120)
    result.style.shadowOffsetY = 2
    result.style.shadowBlur = 5

proc buttonConfig*(variant = ButtonNormal): BoxConfig =
  ## Return a fit-sized button config for `variant`.
  cfg(width = fit(), height = fit()).applyButtonVariant(variant)

proc normalButtonConfig*(): BoxConfig =
  buttonConfig(ButtonNormal)

proc smallButtonConfig*(): BoxConfig =
  buttonConfig(ButtonSmall)

proc largeButtonConfig*(): BoxConfig =
  buttonConfig(ButtonLarge)

proc iconButtonConfig*(): BoxConfig =
  buttonConfig(ButtonIcon)

proc defaultUIDriverRelays*(): UIDriverRelays =
  ## Return the UI declaration defaults shared by language drivers.
  ##
  ## Nim's native procs expose the same defaults in their signatures; script
  ## drivers use this relay table so missing attributes resolve identically.
  UIDriverRelays(
    containerConfig: proc(): BoxConfig = cfg(),
    leafConfig: proc(): BoxConfig = cfg(width = fit(), height = fit()),
    menuDividerConfig: proc(): BoxConfig = cfg(width = fill(), height = fit()),
    tabsConfig: proc(): BoxConfig = cfg(width = fill(), height = fit()),
    sliderConfig: proc(): BoxConfig = cfg(width = fill(min = 120), height = fit()),
    lineInputConfig: proc(): BoxConfig = cfg(width = fill(min = 160),
        height = fit()),
    editorConfig: proc(): BoxConfig = cfg(width = fill(min = 240),
        height = fill(min = 160)),
  )

var uiDriverRelays* = defaultUIDriverRelays()

proc withBackground*(config: BoxConfig, background: Color): BoxConfig =
  ## Return `config` with `background` as its explicit background colour.
  result = config
  result.style.hasBackground = true
  result.style.background = background

proc withOpacity*(config: BoxConfig, opacity: float64): BoxConfig =
  ## Return `config` with `opacity` applied to what it draws.
  result = config
  result.style.hasOpacity = true
  result.style.opacity = opacity

proc withCornerStyle*(config: BoxConfig, style: CornerStyle): BoxConfig =
  ## Return `config` with `style` controlling whether corners are flat or rounded.
  result = config
  result.style.cornerStyle = style

proc withRadius*(config: BoxConfig, radius: float64): BoxConfig =
  ## Return `config` with one radius applied to every corner.
  result = config
  result.style.cornerRadii = radii(radius)

proc withRadii*(
    config: BoxConfig,
    topLeft, topRight, bottomRight, bottomLeft: float64,
): BoxConfig =
  ## Return `config` with an independent radius for each corner.
  result = config
  result.style.cornerRadii = CornerRadii(
    topLeft: topLeft,
    topRight: topRight,
    bottomRight: bottomRight,
    bottomLeft: bottomLeft,
  )

proc withShadow*(
    config: BoxConfig,
    shadowColor = color(0, 0, 0, 96),
    offsetX = 0.0,
    offsetY = 3.0,
    blur = 8.0,
    spread = 0.0,
): BoxConfig =
  ## Return `config` with an outer shadow.
  result = config
  result.style.hasShadow = true
  result.style.shadowColor = shadowColor
  result.style.shadowOffsetX = offsetX
  result.style.shadowOffsetY = offsetY
  result.style.shadowBlur = blur
  result.style.shadowSpread = spread

proc init*(T: typedesc[UI]): T =
  ## Create an empty UI: a fresh layout whose root fills the window, the
  ## default palette and an empty resource cache.
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
    windowFocused: true,
    windowMouseInside: false,
  )

proc setTheme*(self: var UI; themeName: string) =
  ## Select the palette the UI draws with, by theme name.
  self.themeName = themeName
  self.context.draw.palette = Palette.init(themeName)

proc initContext*(self: var UI, windowWidth, windowHeight: int) =
  ## Set the window size the UI lays out against, and load the palette.
  ##
  ## Call this once the window exists, before the first frame.
  self.context.update.windowWidth = windowWidth
  self.context.update.windowHeight = windowHeight
  self.context.draw.windowWidth = windowWidth
  self.context.draw.windowHeight = windowHeight
  self.context.draw.palette = Palette.init(self.themeName)

proc resources*(self: UI): Resources =
  ## Return the font and image cache shared by the UI's widgets.
  self.context.draw.resources

proc palette*(self: UI): Palette =
  ## Return the palette the UI is drawing with.
  self.context.draw.palette

proc font*(self: UI, name = "font"): screen.Font =
  ## Return the backend handle of the font registered as `name`.
  let (font, _) = self.context.draw.resources.get(name)
  screen.Font(font)

proc loadFont*(self: UI, name, path: string, size: Positive) =
  ## Load the font at `path` at `size` and register it as `name`.
  self.context.draw.resources.loadFont(name, path, size)

proc fontAtSize*(self: var UI, name: string, size: int): string =
  ## Return the name of the font `name` rendered at `size`, loading that size
  ## if it is not cached yet.
  ##
  ## The returned name can be passed as a `fontName` to any widget.
  self.context.draw.resources.fontAtSize(name, size)

proc windowWidth*(self: UI): int =
  ## Return the window width the UI is laying out against.
  self.context.draw.windowWidth

proc windowHeight*(self: UI): int =
  ## Return the window height the UI is laying out against.
  self.context.draw.windowHeight

proc widgetFrame*(
    self: UI, id: WidgetID
): tuple[ok: bool, frame: Frame] {.raises: [].} =
  ## Return the solved frame of the widget with `id`.
  ##
  ## `ok` is false, and the frame empty, when no widget in the current frame
  ## has that id.
  try:
    if self.frameByID.hasKey(id):
      return (true, self.frameByID[id])
  except KeyError:
    discard
  for box in self.layout.boxes:
    if box.id == id:
      return (true, box.frame)
  (false, Frame())

proc scrollOffset*(self: UI, id: WidgetID): tuple[x, y: float64] {.raises: [].} =
  ## Return the retained scroll offset for a scroll container.
  let state = self.scrollStates.getOrDefault(id)
  (state.scrollX, state.scrollY)

proc pointerInputBlocked*(self: UI, x, y: int): bool {.raises: [].} =
  ## Test whether the point `x`, `y` lands on a surface that swallows pointer
  ## input, such as an open menu or a floating card.
  for frame in self.pointerBlockFrames:
    if x.toFloat >= frame.x and x.toFloat < frame.x + frame.width and
        y.toFloat >= frame.y and y.toFloat < frame.y + frame.height:
      return true

proc pointerOverUi*(self: UI, x, y: int): bool {.raises: [].} =
  ## Test whether the point `x`, `y` lands on the UI rather than on what is
  ## behind it. Equivalent to `pointerInputBlocked`.
  self.pointerInputBlocked(x, y)

proc pointerOverInteractive*(self: UI, x, y: int): bool {.raises: [].} =
  ## Test whether the point `x`, `y` lands on an interactive widget, so a
  ## host application can leave that input to the UI.
  for frame in self.pointerInteractiveFrames:
    if x.toFloat >= frame.x and x.toFloat < frame.x + frame.width and
        y.toFloat >= frame.y and y.toFloat < frame.y + frame.height:
      return true

proc wantsTextInput*(self: UI): bool =
  ## Test whether a widget holds keyboard focus, which is when the backend
  ## should be asked for text input.
  self.context.draw.focusedWidget != InvalidWidgetID

proc requestRedrawAfter*(self: var UI, ms: int,
    loc: tuple[filename: string, line: int, column: int] = instantiationInfo()) =
  ## Ask for another frame in at most `ms` milliseconds.
  ##
  ## The soonest outstanding request wins, so an animation can keep asking
  ## for the next frame without postponing a sooner one.
  let now =
    if self.context.draw.ticks > 0:
      self.context.draw.ticks
    else:
      input.getTicks()
  let ticks = now + max(ms, 0)
  if not self.hasScheduledRedraw or ticks < self.scheduledRedrawTicks:
    self.scheduledRedrawTicks = ticks
    self.hasScheduledRedraw = true
    traceRedrawRequest(ms, ticks, loc)

proc requestFullRedrawAfter*(self: var UI, ms: int,
    loc: tuple[filename: string, line: int, column: int] = instantiationInfo()) =
  ## Ask for another full application frame in at most `ms` milliseconds.
  self.forceNextFullRedraw = true
  self.requestRedrawAfter(ms, loc)

proc requestRedrawAfterSafe(self: var UI, ms: int,
    loc: tuple[filename: string, line: int, column: int] = instantiationInfo()) {.raises: [].} =
  try:
    self.requestRedrawAfter(ms, loc)
  except Exception:
    discard

proc nowTicks(self: UI): int {.raises: [].} =
  if self.context.draw.ticks > 0:
    self.context.draw.ticks
  else:
    try:
      input.getTicks()
    except Exception:
      0

proc currentAnimationValue(state: AnimationState, now: int): AnimationValue =
  let duration = max(state.spec.durationMs, 1)
  let elapsed = max(now - state.startTicks, 0).float64 / duration.float64
  let targetProgress = if state.target: 1.0 else: 0.0
  let raw = state.startProgress +
    (targetProgress - state.startProgress) * elapsed.clamp(0.0, 1.0)
  result = state.spec.valueAt(raw, elapsed < 1.0)

proc animate*(
    self: var UI,
    id: WidgetID,
    open = true,
    spec = dialogPopIn(),
): AnimationValue {.discardable.} =
  ## Attach an immediate-mode animation to `id` and return this frame's value.
  ##
  ## Call this every frame the widget is declared. The animation is keyed by
  ## `id`, so a widget can be rebuilt by the immediate-mode pass while its
  ## progress is retained in the UI.
  if id == InvalidWidgetID:
    return spec.valueAt(if open: 1.0 else: 0.0)
  self.liveAnimationIDs.incl id
  let now = self.nowTicks()
  var state = self.animations.getOrDefault(id)
  if id notin self.animations:
    state = AnimationState(
      target: open,
      startProgress: if open: 0.0 else: 1.0,
      startTicks: now,
      spec: spec,
    )
  elif state.target != open or state.spec != spec:
    state.startProgress = state.currentAnimationValue(now).progress
    state.startTicks = now
    state.target = open
    state.spec = spec
  state.value = state.currentAnimationValue(now)
  self.animations[id] = state
  if state.value.running:
    self.context.draw.dirtyAll = true
    self.requestRedrawAfterSafe(16)
  state.value

proc animationValue*(self: UI, id: WidgetID): AnimationValue {.raises: [].} =
  ## Return the latest animation value for `id`, or an identity transform.
  result = self.animations.getOrDefault(id).value
  if result.scale <= 0.0 and result.opacity <= 0.0 and result.progress <= 0.0:
    result = AnimationValue(progress: 1.0, opacity: 1.0, scale: 1.0)

proc hasRunningAnimations*(self: UI): bool {.raises: [].} =
  ## Test whether any retained animation is still moving.
  for state in self.animations.values:
    if state.value.running:
      return true

proc advanceAnimations(self: var UI) {.raises: [].} =
  ## Refresh retained animation values before replaying a cached frame.
  ##
  ## Owl apps often repaint retained frames between full evaluations. Without
  ## this, an animation advances only on frames that rebuild the whole widget
  ## tree, which makes popovers appear to freeze mid-transition.
  if self.animations.len == 0:
    return
  let now = self.nowTicks()
  for id, state in self.animations.mpairs:
    state.value = state.currentAnimationValue(now)
    if state.value.running:
      self.context.draw.dirtyAll = true
      self.requestRedrawAfterSafe(16)

proc redrawDelayMs*(self: UI): int =
  ## Return the milliseconds until the scheduled redraw, or -1 when none is
  ## scheduled.
  if not self.hasScheduledRedraw:
    return -1
  max(self.scheduledRedrawTicks - input.getTicks(), 0)

proc clearRedrawRequest*(self: var UI) {.raises: [].} =
  ## Forget the scheduled redraw.
  self.hasScheduledRedraw = false

proc updateWindowActivity(self: var UI) {.raises: [].} =
  if self.windowFocused or self.windowMouseInside:
    self.windowInactiveSince = 0
  elif self.windowAutoDismissArmed and self.windowInactiveSince == 0:
    self.windowInactiveSince = self.nowTicks()

proc windowFocusGained*(self: var UI) {.raises: [].} =
  ## Mark the backing window focused for dialog auto-dismiss policy.
  self.windowFocused = true
  self.updateWindowActivity()

proc windowFocusLost*(self: var UI) {.raises: [].} =
  ## Mark the backing window unfocused for dialog auto-dismiss policy.
  self.windowFocused = false
  self.updateWindowActivity()

proc windowMouseEnter*(self: var UI) {.raises: [].} =
  ## Mark the pointer as inside the backing window.
  self.windowMouseInside = true
  self.windowAutoDismissArmed = true
  self.updateWindowActivity()

proc windowMouseLeave*(self: var UI) {.raises: [].} =
  ## Mark the pointer as outside the backing window.
  self.windowMouseInside = false
  self.updateWindowActivity()

proc windowInactiveFor*(self: UI, graceMs: int): bool {.raises: [].} =
  ## Test whether focus or pointer activity has been absent for `graceMs`.
  if not self.windowAutoDismissArmed:
    return false
  if self.windowFocused or self.windowMouseInside:
    return false
  if self.windowInactiveSince == 0:
    return false
  self.nowTicks() - self.windowInactiveSince >= max(graceMs, 0)

proc windowInactiveRemainingMs*(self: UI, graceMs: int): int {.raises: [].} =
  ## Return the remaining grace delay for inactive-window auto-dismiss.
  if not self.windowAutoDismissArmed or self.windowFocused or
      self.windowMouseInside or self.windowInactiveSince == 0:
    return -1
  max(self.windowInactiveSince + max(graceMs, 0) - self.nowTicks(), 0)

proc externalPopoverAvailable(): bool {.raises: [].} =
  when defined(linux):
    screen.externalPopoversEnabled and getEnv("WAYLAND_DISPLAY").len > 0
  else:
    false

proc tooltipTraceEnabled(): bool {.raises: [].} =
  getEnv("NEST_TOOLTIP_TRACE").normalize in ["1", "true", "yes", "on"]

proc traceTooltip(message: string) {.raises: [].} =
  if tooltipTraceEnabled():
    try:
      echo "[nest tooltip] " & message
    except IOError:
      discard

proc closePopover(popover: PopoverProcess) {.raises: [].} =
  if popover == nil or popover.process == nil:
    return
  try:
    if popover.process.running:
      popover.process.terminate
      discard popover.process.waitForExit(100)
    else:
      discard popover.process.waitForExit(0)
    popover.process.close
  except OSError:
    discard
  except IOError:
    discard
  except ValueError:
    discard

proc popoverAnchorJson(self: UI, x, y: int): string {.raises: [].} =
  $(%*{
    "x": x,
    "y": y,
    "width": 1,
    "height": 1,
    "windowWidth": self.windowWidth,
    "windowHeight": max(self.windowHeight, 1),
  })

proc cursorPopoverAnchorJson(self: UI, x, y: int): string {.raises: [].} =
  $(%*{
    "cursor": true,
    "x": x,
    "y": y,
    "width": 1,
    "height": 1,
    "windowWidth": max(self.windowWidth, 1),
    "windowHeight": max(self.windowHeight, 1),
  })

proc startPopoverProcess(
    command: string, args: openArray[string], resultPath = "", key = ""
): PopoverProcess {.raises: [].} =
  when defined(linux):
    try:
      var processArgs = @[command]
      for arg in args:
        processArgs.add arg
      result = PopoverProcess(
        process: startProcess(
          getAppFilename(), args = processArgs, options = {poUsePath,
              poParentStreams}
        ),
        resultPath: resultPath,
        key: key,
      )
    except OSError:
      result = nil
    except IOError:
      result = nil
  else:
    discard command
    discard args
    discard resultPath
    discard key

proc showExternalTooltip*(self: var UI, id: WidgetID, text: string) {.raises: [].} =
  ## Show `text` next to the pointer in a separate popover process when the
  ## current platform supports external popovers.
  if text.len == 0 or not externalPopoverAvailable():
    if text.len > 0:
      traceTooltip("external popovers unavailable")
    return
  let key = $id & "\x1f" & text
  if self.tooltipProcess != nil and self.tooltipProcess.key == key:
    return
  self.tooltipProcess.closePopover()
  traceTooltip("show " & $id & " " & text)
  self.tooltipProcess = startPopoverProcess(
    "tooltip-popover",
    [text, self.cursorPopoverAnchorJson(
        max(self.context.update.mouseX - TooltipCursorInset, 0),
        max(self.context.update.mouseY - TooltipCursorInset, 0),
      ), self.themeName, $getCurrentProcessId()],
    key = key,
  )

proc hideExternalTooltip*(self: var UI) {.raises: [].} =
  ## Close the currently shown external tooltip, if any.
  self.tooltipProcess.closePopover()
  self.tooltipProcess = nil

proc tooltipNow(self: UI): int {.raises: [].} =
  if self.context.draw.ticks > 0:
    self.context.draw.ticks
  else:
    try:
      input.getTicks()
    except Exception:
      0

proc evaluateTooltipHover(self: var UI) {.raises: [].} =
  if not externalPopoverAvailable():
    return
  var
    bestID = InvalidWidgetID
    bestText = ""
    bestArea = Inf
  for id, text in self.tooltipTexts.pairs:
    if text.len == 0:
      continue
    let located = self.widgetFrame(id)
    if not located.ok:
      continue
    let frame = located.frame
    if self.context.update.mouseX.float64 >= frame.x and
        self.context.update.mouseX.float64 < frame.x + frame.width and
        self.context.update.mouseY.float64 >= frame.y and
        self.context.update.mouseY.float64 < frame.y + frame.height:
      let area = frame.width * frame.height
      if bestID == InvalidWidgetID or area < bestArea:
        bestID = id
        bestText = text
        bestArea = area
  if bestID == InvalidWidgetID:
    self.tooltipHoverID = InvalidWidgetID
    self.tooltipHoverText = ""
    self.tooltipHoverSince = 0
    self.hideExternalTooltip()
    return

  let now = self.tooltipNow()
  if bestID != self.tooltipHoverID or bestText != self.tooltipHoverText:
    traceTooltip("hover " & $bestID & " " & bestText)
    self.tooltipHoverID = bestID
    self.tooltipHoverText = bestText
    self.tooltipHoverSince = now
    self.hideExternalTooltip()
    self.requestRedrawAfterSafe(TooltipDelayMs)
    return

  let elapsed = now - self.tooltipHoverSince
  if elapsed < TooltipDelayMs:
    self.requestRedrawAfterSafe(TooltipDelayMs - elapsed)
    return

  self.showExternalTooltip(bestID, bestText)

proc tooltip*(self: var UI, id: WidgetID, text: string) =
  ## Attach a tooltip to the widget `id`.
  ##
  ## Layer-shell Wayland apps show the tooltip as a separate popover process
  ## so it can escape the parent window bounds. Other apps currently ignore
  ## the request.
  if text.len == 0:
    self.tooltipTexts.del id
  else:
    self.tooltipTexts[id] = text

proc markAllDirty*(self: var UI) {.raises: [].} =
  ## Mark the whole frame as needing to be redrawn.
  self.context.draw.dirtyAll = true

proc markDirty*(self: var UI, id: WidgetID) {.raises: [].} =
  ## Mark one widget as needing to be redrawn. Ignores `InvalidWidgetID`.
  if id != InvalidWidgetID:
    self.context.draw.dirtyWidgets.incl id

proc scrollByY*(self: var UI, id: WidgetID, delta: float64) {.raises: [].} =
  ## Move a scroll container's vertical target by `delta` pixels.
  if id == InvalidWidgetID:
    return
  var state = self.scrollStates.getOrDefault(id)
  state.targetY = (state.targetY + delta).clamp(0.0, state.maxY)
  self.scrollStates[id] = state
  self.markDirty(id)
  self.requestRedrawAfterSafe(16)

proc scrollIntoView*(
    self: var UI, containerID, childID: WidgetID, padding = 0.0
) {.raises: [].} =
  ## Adjust a scroll container's vertical target so `childID` is visible.
  if containerID == InvalidWidgetID or childID == InvalidWidgetID:
    return
  let
    container = self.widgetFrame(containerID)
    child = self.widgetFrame(childID)
  if not container.ok or not child.ok:
    return
  var state = self.scrollStates.getOrDefault(containerID)
  let
    childTop = child.frame.y - padding
    childBottom = child.frame.y + child.frame.height + padding
    visibleTop = container.frame.y
    visibleBottom = container.frame.y + container.frame.height
  if childTop < visibleTop:
    state.targetY = (state.targetY - (visibleTop - childTop)).clamp(0.0,
        state.maxY)
  elif childBottom > visibleBottom:
    state.targetY = (state.targetY + (childBottom - visibleBottom)).clamp(0.0,
        state.maxY)
  else:
    return
  self.scrollStates[containerID] = state
  self.markDirty(containerID)
  self.requestRedrawAfterSafe(16)

proc markRealtime*(self: var UI, id: WidgetID) {.raises: [].} =
  ## Mark a widget as animating, so it is redrawn every frame for as long as
  ## it stays in the tree. Ignores `InvalidWidgetID`.
  if id != InvalidWidgetID:
    self.liveRealtimeWidgetIDs.incl id

proc hasRealtimeWidgets*(self: UI): bool {.raises: [].} =
  ## Test whether the retained frame holds any animating widget.
  self.retainedRealtimeWidgets.len > 0

proc redrewFrame*(self: UI): bool {.raises: [].} =
  ## Test whether the last frame actually drew anything, which decides
  ## whether the window needs presenting.
  self.frameRedrawn

proc hasPendingWidgetEvents*(self: UI): bool {.raises: [].} =
  ## Test whether an interaction is still in flight: a widget held active,
  ## one submitted this frame, or a middle-button drag.
  self.context.draw.activeWidgets.len > 0 or
      self.context.draw.submittedWidgets.len > 0 or
      self.context.draw.middleDragging != InvalidWidgetID

proc hasPendingInput*(self: UI): bool {.raises: [].} =
  ## Test whether there is input the UI has not consumed yet.
  self.inputPending or self.hasPendingWidgetEvents()

proc hasPendingFullRenderInput*(self: UI): bool {.raises: [].} =
  ## Test whether there is input that forces a full redraw rather than an
  ## incremental one.
  self.fullRenderInputPending or self.hasPendingWidgetEvents()

proc needsFullRender*(self: UI): bool {.raises: [].} =
  ## Test whether anything has been marked dirty since the last draw.
  self.forceNextFullRedraw or self.context.draw.dirtyAll or
      self.context.draw.dirtyWidgets.len > 0

proc hasRetainedFrame*(self: UI): bool {.raises: [].} =
  ## Test whether a retained frame is available to redraw from.
  self.retainedFrameValid

proc setDrawTicks*(self: var UI, ticks: int) =
  ## Set the tick count the frame is drawn at, which animations measure
  ## time against.
  self.context.draw.ticks = ticks

proc setDrawCommands*(self: var UI, commands: ptr seq[DrawCommand]) =
  ## Record drawing into `commands` instead of issuing it to the backend.
  ##
  ## Pass nil to go back to drawing directly.
  self.context.draw.drawCommands = commands

proc setDrawCommandRelays*(
    self: var UI,
    commands: ptr seq[DrawCommand],
    measureText: proc(f: Font, text: string): TextExtent {.nimcall.},
    measureImage: proc(path: string): TextExtent {.nimcall.},
) =
  ## Record drawing into `commands`, and measure text and images through
  ## `measureText` and `measureImage`.
  ##
  ## Recording needs its own measuring hooks, because the backend is not
  ## being touched while the frame is captured.
  self.context.draw.drawCommands = commands
  self.context.draw.commandMeasureText = measureText
  self.context.draw.commandMeasureImage = measureImage

proc setIO*(self: var UI, io: IO) =
  ## Install the host hooks widgets reach the outside world through, such as
  ## file pickers.
  self.context.draw.io = io

proc io*(self: UI): IO =
  ## Return the host hooks installed with `setIO`.
  self.context.draw.io

proc pick*(files: FileIO, id: WidgetID, defaultLocation = ""): bool {.discardable.} =
  ## Start the host's file picker for the widget `id`, starting at
  ## `defaultLocation`.
  ##
  ## Returns false when the host installed no picker.
  if files.openFile.isNil:
    false
  else:
    files.openFile(id, defaultLocation.cstring)

proc value*(files: FileIO, id: WidgetID): string =
  ## Return the path the picker for `id` produced, or an empty string.
  if files.fileValue.isNil:
    ""
  else:
    $files.fileValue(id)

proc error*(files: FileIO, id: WidgetID): string =
  ## Return the error the picker for `id` reported, or an empty string.
  if files.fileError.isNil:
    ""
  else:
    $files.fileError(id)

proc clear*(files: FileIO, id: WidgetID) =
  ## Forget the picker result stored for `id`.
  if not files.clearFile.isNil:
    files.clearFile(id)

proc openDialog*(self: var UI, open: var bool) =
  ## Open the dialog `open` tracks and ask for a redraw.
  open = true
  self.requestRedrawAfter(0)

proc closeDialog*(self: var UI, open: var bool) =
  ## Close the dialog `open` tracks and ask for a redraw.
  open = false
  self.requestRedrawAfter(0)

proc toggleDialog*(self: var UI, open: var bool): bool {.discardable.} =
  ## Flip the dialog `open` tracks, ask for a redraw, and return its new
  ## state.
  open = not open
  self.requestRedrawAfter(0)
  result = open

proc returnDialog*(
    self: var UI, key, value: string, open: var bool
): string {.discardable.} =
  ## Close the dialog `open` tracks, storing `value` as its result under
  ## `key`, and return `value`.
  self.dialogResults[key] = value
  self.closeDialog(open)
  value

proc hasDialogResult*(self: UI, key: string): bool =
  ## Test whether a dialog has stored a result under `key`.
  self.dialogResults.hasKey(key)

proc dialogResult*(self: UI, key: string): string =
  ## Return the result stored under `key`, or an empty string.
  self.dialogResults.getOrDefault(key)

proc clearDialogResult*(self: var UI, key: string) =
  ## Forget the dialog result stored under `key`.
  self.dialogResults.del key

proc setRenderKey*(self: var UI, id: WidgetID, key: string) =
  ## Record what the widget `id` renders as, so the UI can tell when it needs
  ## redrawing.
  ##
  ## A widget whose key changed is marked dirty; a widget seen for the first
  ## time only marks itself, while a changed key marks the whole frame, since
  ## it may have changed the layout around it.
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
    $config.style.hasOpacity & "|" & $config.style.opacity & "|" &
    $config.style.cornerStyle & "|" & $config.style.cornerRadii & "|" &
    $config.style.hasShadow & "|" & $config.style.shadowColor & "|" &
    $config.style.shadowOffsetX & "|" & $config.style.shadowOffsetY & "|" &
    $config.style.shadowBlur & "|" & $config.style.shadowSpread
  let paddingKey = $config.padding.left & "," & $config.padding.top & "," &
    $config.padding.right & "," & $config.padding.bottom
  let buttonPaddingKey = $config.buttonPadding.left & "," &
    $config.buttonPadding.top & "," & $config.buttonPadding.right & "," &
    $config.buttonPadding.bottom
  kind & "|" & $config.width & "|" & $config.height & "|" & $config.gap & "|" &
    paddingKey & "|" & $config.alignItems & "|" & $config.justifyContent & "|" &
    $config.alignSelf & "|" & $config.scrollX & "|" & $config.scrollY & "|" &
    $config.scrollWheel & "|" & $config.dismissOnClickaway & "|" &
    $config.textScroll & "|" & $config.lineNumbers & "|" & $config.scrollbars &
    "|" & $config.readOnly & "|" & config.fontName & "|" & $config.fontSize &
    "|" & buttonPaddingKey & "|" & config.syntax &
    styleKey

proc styleRenderKey(style: ComponentStyle): string =
  $style.hasBackground & "|" & $style.background & "|" & $style.hasOpacity & "|" &
    $style.opacity & "|" & $style.cornerStyle & "|" & $style.cornerRadii & "|" &
    $style.hasShadow & "|" & $style.shadowColor & "|" & $style.shadowOffsetX & "|" &
    $style.shadowOffsetY & "|" & $style.shadowBlur & "|" & $style.shadowSpread

proc renderKey(kind: string, width, height: SizePolicy,
    alignSelf: Alignment): string =
  kind & "|" & $width & "|" & $height & "|" & $alignSelf

proc beginInputFrame*(self: var UI) =
  ## Start collecting a frame's input, clearing what the last frame left
  ## behind.
  self.forceNextFullRedraw = false
  self.context.update.keyInputs.setLen(0)
  self.context.update.textInputs.setLen(0)
  self.context.update.mouseWheelX = 0
  self.context.update.mouseWheelY = 0
  self.context.update.submittedWidgets.clear()
  self.context.update.dirtyWidgets.clear()
  self.context.update.sliderValues.clear()
  self.context.update.mouseMiddlePressed = false
  self.context.update.mouseRightPressed = false

proc finishInputFrame*(self: var UI) =
  ## Finish a frame's input, clearing the one-shot state so a press or a key
  ## is not delivered twice.
  self.context.update.mouseLeftPressed = false
  self.context.update.mouseMiddlePressed = false
  self.context.update.mouseRightPressed = false
  self.context.update.keyInputs.setLen(0)
  self.context.update.textInputs.setLen(0)
  self.context.update.mouseWheelX = 0
  self.context.update.mouseWheelY = 0
  self.context.update.submittedWidgets.clear()
  self.context.update.dirtyWidgets.clear()
  self.context.update.sliderValues.clear()
  self.inputPending = false
  self.fullRenderInputPending = false

proc mouseMove*(self: var UI, x, y: int) =
  ## Report the pointer moving to `x`, `y`.
  self.inputPending = true
  self.context.update.mouseX = x
  self.context.update.mouseY = y
  self.context.draw.mouseX = x
  self.context.draw.mouseY = y

proc mouseDown*(self: var UI) =
  ## Report the left button going down; the frame it goes down on counts as a
  ## press.
  self.inputPending = true
  self.fullRenderInputPending = true
  let last = self.context.update.mouseLeftDown
  self.context.update.mouseLeftDown = true
  self.context.update.mouseLeftPressed = not last

proc mouseUp*(self: var UI) =
  ## Report the left button coming up, which also ends a slider drag.
  self.inputPending = true
  self.fullRenderInputPending = true
  self.context.update.mouseLeftDown = false
  self.context.update.sliderDragging = InvalidWidgetID

proc mouseMiddleDown*(self: var UI) =
  ## Report the middle button going down.
  self.inputPending = true
  self.fullRenderInputPending = true
  let last = self.context.update.mouseMiddleDown
  self.context.update.mouseMiddleDown = true
  self.context.update.mouseMiddlePressed = not last

proc mouseMiddleUp*(self: var UI) =
  ## Report the middle button coming up, which also ends a middle-button
  ## drag.
  self.inputPending = true
  self.fullRenderInputPending = true
  self.context.update.mouseMiddleDown = false
  self.context.update.middleDragging = InvalidWidgetID
  self.context.draw.middleDragging = InvalidWidgetID

proc mouseRightDown*(self: var UI) =
  ## Report the right button going down.
  self.inputPending = true
  self.fullRenderInputPending = true
  self.context.update.mouseRightPressed = true

proc resizeWindow*(self: var UI, width, height: int) =
  ## Report the window being resized to `width` by `height`; negative sizes
  ## clamp to zero.
  self.inputPending = true
  self.fullRenderInputPending = true
  self.context.update.windowWidth = max(width, 0)
  self.context.update.windowHeight = max(height, 0)
  self.context.draw.windowWidth = self.context.update.windowWidth
  self.context.draw.windowHeight = self.context.update.windowHeight

proc keyDown*(self: var UI, key: KeyCode, mods: set[Modifier]) =
  ## Report `key` being pressed with the modifiers `mods` held.
  self.inputPending = true
  self.fullRenderInputPending = true
  self.context.update.keyInputs.add KeyInput(key: key, mods: mods)

proc textInput*(self: var UI, text: string) =
  ## Report typed `text`. Empty text is ignored.
  if text.len > 0:
    self.inputPending = true
    self.fullRenderInputPending = true
    self.context.update.textInputs.add text

proc mouseWheel*(self: var UI, x, y: float64) =
  ## Report wheel movement, accumulated over the frame.
  self.inputPending = true
  self.fullRenderInputPending = true
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
  ## Return the widget id named by `parts`.
  ##
  ## Ids are hashed from the parts and the enclosing `scope`, so the same
  ## name yields the same id every frame, which is what lets a widget keep
  ## its state across frames.
  var scoped = self.idScopes
  if parts.len == 0 and scoped.len == 0:
    scoped.add "_nest_empty_id"
  else:
    for part in parts:
      scoped.add part
  keyedWidgetID(scoped)

proc scopedID*(self: var UI, parent: WidgetID,
    parts: varargs[string, `$`]): WidgetID =
  ## Return the widget id named by `parts` inside the scope of `parent`,
  ## without disturbing the current scope.
  self.idScopes.add($parent)
  try:
    self.id(parts)
  finally:
    self.idScopes.setLen(self.idScopes.len - 1)

proc nextAutoID*(self: var UI): WidgetID =
  ## Return a generated id for a widget the caller did not name.
  ##
  ## The counter restarts each frame, so an unnamed widget keeps its id only
  ## as long as the declarations around it are unchanged.
  let key = "_nest_auto_id:" & $self.autoIDCounter
  inc self.autoIDCounter
  self.id(key)

template scope*(self: var UI, key: untyped, body: untyped) =
  ## Run `body` with `key` pushed onto the id scope.
  ##
  ## Every id built inside is qualified by `key`, which is how the same
  ## component can be declared more than once without its widgets colliding.
  block:
    self.idScopes.add($key)
    try:
      body
      discard
    finally:
      self.idScopes.setLen(self.idScopes.len - 1)

template autoScoped*(self: var UI, body: untyped) =
  ## Run `body` in a scope named by a generated id, injected as `autoID`.
  ##
  ## This is how the unnamed widget overloads keep their children apart.
  block:
    let autoID {.inject.} = self.nextAutoID()
    self.scope(autoID):
      body

proc peelSignature(node: NimNode, returnType, eventType: var NimNode): NimNode =
  ## Strip `emits E` and `-> T` off a widget signature, in any order, including
  ## when an export marker encloses them.
  if node.kind == nnkCommand and node.len == 2 and node[1].kind ==
      nnkCommand and node[1][0].eqIdent("emits"):
    eventType = node[1][1]
    return node[0].peelSignature(returnType, eventType)
  if node.kind == nnkInfix and node.len == 3 and node[0].eqIdent("->"):
    returnType = node[2]
    return node[1].peelSignature(returnType, eventType)
  if node.kind == nnkInfix and node.len == 3 and node[0].eqIdent("*"):
    return nnkInfix.newTree(
      node[0], node[1], node[2].peelSignature(returnType, eventType)
    )
  node

proc emitToResult(node: NimNode): NimNode =
  ## Rewrite every `emit x` in a widget body into `result.add x`.
  if node.kind in {nnkCall, nnkCommand} and node.len == 2 and
      node[0].eqIdent("emit"):
    return newCall(newDotExpr(ident"result", ident"add"), node[1])
  result = node.copyNimNode
  for child in node:
    result.add child.emitToResult

macro widget*(signature, body: untyped): untyped =
  ## Declare a portion of a user interface as a named routine.
  ##
  ## `widget name(params): body` expands to a routine that takes the `UI` as its
  ## first parameter and runs `body` inside `ui.scope("name")`:
  ##
  ## ```nim
  ## widget counter(model: CounterModel):
  ##   ui.label(ui.id("count"), $model.count, fit(), fit())
  ##
  ## # becomes
  ## proc counter(ui: var UI, model: CounterModel) =
  ##   ui.scope("counter"):
  ##     ui.label(ui.id("count"), $model.count, fit(), fit())
  ## ```
  ##
  ## The body is ordinary Nim and keeps the `ui.` prefix on every call, so a
  ## `widget` declaration and a hand-written `proc name(ui: var UI, ...)` are
  ## interchangeable: turning one into the other is a change to the header, not
  ## to the interface it declares.
  ##
  ## Ids built with `ui.id` inside the body are scoped by the name, which keeps
  ## two widgets from meeting on a shared id such as `"row"`. Declaring the same
  ## widget twice in one frame still needs a `ui.scope` at the call site, so the
  ## two instances differ.
  ##
  ## **Events.** `emits E` gives the widget its own event type. Inside the body,
  ## `emit` reports one; the widget returns the events it emitted, and its caller
  ## either handles them or raises its own in their place:
  ##
  ## ```nim
  ## widget counter(model: CounterModel) emits CounterEvent:
  ##   if ui.button(ui.id("inc"), "+", fit(), fit()):
  ##     emit Incremented
  ##
  ## widget page(model: PageModel) emits PageEvent:
  ##   for event in ui.counter(model.counter):
  ##     case event
  ##     of Incremented: emit CountChanged
  ## ```
  ##
  ## Events are produced during the event pass, so a caller consumes them where
  ## they are returned, or accumulates them with `add`. Assigning them to a
  ## variable that outlives the call loses them: the layout pass runs the widget
  ## a second time and returns nothing.
  ##
  ## **Containers.** A parameter of type `untyped` takes a block, which lets a
  ## widget wrap children the caller supplies. Such a widget expands to a
  ## template rather than a procedure, so it cannot use `emits`; take an
  ## `events: var seq[E]` parameter and append to it instead. Its parameter
  ## names are substituted textually, so a name that also appears as a field
  ## name inside the body will replace that too:
  ##
  ## ```nim
  ## widget titledCard(title: string, body: untyped):
  ##   ui.card(ui.id("root"), cfg(padding = 10, gap = 6)):
  ##     ui.label(ui.id("title"), title, fill(), fit())
  ##     body
  ##
  ## ui.titledCard("Details"):
  ##   ui.label(ui.id("line"), "inside the card", fill(), fit())
  ## ```
  ##
  ## Parameters otherwise take the usual forms, including a shared type and a
  ## default. Export a widget by marking its name, as in `widget counter*(...)`.
  ## A return type can also be given directly with `->`, in which case `result`
  ## is used as in any procedure and the result is discardable.
  var
    returnType = newEmptyNode()
    eventType = newEmptyNode()
    node = signature.peelSignature(returnType, eventType)

  if returnType.kind != nnkEmpty and eventType.kind != nnkEmpty:
    error("a widget declares either `emits E` or `-> T`, not both", signature)
  if eventType.kind != nnkEmpty:
    returnType = nnkBracketExpr.newTree(ident"seq", eventType)

  var
    nameNode: NimNode
    argumentList: NimNode = nil
    firstArgument = 0

  if node.kind == nnkInfix and node[0].eqIdent("*"):
    nameNode = nnkPostfix.newTree(ident"*", node[1])
    argumentList = node[2]
  else:
    case node.kind
    of nnkIdent, nnkAccQuoted:
      nameNode = node
    of nnkCall, nnkCommand, nnkObjConstr:
      nameNode = node[0]
      argumentList = node
      firstArgument = 1
    else:
      error("widget expects a name and a parameter list", signature)

  if argumentList != nil and
      argumentList.kind notin {nnkPar, nnkTupleConstr, nnkCall, nnkCommand,
        nnkObjConstr}:
    error("widget expects a name and a parameter list", signature)

  let bareName =
    if nameNode.kind == nnkPostfix:
      nameNode[1]
    else:
      nameNode

  var
    parameters = @[returnType,
      newIdentDefs(ident"ui", nnkVarTy.newTree(ident"UI"))]
    pending: seq[NimNode]
    takesBlock = false

  if argumentList != nil:
    for index in firstArgument ..< argumentList.len:
      let argument = argumentList[index]
      case argument.kind
      of nnkIdent, nnkAccQuoted:
        # A parameter that shares its type with a later one: `first, second: T`.
        pending.add argument
      of nnkExprColonExpr:
        var
          parameterType = argument[1]
          default = newEmptyNode()
        if parameterType.kind == nnkAsgn:
          default = parameterType[1]
          parameterType = parameterType[0]
        if parameterType.eqIdent("untyped") or parameterType.eqIdent("typed"):
          takesBlock = true
        pending.add argument[0]
        for name in pending:
          parameters.add newIdentDefs(name, parameterType, default)
        pending.setLen(0)
      of nnkExprEqExpr, nnkAsgn:
        # A parameter whose type comes from its default: `tone = 0`.
        if pending.len > 0:
          error("widget parameter `" & pending[^1].repr & "` has no type",
            signature)
        parameters.add newIdentDefs(argument[0], newEmptyNode(), argument[1])
      else:
        error("widget parameters must be `name: Type`", argument)

  if pending.len > 0:
    error("widget parameter `" & pending[^1].repr & "` has no type", signature)

  if eventType.kind != nnkEmpty and takesBlock:
    error(
      "a widget that takes a block cannot use `emits`, because it expands to " &
        "a template: give it an `events: var seq[" & eventType.repr &
        "]` parameter and append to that instead",
      signature,
    )

  var rewritten = body
  if eventType.kind != nnkEmpty:
    rewritten = body.emitToResult

  let scopeCall = newCall(
    newDotExpr(ident"ui", ident"scope"), newLit($bareName), rewritten
  )

  result = newProc(
    name = nameNode,
    params = parameters,
    body = newStmtList(scopeCall),
    procType = if takesBlock: nnkTemplateDef else: nnkProcDef,
  )
  if returnType.kind != nnkEmpty and eventType.kind == nnkEmpty:
    result.addPragma ident"discardable"

proc pointerContains(frame: Frame, x, y: int): bool =
  x.toFloat >= frame.x and x.toFloat < frame.x + frame.width and
    y.toFloat >= frame.y and y.toFloat < frame.y + frame.height

proc collectSubtree(
    self: UI,
    id: WidgetID,
    children: Table[WidgetID, seq[Widget]],
    into: var HashSet[WidgetID],
) =
  into.incl id
  for child in children.getOrDefault(id):
    self.collectSubtree(child.id, children, into)

proc takePointerSurface(self: var UI, x, y, windowWidth, windowHeight: int) =
  ## Decide which surface owns the pointer for this frame.
  ##
  ## A surface that covers other widgets owns the pointer while the pointer is
  ## inside it: a floating card, a dialog, a menu popover, or the area a
  ## component reports from `pointerShield`, such as an open dropdown list.
  ## The topmost one wins, which is the last one declared, and a component's
  ## overlay comes above the floating widgets because that is the order they
  ## draw in.
  ##
  ## It is decided once, from the frame on screen, and holds for the whole
  ## frame: the click that closes a popover therefore belongs to the popover
  ## and not to what it covered.
  self.pointerSurfaceWidget = InvalidWidgetID
  self.pointerSurfaceIDs.clear()
  for widget in self.retainedFloatingWidgets:
    if widget.id in self.retainedModalWidgets:
      self.pointerSurfaceWidget = widget.id
      continue
    let located = self.widgetFrame(widget.id)
    if located.ok and located.frame.pointerContains(x, y):
      self.pointerSurfaceWidget = widget.id
  for (component, widget) in self.retainedComponents:
    let shield = component.pointerShield(widget, windowWidth, windowHeight)
    if shield.has and shield.frame.pointerContains(x, y):
      self.pointerSurfaceWidget = widget.id
  if self.pointerSurfaceWidget != InvalidWidgetID:
    self.collectSubtree(
      self.pointerSurfaceWidget, self.retainedLayoutChildren,
      self.pointerSurfaceIDs,
    )

proc pointerSurface*(self: UI): WidgetID =
  ## Return the widget that owns the pointer this frame, or `InvalidWidgetID`
  ## when the pointer is over ordinary content.
  self.pointerSurfaceWidget

proc pointerReaches*(self: UI, id: WidgetID): bool =
  ## Test whether the pointer is available to the widget `id` this frame.
  ##
  ## False for everything outside the surface that owns the pointer, which is
  ## how one click lands on one surface only. Widgets that read a press
  ## directly, rather than through `clicked`, ask this first.
  self.pointerSurfaceWidget == InvalidWidgetID or
    id in self.pointerSurfaceIDs

proc beginEvents(self: var UI, context: DrawContext) =
  self.phase = EventPhase
  self.autoIDCounter = 0
  self.eventActiveWidgets = context.activeWidgets
  self.eventSubmittedWidgets = context.submittedWidgets
  self.eventFocusedWidget = context.focusedWidget
  self.takePointerSurface(
    context.mouseX, context.mouseY, context.windowWidth, context.windowHeight
  )

proc active*(self: UI, id: WidgetID): bool =
  ## Test whether the widget `id` is being pressed.
  id in self.eventActiveWidgets

proc clicked*(self: UI, id: WidgetID): bool =
  ## Test whether the widget `id` was clicked.
  ##
  ## True on the frame the press lands, which is what the widget helpers
  ## return from the event phase. Like them, it answers only while events are
  ## being dispatched, so a handler built on it runs once a frame rather than
  ## again as the widget tree is built.
  self.phase == EventPhase and self.active(id)

proc mouseLeftPressed*(self: UI): bool =
  ## Test whether the left mouse button was pressed this frame.
  self.phase == EventPhase and self.context.update.mouseLeftPressed

proc clickedIn*(self: UI, id: WidgetID): bool =
  ## Test whether the mouse was pressed inside the widget's solved frame.
  if self.phase != EventPhase or not self.pointerReaches(id):
    return false
  let located = self.widgetFrame(id)
  located.ok and self.context.update.mouseLeftPressed and
    self.context.update.mouseX.toFloat >= located.frame.x and
    self.context.update.mouseX.toFloat < located.frame.x + located.frame.width and
    self.context.update.mouseY.toFloat >= located.frame.y and
    self.context.update.mouseY.toFloat < located.frame.y + located.frame.height

proc dragWindow*(self: var UI, id: WidgetID) =
  ## Makes this widget a drag handle for the application window.
  ## Call this from a popup or dialog title region to opt into dragging.
  if self.phase != EventPhase:
    return
  if not self.pointerReaches(id):
    return
  let located = self.widgetFrame(id)
  if self.context.update.mouseLeftPressed and located.ok:
    let frame = located.frame
    if self.context.update.mouseX.toFloat >= frame.x and
        self.context.update.mouseX.toFloat < frame.x + frame.width and
        self.context.update.mouseY.toFloat >= frame.y and
        self.context.update.mouseY.toFloat < frame.y + frame.height:
      self.windowDragHandle = id
      self.windowDragLastX = self.context.update.mouseX
      self.windowDragLastY = self.context.update.mouseY
  if self.windowDragHandle != id:
    return
  if not self.context.update.mouseLeftDown:
    self.windowDragHandle = InvalidWidgetID
    return
  let dx = self.context.update.mouseX - self.windowDragLastX
  let dy = self.context.update.mouseY - self.windowDragLastY
  if dx != 0 or dy != 0:
    moveWindowBy(dx, dy)
    self.windowDragLastX = self.context.update.mouseX
    self.windowDragLastY = self.context.update.mouseY

proc resizeFloating*(self: var UI, id: WidgetID, width, height: var float64,
    minWidth = 240.0, minHeight = 160.0, maxWidth = Inf, maxHeight = Inf) =
  ## Resize a floating surface by dragging the widget `id`.
  if self.phase != EventPhase:
    return
  if not self.pointerReaches(id):
    return
  let located = self.widgetFrame(id)
  if self.context.update.mouseLeftPressed and located.ok and
      located.frame.pointerContains(self.context.update.mouseX,
          self.context.update.mouseY):
    self.resizeDragHandle = id
    self.resizeDragLastX = self.context.update.mouseX
    self.resizeDragLastY = self.context.update.mouseY
  if self.resizeDragHandle != id:
    return
  if not self.context.update.mouseLeftDown:
    self.resizeDragHandle = InvalidWidgetID
    return
  let
    dx = self.context.update.mouseX - self.resizeDragLastX
    dy = self.context.update.mouseY - self.resizeDragLastY
  if dx != 0 or dy != 0:
    width = (width + dx.toFloat).clamp(minWidth, maxWidth)
    height = (height + dy.toFloat).clamp(minHeight, maxHeight)
    self.resizeDragLastX = self.context.update.mouseX
    self.resizeDragLastY = self.context.update.mouseY
    self.markAllDirty()
    self.requestRedrawAfter(0)

proc rightClicked*(self: UI, id: WidgetID): bool =
  ## Test whether the right button was pressed over the widget `id` this
  ## frame. Only reports during the event phase.
  if self.phase != EventPhase or not self.context.update.mouseRightPressed:
    return false
  let located = self.widgetFrame(id)
  located.ok and self.context.update.mouseX.toFloat >= located.frame.x and
    self.context.update.mouseX.toFloat < located.frame.x +
        located.frame.width and
    self.context.update.mouseY.toFloat >= located.frame.y and
    self.context.update.mouseY.toFloat < located.frame.y + located.frame.height

proc middleClicked*(self: UI, id: WidgetID): bool =
  ## Test whether the middle button was pressed over the widget `id` this
  ## frame. Only reports during the event phase.
  if self.phase != EventPhase or not self.context.update.mouseMiddlePressed:
    return false
  let located = self.widgetFrame(id)
  located.ok and self.context.update.mouseX.toFloat >= located.frame.x and
    self.context.update.mouseX.toFloat < located.frame.x +
        located.frame.width and
    self.context.update.mouseY.toFloat >= located.frame.y and
    self.context.update.mouseY.toFloat < located.frame.y + located.frame.height

proc middleDragDelta*(self: var UI, id: WidgetID):
    tuple[active: bool, started: bool, deltaX: int] =
  ## Report a middle-button drag on the widget `id`.
  ##
  ## `active` is true while the drag is in progress, `started` only on the
  ## frame it begins, and `deltaX` is the horizontal distance from where it
  ## started. Only reports during the event phase.
  if self.phase != EventPhase:
    return (false, false, 0)
  let located = self.widgetFrame(id)
  if not located.ok:
    return (false, false, 0)
  let hot =
    self.context.update.mouseX.toFloat >= located.frame.x and
    self.context.update.mouseX.toFloat < located.frame.x +
        located.frame.width and
    self.context.update.mouseY.toFloat >= located.frame.y and
    self.context.update.mouseY.toFloat < located.frame.y + located.frame.height
  if self.context.update.mouseMiddlePressed and hot:
    self.context.draw.middleDragging = id
    self.context.draw.middleDragStartX = self.context.update.mouseX
    return (true, true, 0)
  if self.context.draw.middleDragging == id and
      self.context.update.mouseMiddleDown:
    return (true, false,
      self.context.update.mouseX - self.context.draw.middleDragStartX)
  (false, false, 0)

proc submitted*(self: UI, id: WidgetID): bool =
  ## Test whether the widget `id` was submitted, as a line input is by the
  ## Enter key.
  ##
  ## Answers only while events are being dispatched, like the widget helpers
  ## themselves, so a handler built on it runs once a frame rather than again
  ## as the widget tree is built.
  self.phase == EventPhase and id in self.eventSubmittedWidgets

proc sliderValue*(self: UI, id: WidgetID): tuple[active: bool, value: float64] =
  ## Report the value of the slider `id` while it is being dragged.
  ##
  ## `active` is false, and the value zero, when this slider is not the one
  ## being dragged.
  if self.phase == EventPhase and self.context.draw.sliderDragging == id and
      self.context.draw.sliderValues.hasKey(id):
    return (true, self.context.draw.sliderValues[id])
  (false, 0.0)

proc focused*(self: UI, id: WidgetID): bool =
  ## Test whether the widget `id` holds keyboard focus.
  self.eventFocusedWidget == id

proc focus*(self: var UI, id: WidgetID) =
  ## Give keyboard focus to the widget `id`.
  self.context.update.focusedWidget = id
  self.context.draw.focusedWidget = id
  self.eventFocusedWidget = id

proc closeFocus*(self: var UI, id: WidgetID) =
  ## Take keyboard focus away from the widget `id`, if it holds it.
  ##
  ## Focus is tracked in three places, and all three are cleared here: an
  ## event handler that cleared only one of them would find the layout pass
  ## putting the focus back, which is what keeps a dropdown open after a
  ## pick.
  if self.context.update.focusedWidget == id:
    self.context.update.focusedWidget = InvalidWidgetID
  if self.context.draw.focusedWidget == id:
    self.context.draw.focusedWidget = InvalidWidgetID
  if self.eventFocusedWidget == id:
    self.eventFocusedWidget = InvalidWidgetID

proc liveWidget*(self: UI, id: WidgetID): bool =
  ## Test whether the widget `id` was declared in the current frame.
  id in self.liveWidgetIDs

proc inEventPhase*(self: UI): bool =
  ## Test whether the UI is dispatching events rather than building widgets.
  self.phase == EventPhase

proc inLayoutPhase*(self: UI): bool =
  ## Test whether the UI is building widgets rather than dispatching events.
  self.phase == LayoutPhase

proc normalizedKeyName(value: string): string =
  for ch in value:
    if ch notin {'-', '_', ' '}:
      result.add toLowerAscii(ch)

proc keyPressed*(self: UI, name: string): bool =
  ## Test whether the key called `name` was pressed this frame.
  ##
  ## Names ignore case, spaces, dashes and underscores and may leave off the
  ## `Key` prefix, so `Escape`, `esc` and `KeyEsc` all match the same key.
  ## Only reports during the event phase.
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

proc keyNameMatches(wanted, keyName: string): bool =
  keyName == wanted or keyName == "key" & wanted or
    (wanted == "escape" and keyName == "keyesc") or
    (wanted == "esc" and keyName == "keyesc")

proc keyComboPressed*(self: UI, name: string, ctrl = false, alt = false,
    shift = false, gui = false): bool =
  ## Test whether `name` was pressed with exactly the requested modifiers.
  if self.phase != EventPhase:
    return false
  let wanted = normalizedKeyName(name)
  for input in self.context.update.keyInputs:
    let keyName = normalizedKeyName($input.key)
    if not keyNameMatches(wanted, keyName):
      continue
    if ctrl != (CtrlPressed in input.mods):
      continue
    if alt != (AltPressed in input.mods):
      continue
    if shift != (ShiftPressed in input.mods):
      continue
    if gui != (GuiPressed in input.mods):
      continue
    return true

proc textInput*(self: UI): string =
  ## Return all text input received during this event frame.
  if self.phase != EventPhase:
    return ""
  self.context.update.textInputs.join("")

proc textInputs*(self: UI): seq[string] =
  ## Return each text input chunk received during this event frame.
  if self.phase == EventPhase:
    result = self.context.update.textInputs

proc keyboardInputPending*(self: UI): bool =
  ## Test whether this event frame contains keyboard or text input.
  self.phase == EventPhase and (
    self.context.update.keyInputs.len > 0 or self.context.update.textInputs.len > 0
  )

proc listKey*(index: int, value: string): string =
  ## Return the list key identifying the item `value` at `index`.
  ##
  ## Used to give list rows stable widget ids.
  $index & ":" & value

proc listItems*[T](
    items: openArray[T],
    key: proc(item: T, index: int): string,
    filter: proc(item: T, index: int): bool = nil,
): seq[ListItem[T]] =
  ## Turn `items` into list items, each carrying its index, its `key` and the
  ## item itself.
  ##
  ## `filter` selects which items to keep; passing nil keeps them all. The
  ## keys are what the rows' widget ids are built from, so they should stay
  ## with an item as the list is reordered.
  for index, item in items:
    if filter.isNil or filter(item, index):
      result.add ListItem[T](index: index, key: key(item, index), value: item)

proc editLineState*(): EditLineState =
  ## Create the state of an in-place line editor, with nothing being edited.
  EditLineState(input: LineInputState.new(""), inputID: nextWidgetID(), key: "")

proc editing*(state: EditLineState): bool =
  ## Test whether an in-place edit is in progress.
  state.key.len > 0

proc editing*(state: EditLineState, key: string): bool =
  ## Test whether the row `key` is the one being edited.
  state.key == key

proc beginEdit*(state: var EditLineState, key, value: string) =
  ## Begin editing the row `key`, seeding the editor with `value` and putting
  ## the cursor at its end.
  state.key = key
  state.input.text = value
  state.input.cursor = value.len

proc cancelEdit*(state: var EditLineState) =
  ## Abandon the edit in progress, discarding what was typed.
  state.key = ""

proc saveEdit*(state: var EditLineState): string =
  ## Finish the edit and return the edited text.
  result = state.input.text
  state.cancelEdit()

proc reset*(self: var UI) =
  ## Throw the widget tree away and start over with an empty root.
  ##
  ## The root keeps its id, so a UI can be rebuilt from scratch without every
  ## widget underneath it changing identity.
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
  self.modalWidgets.clear()
  self.floatingBelowAnchors.clear()
  self.centeredFloatingWidgets.clear()
  self.componentByID.clear()
  self.liveAnimationIDs.clear()
  if self.intrinsicByID.isNil:
    self.intrinsicByID = newTable[WidgetID, IntrinsicSize]()
  else:
    self.intrinsicByID.clear()
  self.pendingLayouts.setLen(0)
  self.layoutChildren.clear()
  self.scrollContainers.clear()
  self.scrollWheelContainers.clear()
  self.idScopes.setLen(0)
  self.eventActiveWidgets.clear()
  self.eventSubmittedWidgets.clear()
  self.eventFocusedWidget = InvalidWidgetID
  self.phase = LayoutPhase

proc beginLayout*(self: var UI, windowWidth, windowHeight: int) =
  ## Begin a frame's layout against a window of `windowWidth` by
  ## `windowHeight`.
  ##
  ## Clears the previous frame's widgets and reopens the root as the current
  ## parent. Widget declarations go between this and `endLayout`.
  self.autoIDCounter = 0
  self.layout.root(self.root)
  self.parent = self.root
  self.frames = @[LayoutFrame(parent: self.root)]
  self.childrenWidgets.setLen(0)
  self.components.setLen(0)
  self.floatingWidgets.setLen(0)
  self.floatingBelowAnchors.clear()
  self.centeredFloatingWidgets.clear()
  self.componentByID.clear()
  if self.intrinsicByID.isNil:
    self.intrinsicByID = newTable[WidgetID, IntrinsicSize]()
  else:
    self.intrinsicByID.clear()
  self.pendingLayouts.setLen(0)
  self.layoutChildren.clear()
  self.scrollContainers.clear()
  self.scrollWheelContainers.clear()
  self.tooltipTexts.clear()
  self.liveWidgetIDs.clear()
  self.liveAnimationIDs.clear()
  self.liveWidgetIDs.incl self.root.id
  self.liveRealtimeWidgetIDs.clear()
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

proc scrollSettleDistance(): float64 =
  0.25

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
  frame.pointerContains(x, y)

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
  if abs(state.scrollX - state.targetX) <= scrollSettleDistance():
    state.scrollX = state.targetX
  if abs(state.scrollY - state.targetY) <= scrollSettleDistance():
    state.scrollY = state.targetY
  if abs(state.scrollX - previousScrollX) > 0.01 or
      abs(state.scrollY - previousScrollY) > 0.01:
    self.markDirty(parent.id)
    self.requestRedrawAfterSafe(16)
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
      pending.padding.left + pending.padding.right +
      pending.gap * max(pending.children.len - 1, 0).toFloat
    for child in pending.children:
      width += self.preferredWidth(child, pendingByParent)
    width.clampPolicy(widget.widthPolicy)
  of ColumnLayout:
    var width = widget.widthPolicy.min
    for child in pending.children:
      width =
        max(width, self.preferredWidth(child, pendingByParent) +
            pending.padding.left + pending.padding.right)
    width.clampPolicy(widget.widthPolicy)
  of OverlayLayout:
    var width = widget.widthPolicy.min
    for child in pending.children:
      width =
        max(width, self.preferredWidth(child, pendingByParent) +
            pending.padding.left + pending.padding.right)
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
        height, self.preferredHeight(child, pendingByParent) +
            pending.padding.top +
          pending.padding.bottom
      )
    height.clampPolicy(widget.heightPolicy)
  of ColumnLayout:
    if pending.children.len == 0:
      return widget.heightPolicy.min
    var height =
      pending.padding.top + pending.padding.bottom +
      pending.gap * max(pending.children.len - 1, 0).toFloat
    for child in pending.children:
      height += self.preferredHeight(child, pendingByParent)
    height.clampPolicy(widget.heightPolicy)
  of OverlayLayout:
    var height = widget.heightPolicy.min
    for child in pending.children:
      height = max(
        height, self.preferredHeight(child, pendingByParent) +
            pending.padding.top +
          pending.padding.bottom
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
      availableWidth = max(parentFrame.width - pending.padding.left -
          pending.padding.right, 0.0)
      availableHeight = max(parentFrame.height - pending.padding.top -
          pending.padding.bottom, 0.0)
    var fixedHeight = pending.gap * max(pending.children.len - 1, 0).toFloat
    var fillCount = 0
    for child in pending.children:
      if child.heightPolicy.kind == WidgetFill:
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
        parentFrame.y + pending.padding.top + (availableHeight -
            contentHeight) / 2.0
      of JustifyEnd:
        parentFrame.y + parentFrame.height - pending.padding.bottom - contentHeight
      of JustifyStart:
        parentFrame.y + pending.padding.top
    for child in pending.children:
      let childHeight =
        if child.heightPolicy.kind == WidgetFill:
          let preferred = self.preferredHeight(child, pendingByParent)
          (if pending.scrollY: max(fillHeight,
              preferred) else: fillHeight).clampPolicy(
            child.heightPolicy
          )
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
          parentFrame.x + pending.padding.left + (availableWidth - childWidth) / 2.0
        of AlignEnd:
          parentFrame.x + parentFrame.width - pending.padding.right - childWidth
        else:
          parentFrame.x + pending.padding.left
      child.setFrame(Frame(x: x, y: y, width: childWidth, height: childHeight))
      if pendingByParent.hasKey(child.id):
        self.assignDirectStack(pendingByParent[child.id], pendingByParent)
      y += childHeight + pending.gap
  of RowLayout:
    let
      availableWidth = max(parentFrame.width - pending.padding.left -
          pending.padding.right, 0.0)
      availableHeight = max(parentFrame.height - pending.padding.top -
          pending.padding.bottom, 0.0)
    var fixedWidth = pending.gap * max(pending.children.len - 1, 0).toFloat
    var fillCount = 0
    for child in pending.children:
      if child.widthPolicy.kind == WidgetFill:
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
        parentFrame.x + pending.padding.left + (availableWidth - contentWidth) / 2.0
      of JustifyEnd:
        parentFrame.x + parentFrame.width - pending.padding.right - contentWidth
      of JustifyStart:
        parentFrame.x + pending.padding.left
    for child in pending.children:
      let childWidth =
        if child.widthPolicy.kind == WidgetFill:
          let preferred = self.preferredWidth(child, pendingByParent)
          (if pending.scrollX: max(fillWidth,
              preferred) else: fillWidth).clampPolicy(
            child.widthPolicy
          )
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
          parentFrame.y + pending.padding.top + (availableHeight -
              childHeight) / 2.0
        of AlignEnd:
          parentFrame.y + parentFrame.height - pending.padding.bottom - childHeight
        else:
          parentFrame.y + pending.padding.top
      child.setFrame(Frame(x: x, y: y, width: childWidth, height: childHeight))
      if pendingByParent.hasKey(child.id):
        self.assignDirectStack(pendingByParent[child.id], pendingByParent)
      x += childWidth + pending.gap
  of OverlayLayout:
    let
      availableWidth = max(parentFrame.width - pending.padding.left -
          pending.padding.right, 0.0)
      availableHeight = max(parentFrame.height - pending.padding.top -
          pending.padding.bottom, 0.0)
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
          parentFrame.x + pending.padding.left + (availableWidth - childWidth) / 2.0
        of AlignEnd:
          parentFrame.x + parentFrame.width - pending.padding.right - childWidth
        else:
          parentFrame.x + pending.padding.left
      let y =
        case pending.justifyContent
        of JustifyCenter:
          parentFrame.y + pending.padding.top + (availableHeight -
              childHeight) / 2.0
        of JustifyEnd:
          parentFrame.y + parentFrame.height - pending.padding.bottom - childHeight
        of JustifyStart:
          parentFrame.y + pending.padding.top
      child.setFrame(Frame(x: x, y: y, width: childWidth, height: childHeight))
      if pendingByParent.hasKey(child.id):
        self.assignDirectStack(pendingByParent[child.id], pendingByParent)

proc endLayout*(self: var UI): bool {.discardable.} =
  ## Finish the frame's layout, solve it, and report whether it worked.
  ##
  ## Applies the row, column and overlay arrangements collected while the
  ## frame was declared, places floating widgets over the rest, and solves
  ## the constraint system. Returns false when the constraints turned out to
  ## be unsatisfiable, leaving the previous solution in place.
  if self.frames.len == 1 and self.frames[0].children.len > 0:
    let children = self.frames[0].children
    self.pendingLayouts.add PendingLayout(
      kind: ColumnLayout,
      parent: self.root,
      children: children,
      gap: 0.0,
      padding: insets(0.0),
      alignItems: AlignStretch,
      justifyContent: JustifyStart,
      scrollX: false,
      scrollY: false,
      scrollWheel: true,
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
    elif pending.parent.id in self.centeredFloatingWidgets:
      directParents.incl pending.parent.id
    elif pending.parent.id in scrollParentIDs or
        pending.parent.id.hasScrollAncestor():
      directParents.incl pending.parent.id

  for i in countdown(self.pendingLayouts.high, 0):
    let pending = self.pendingLayouts[i]
    self.layoutChildren[pending.parent.id] = pending.children
    if pending.scrollX or pending.scrollY:
      self.scrollContainers.incl pending.parent.id
      if pending.scrollWheel:
        self.scrollWheelContainers.incl pending.parent.id
    if pending.parent.id in directParents:
      continue
    case pending.kind
    of RowLayout:
      self.layout.row(
        pending.parent,
        pending.children,
        gap = pending.gap,
        paddingLeft = pending.padding.left,
        paddingTop = pending.padding.top,
        paddingRight = pending.padding.right,
        paddingBottom = pending.padding.bottom,
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
        paddingLeft = pending.padding.left,
        paddingTop = pending.padding.top,
        paddingRight = pending.padding.right,
        paddingBottom = pending.padding.bottom,
        alignItems = pending.alignItems,
        justifyContent = pending.justifyContent,
        scrollX = pending.scrollX,
        scrollY = pending.scrollY,
      )
    of OverlayLayout:
      self.layout.overlay(
        pending.parent,
        pending.children,
        paddingLeft = pending.padding.left,
        paddingTop = pending.padding.top,
        paddingRight = pending.padding.right,
        paddingBottom = pending.padding.bottom,
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
    var staleTooltipKeys: seq[WidgetID]
    for id in self.tooltipTexts.keys:
      if id notin self.liveWidgetIDs:
        staleTooltipKeys.add id
    for id in staleTooltipKeys:
      self.tooltipTexts.del id
    self.previousWidgetIDs = self.liveWidgetIDs
    var staleRealtimeKeys: seq[WidgetID]
    for id in self.retainedRealtimeWidgets.keys:
      if id notin self.liveRealtimeWidgetIDs:
        staleRealtimeKeys.add id
    for id in staleRealtimeKeys:
      self.retainedRealtimeWidgets.del id
    var staleAnimationKeys: seq[WidgetID]
    for id in self.animations.keys:
      if id notin self.liveAnimationIDs:
        staleAnimationKeys.add id
    for id in staleAnimationKeys:
      self.animations.del id
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
        elif parentID in self.centeredFloatingWidgets:
          let
            parent = pendingByParent[parentID].parent
            rootFrame = self.root.frame
            width = min(self.preferredWidth(parent, pendingByParent),
                rootFrame.width)
            height = min(self.preferredHeight(parent, pendingByParent),
                rootFrame.height)
            x = rootFrame.x + max((rootFrame.width - width) / 2.0, 0.0)
            y = rootFrame.y + max((rootFrame.height - height) / 2.0, 0.0)
          parent.setFrame(Frame(x: x, y: y, width: width, height: height))
          self.assignDirectStack(pendingByParent[parentID], pendingByParent)
        elif parentID in self.scrollContainers:
          self.assignDirectStack(pendingByParent[parentID], pendingByParent)
    self.applyScrollOffsets()
    self.frameByID.clear()
    for box in self.layout.boxes:
      self.frameByID[box.id] = box.frame
    self.pointerBlockFrames.setLen(0)
    self.pointerInteractiveFrames.setLen(0)
    for (component, widget) in self.components:
      if component of Interactive:
        self.pointerInteractiveFrames.add widget.frame
      if component of Interactive or component.style.hasBackground:
        self.pointerBlockFrames.add widget.frame
      if widget.id in self.liveRealtimeWidgetIDs:
        self.retainedRealtimeWidgets[widget.id] = (component, widget)
    self.retainedRoot = self.root
    self.retainedComponents = self.components
    self.retainedComponentByID = self.componentByID
    self.retainedLayoutChildren = self.layoutChildren
    self.retainedFloatingWidgets = self.floatingWidgets
    self.retainedModalWidgets = self.modalWidgets
    self.retainedScrollContainers = self.scrollContainers
    self.retainedScrollWheelContainers = self.scrollWheelContainers
    self.retainedFrameValid = true

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

proc peekChildren(self: UI): seq[Widget] =
  ## Return the children collected for the current parent, leaving them in
  ## place for the arrangement that follows.
  if self.frames.len == 0:
    self.childrenWidgets
  else:
    self.frames[^1].children

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
  ## Capture the widgets declared in `body` instead of adding them to the
  ## current parent.
  ##
  ## The captured widgets can then be handed to `place`, which is how a
  ## container fills its named slots. Yields an empty slot during the event
  ## phase, where no widgets are built.
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
  ## Capture exactly one widget declared in `body`.
  ##
  ## Raises `ValueError` when `body` declared anything other than a single
  ## widget.
  block:
    let captured {.gensym.} = self.slot:
      body
    if captured.len != 1:
      raise newException(
        ValueError, "expected exactly one widget in slot, got " & $captured.len
      )
    captured[0]

proc place*(self: var UI, slot: WidgetSlot) {.layoutOnly.} =
  ## Add the widgets captured in `slot` to the current parent.
  self.addChildren(slot)

proc place*(self: var UI, widget: Widget) {.layoutOnly.} =
  ## Add a captured `widget` to the current parent.
  self.addChild(widget)

proc attach*(self: var UI, widget: Widget,
    component: Component) {.layoutOnly.} =
  ## Attach `component` to `widget`, making it what the widget measures,
  ## updates and draws as.
  self.components.add((component, widget))
  self.componentByID[widget.id] = component

proc applyIntrinsicSizes*(self: UI, resources: Resources) =
  ## Measure every component whose widget fits its content and constrain the
  ## widget to that size.
  ##
  ## Call this after the frame's widgets are declared and before solving, so
  ## `fit` policies have something to resolve to.
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
  ## Run `body` only while events are being dispatched.
  ##
  ## Use it for the frame's event handling, which would otherwise run a
  ## second time as the widget tree is built.
  if self.phase == EventPhase:
    body

template animated*(
    self: var UI,
    id: WidgetID,
    open: bool = true,
    spec: AnimationSpec = dialogPopIn(),
    body: untyped,
) =
  ## Declare `body` normally and animate the subtree rooted at `id`.
  ##
  ## The widget with `id` must be declared inside `body`; the declaration is
  ## still immediate-mode, while animation progress is retained by the UI.
  block:
    if self.phase == LayoutPhase:
      discard self.animate(id, open, spec)
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
  ## Run one frame of the UI against explicit update and draw contexts.
  ##
  ## `blk` is the frame's declarations, and is run twice: once to dispatch
  ## events and once to build the widget tree, which is then solved, updated
  ## and drawn. Use the single-context overload unless the caller keeps its
  ## own contexts. Whether the frame drew anything is reported by
  ## `redrewFrame`.
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
  var savedIdScopes {.gensym.}: seq[string]
  for scope in ui.idScopes:
    savedIdScopes.add(scope)
  ui.beginEvents(drawContext)
  blk

  ui.phase = LayoutPhase
  var layoutOk {.gensym.} = false
  try:
    ui.beginLayout(drawContext.windowWidth, drawContext.windowHeight)
    ui.idScopes = savedIdScopes
    blk
    ui.applyIntrinsicSizes(drawContext.resources)
    layoutOk = ui.endLayout()
  except InternalSolverError, UnsatisfiableConstraintError:
    layoutOk = false

  if layoutOk:
    if drawContext.focusedWidget != InvalidWidgetID and
        not ui.liveWidget(drawContext.focusedWidget):
      drawContext.focusedWidget = InvalidWidgetID
      updateContext.focusedWidget = InvalidWidgetID
      ui.eventFocusedWidget = InvalidWidgetID
      ui.markAllDirty()
    let beforeHot {.gensym.} = drawContext.hotWidgets
    let beforeActive {.gensym.} = drawContext.activeWidgets
    let beforeSubmitted {.gensym.} = drawContext.submittedWidgets
    let beforeFocused {.gensym.} = drawContext.focusedWidget
    updateContext.hotWidgets.clear()
    updateContext.activeWidgets.clear()
    updateContext.dirtyWidgets.clear()
    updateContext.resources = drawContext.resources
    updateContext.sliderDragging =
      if updateContext.mouseLeftDown: drawContext.sliderDragging else: InvalidWidgetID
    ui.update(updateContext)
    for id {.gensym.} in updateContext.dirtyWidgets.items:
      ui.markDirty(id)
    ui.markStateChanges(
      beforeHot, beforeActive, beforeSubmitted, beforeFocused, updateContext
    )
    switchState(updateContext, drawContext)
    ui.evaluateTooltipHover()
    ui.frameRedrawn = ui.draw(drawContext)
    if drawContext.hasRedrawRequest:
      ui.requestRedrawAfterSafe(drawContext.redrawDelayMs)
      drawContext.dirtyAll = true
  else:
    updateContext.hotWidgets.clear()
    updateContext.activeWidgets.clear()
  ui.reset()
  ui.idScopes = savedIdScopes

template layout*(ui: var UI, blk: untyped): auto =
  ## Run one frame of the UI.
  ##
  ## `blk` is the frame's declarations, and is run twice: once to dispatch
  ## events and once to build the widget tree. The tree is then solved,
  ## updated against this frame's input, and drawn, either fully or as an
  ## incremental redraw of what changed. A layout that cannot be solved is
  ## skipped, leaving the previous frame on screen; whether this frame drew
  ## anything is reported by `redrewFrame`.
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
  var savedIdScopes {.gensym.}: seq[string]
  for scope in ui.idScopes:
    savedIdScopes.add(scope)
  ui.beginEvents(ui.context.draw)
  blk

  ui.phase = LayoutPhase
  var layoutOk {.gensym.} = false
  try:
    ui.beginLayout(ui.context.draw.windowWidth, ui.context.draw.windowHeight)
    ui.idScopes = savedIdScopes
    blk
    ui.applyIntrinsicSizes(ui.context.draw.resources)
    layoutOk = ui.endLayout()
  except InternalSolverError, UnsatisfiableConstraintError:
    layoutOk = false

  if layoutOk:
    if ui.context.draw.focusedWidget != InvalidWidgetID and
        not ui.liveWidget(ui.context.draw.focusedWidget):
      ui.context.draw.focusedWidget = InvalidWidgetID
      ui.context.update.focusedWidget = InvalidWidgetID
      ui.eventFocusedWidget = InvalidWidgetID
      ui.markAllDirty()
    let beforeHot {.gensym.} = ui.context.draw.hotWidgets
    let beforeActive {.gensym.} = ui.context.draw.activeWidgets
    let beforeSubmitted {.gensym.} = ui.context.draw.submittedWidgets
    let beforeFocused {.gensym.} = ui.context.draw.focusedWidget
    ui.context.update.hotWidgets.clear()
    ui.context.update.activeWidgets.clear()
    ui.context.update.dirtyWidgets.clear()
    ui.context.update.resources = ui.context.draw.resources
    ui.context.update.sliderDragging =
      if ui.context.update.mouseLeftDown:
        ui.context.draw.sliderDragging
      else:
        InvalidWidgetID
    ui.update(ui.context.update)
    for id {.gensym.} in ui.context.update.dirtyWidgets.items:
      ui.markDirty(id)
    ui.markStateChanges(
      beforeHot, beforeActive, beforeSubmitted, beforeFocused, ui.context.update
    )
    switchState(ui.context.update, ui.context.draw)
    ui.evaluateTooltipHover()
    ui.frameRedrawn = ui.draw(ui.context.draw)
    if ui.context.draw.hasRedrawRequest:
      ui.requestRedrawAfterSafe(ui.context.draw.redrawDelayMs)
      ui.markAllDirty()
  else:
    ui.context.update.hotWidgets.clear()
    ui.context.update.activeWidgets.clear()
  ui.reset()
  ui.idScopes = savedIdScopes

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
  if parent.frame.contains(context.mouseX, context.mouseY) and
      parent.id in self.scrollWheelContainers:
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
    self.requestRedrawAfterSafe(16)

const PointerAway = -1_000_000
  ## A pointer position no widget can contain, which is how a widget under a
  ## shielded surface is updated: it sees a pointer that is nowhere near it.

template withoutPointer(context: var UpdateContext, body: untyped) =
  ## Run `body` with the pointer moved out of reach and its buttons up.
  ##
  ## Keyboard state is left alone, so a focused widget keeps taking keys.
  let
    mouseX {.gensym.} = context.mouseX
    mouseY {.gensym.} = context.mouseY
    leftDown {.gensym.} = context.mouseLeftDown
    leftPressed {.gensym.} = context.mouseLeftPressed
    middleDown {.gensym.} = context.mouseMiddleDown
    middlePressed {.gensym.} = context.mouseMiddlePressed
    rightPressed {.gensym.} = context.mouseRightPressed
    wheelX {.gensym.} = context.mouseWheelX
    wheelY {.gensym.} = context.mouseWheelY
  context.mouseX = PointerAway
  context.mouseY = PointerAway
  context.mouseLeftDown = false
  context.mouseLeftPressed = false
  context.mouseMiddleDown = false
  context.mouseMiddlePressed = false
  context.mouseRightPressed = false
  context.mouseWheelX = 0
  context.mouseWheelY = 0
  try:
    body
  finally:
    context.mouseX = mouseX
    context.mouseY = mouseY
    context.mouseLeftDown = leftDown
    context.mouseLeftPressed = leftPressed
    context.mouseMiddleDown = middleDown
    context.mouseMiddlePressed = middlePressed
    context.mouseRightPressed = rightPressed
    context.mouseWheelX = wheelX
    context.mouseWheelY = wheelY

proc updateWidgetTree(
    self: var UI,
    widget: Widget,
    components: Table[WidgetID, Component],
    context: var UpdateContext,
    clipped = false,
    shieldOwner = InvalidWidgetID,
    blocked = false,
) =
  let widgetBlocked = blocked and widget.id != shieldOwner
  if widgetBlocked:
    withoutPointer(context):
      self.updateScrollbarDrag(widget, context)
      if components.hasKey(widget.id):
        components[widget.id].update(widget, context)
  else:
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
    self.updateWidgetTree(
      child, components, context, childClipped, shieldOwner, widgetBlocked
    )

proc update*(self: var UI, context: var UpdateContext) =
  ## Update every component in the tree against `context`, floating widgets
  ## included.
  ##
  ## A surface that covers other widgets takes the pointer for itself: while
  ## the pointer is over a floating card, a menu popover or an open dropdown
  ## list, every widget outside it is updated as though the pointer were
  ## nowhere near, so a click cannot land on two surfaces at once.
  let shieldOwner = self.pointerSurfaceWidget
  let blocked = shieldOwner != InvalidWidgetID
  self.updateWidgetTree(
    self.root, self.componentByID, context, false, shieldOwner, blocked
  )
  for widget in self.floatingWidgets:
    self.updateWidgetTree(
      widget, self.componentByID, context, false, shieldOwner, blocked
    )

proc draw*(self: UI, context: var DrawContext): bool {.discardable.} =
  ## Draw the widget tree into `context` and report whether anything was
  ## drawn.
  ##
  ## Returns false without drawing when nothing has been marked dirty.
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

  proc drawWidgetTree(widget: Widget, inheritedDirty = false, replaying = false)

  proc animationActive(id: WidgetID): bool =
    if id notin self.animations:
      return false
    let value = self.animations[id].value
    value.running or abs(value.opacity - 1.0) > 0.001 or
      abs(value.scale - 1.0) > 0.001 or abs(value.offsetX) > 0.001 or
      abs(value.offsetY) > 0.001

  proc drawAnimatedSubtree(widget: Widget, inheritedDirty: bool) =
    let value = self.animations[widget.id].value
    var commands: seq[DrawCommand]
    let
      previousCommands = screen.drawCommands
      previousContextCommands = drawContext.drawCommands
    screen.drawCommands = addr commands
    drawContext.drawCommands = addr commands
    drawWidgetTree(widget, inheritedDirty, true)
    screen.drawCommands = previousCommands
    drawContext.drawCommands = previousContextCommands
    let
      f = widget.frame
      originX = f.x + f.width * 0.5
      originY = f.y + f.height * 0.5
    for command in commands:
      replayDrawCommand(
        command,
        originX,
        originY,
        value.scale,
        value.opacity,
        value.offsetX,
        value.offsetY,
      )

  proc drawWidgetTree(widget: Widget, inheritedDirty = false,
      replaying = false) =
    if not replaying and widget.id.animationActive():
      drawAnimatedSubtree(widget, inheritedDirty)
      return
    let dirty =
      drawContext.dirtyAll or inheritedDirty or widget.id in
          drawContext.dirtyWidgets
    if dirty and self.componentByID.hasKey(widget.id) and
        not self.retainedRealtimeWidgets.hasKey(widget.id):
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
        drawWidgetTree(child, dirty, replaying)
      restoreState()
      drawContext.hasClip = previousHasClip
      drawContext.clipRect = previousClip
      if dirty:
        drawScrollbars(widget)
    else:
      for child in self.layoutChildren.getOrDefault(widget.id):
        drawWidgetTree(child, dirty, replaying)

  drawWidgetTree(self.root)
  for widget in self.floatingWidgets:
    drawWidgetTree(widget, true)
  for (component, widget) in self.components:
    if not self.retainedRealtimeWidgets.hasKey(widget.id):
      component.drawOverlay(widget, drawContext)
  context.hasRedrawRequest = drawContext.hasRedrawRequest
  context.redrawDelayMs = drawContext.redrawDelayMs
  context.dirtyWidgets.clear()
  context.dirtyAll = false
  true

proc drawRealtime*(self: var UI): bool {.discardable.} =
  ## Redraw only the animating widgets of the retained frame, and report
  ## whether anything was drawn.
  ##
  ## Returns false when the retained frame holds no animating widget.
  if self.retainedRealtimeWidgets.len == 0:
    return false

  var
    updateContext = self.context.update
    drawContext = self.context.draw
  updateContext.resources = drawContext.resources
  updateContext.sliderDragging =
    if updateContext.mouseLeftDown: drawContext.sliderDragging else: InvalidWidgetID

  let previousDrawCommands = screen.drawCommands
  let previousCommandMeasureImage = screen.commandMeasureImage
  screen.drawCommands = drawContext.drawCommands
  screen.commandMeasureImage = drawContext.commandMeasureImage
  defer:
    screen.drawCommands = previousDrawCommands
    screen.commandMeasureImage = previousCommandMeasureImage

  for (component, widget) in self.retainedRealtimeWidgets.values:
    component.update(widget, updateContext)
    component.draw(widget, drawContext)
    component.drawOverlay(widget, drawContext)

  self.context.update = updateContext
  self.context.draw.hasRedrawRequest = drawContext.hasRedrawRequest
  self.context.draw.redrawDelayMs = drawContext.redrawDelayMs
  if drawContext.hasRedrawRequest:
    self.requestRedrawAfterSafe(drawContext.redrawDelayMs)
  self.frameRedrawn = true
  true

proc drawRetainedFrame*(self: var UI): bool {.discardable.} =
  ## Repaint the last solved frame without re-evaluating Owl or solving layout.
  if not self.retainedFrameValid:
    return false
  let
    root = self.root
    components = self.components
    componentByID = self.componentByID
    layoutChildren = self.layoutChildren
    floatingWidgets = self.floatingWidgets
    scrollContainers = self.scrollContainers
    scrollWheelContainers = self.scrollWheelContainers
  self.root = self.retainedRoot
  self.components = self.retainedComponents
  self.componentByID = self.retainedComponentByID
  self.layoutChildren = self.retainedLayoutChildren
  self.floatingWidgets = self.retainedFloatingWidgets
  self.scrollContainers = self.retainedScrollContainers
  self.scrollWheelContainers = self.retainedScrollWheelContainers
  self.advanceAnimations()
  self.context.draw.dirtyAll = true
  self.evaluateTooltipHover()
  result = self.draw(self.context.draw)
  self.root = root
  self.components = components
  self.componentByID = componentByID
  self.layoutChildren = layoutChildren
  self.floatingWidgets = floatingWidgets
  self.scrollContainers = scrollContainers
  self.scrollWheelContainers = scrollWheelContainers
  if result:
    if self.context.draw.hasRedrawRequest:
      self.requestRedrawAfterSafe(self.context.draw.redrawDelayMs)
    self.frameRedrawn = true

proc updateRetainedFrame*(self: var UI): bool {.discardable.} =
  ## Update hit testing and repaint the last solved frame without re-evaluating Owl.
  if not self.retainedFrameValid:
    return false
  let
    root = self.root
    components = self.components
    componentByID = self.componentByID
    layoutChildren = self.layoutChildren
    floatingWidgets = self.floatingWidgets
    scrollContainers = self.scrollContainers
    scrollWheelContainers = self.scrollWheelContainers
  self.root = self.retainedRoot
  self.components = self.retainedComponents
  self.componentByID = self.retainedComponentByID
  self.layoutChildren = self.retainedLayoutChildren
  self.floatingWidgets = self.retainedFloatingWidgets
  self.scrollContainers = self.retainedScrollContainers
  self.scrollWheelContainers = self.retainedScrollWheelContainers
  self.advanceAnimations()

  let
    beforeHot = self.context.draw.hotWidgets
    beforeActive = self.context.draw.activeWidgets
    beforeSubmitted = self.context.draw.submittedWidgets
    beforeFocused = self.context.draw.focusedWidget
  self.context.update.hotWidgets.clear()
  self.context.update.activeWidgets.clear()
  self.context.update.dirtyWidgets.clear()
  self.context.update.resources = self.context.draw.resources
  self.context.update.sliderDragging =
    if self.context.update.mouseLeftDown:
      self.context.draw.sliderDragging
    else:
      InvalidWidgetID
  self.update(self.context.update)
  for id in self.context.update.dirtyWidgets.items:
    self.markDirty(id)
  self.markStateChanges(
    beforeHot, beforeActive, beforeSubmitted, beforeFocused, self.context.update
  )
  switchState(self.context.update, self.context.draw)
  self.evaluateTooltipHover()
  self.frameRedrawn = self.draw(self.context.draw)
  if self.context.draw.hasRedrawRequest:
    self.requestRedrawAfterSafe(self.context.draw.redrawDelayMs)
  result = self.frameRedrawn

  self.root = root
  self.components = components
  self.componentByID = componentByID
  self.layoutChildren = layoutChildren
  self.floatingWidgets = floatingWidgets
  self.scrollContainers = scrollContainers
  self.scrollWheelContainers = scrollWheelContainers

proc row*(self: var UI, config: BoxConfig) {.layoutOnly.} =
  ## Arrange the current parent's children in a row.
  ##
  ## The `row` template is the usual way to declare one; this is the
  ## arrangement step on its own.
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
    scrollWheel: config.scrollWheel,
  )

proc column*(self: var UI, config: BoxConfig) {.layoutOnly.} =
  ## Arrange the current parent's children in a column.
  ##
  ## The `column` template is the usual way to declare one; this is the
  ## arrangement step on its own.
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
    scrollWheel: config.scrollWheel,
  )

proc overlay*(self: var UI, config: BoxConfig) {.layoutOnly.} =
  ## Stack the current parent's children on top of each other.
  ##
  ## The `overlay` template is the usual way to declare one; this is the
  ## arrangement step on its own.
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
    scrollWheel: config.scrollWheel,
  )

template row*(self: var UI, id: WidgetID, config: BoxConfig, body: untyped) =
  ## Declare a row widget with the id `id`, laying the widgets declared in
  ## `body` out left to right as configured by `config`.
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

template row*(self: var UI, config: BoxConfig, body: untyped) =
  ## Same as the overload taking an explicit `id`, with a generated id, so the widgets inside stay distinct from those of any other unnamed box.
  block:
    if self.phase == EventPhase:
      body
      discard
    else:
      body
      discard
      self.row(config)

template column*(self: var UI, id: WidgetID, config: BoxConfig, body: untyped) =
  ## Declare a column widget with the id `id`, laying the widgets declared in
  ## `body` out top to bottom as configured by `config`.
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

template column*(self: var UI, config: BoxConfig, body: untyped) =
  ## Same as the overload taking an explicit `id`, with a generated id, so the widgets inside stay distinct from those of any other unnamed box.
  block:
    if self.phase == EventPhase:
      body
      discard
    else:
      body
      discard
      self.column(config)

template overlay*(self: var UI, id: WidgetID, config: BoxConfig,
    body: untyped) =
  ## Declare an overlay widget with the id `id`, stacking the widgets
  ## declared in `body` on top of each other as configured by `config`.
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

template overlay*(self: var UI, config: BoxConfig, body: untyped) =
  ## Same as the overload taking an explicit `id`, with a generated id, so the widgets inside stay distinct from those of any other unnamed box.
  block:
    if self.phase == EventPhase:
      body
      discard
    else:
      body
      discard
      self.overlay(config)

template center*(self: var UI, id: WidgetID, w = fill(), h = fill(),
    body: untyped) =
  ## Declare a box with the id `id` of size `w` by `h` that centres the single
  ## widget declared in `body`.
  ##
  ## Raises `ValueError` when `body` declared anything other than one widget.
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
      let captured = self.peekChildren()
      if captured.len != 1:
        raise newException(
          ValueError, "expected exactly one centered widget, got " & $captured.len
        )
      # An arrangement rather than bare constraints, so a centred box works
      # inside a scroll container too, where children are placed directly
      # instead of being solved.
      self.overlay(cfg(width = w, height = h, alignItems = AlignCenter,
          justifyContent = JustifyCenter))
      discard self.popLayout()

template center*(self: var UI, w = fill(), h = fill(), body: untyped) =
  ## Same as the overload taking an explicit `id`, with a generated id, so the widgets inside stay distinct from those of any other unnamed box.
  self.autoScoped:
    self.center(autoID, w, h):
      body

template panel*(self: var UI, id: WidgetID, config: BoxConfig, body: untyped) =
  ## Declare a panel with the id `id`: a background surface holding the
  ## widgets declared in `body` as a column.
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

template panel*(self: var UI, config: BoxConfig, body: untyped) =
  ## Same as the overload taking an explicit `id`, with a generated id, so the widgets inside stay distinct from those of any other unnamed box.
  self.autoScoped:
    self.panel(autoID, config):
      body

template card*(self: var UI, id: WidgetID, config: BoxConfig, body: untyped) =
  ## Declare a card with the id `id`: a raised, bordered surface holding the
  ## widgets declared in `body` as a column.
  ##
  ## A card also swallows pointer presses that land on it.
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

template card*(self: var UI, config: BoxConfig, body: untyped) =
  ## Same as the overload taking an explicit `id`, with a generated id, so the widgets inside stay distinct from those of any other unnamed box.
  self.autoScoped:
    self.card(autoID, config):
      body

template floatingCardBelow*(
    self: var UI, id: WidgetID, anchorID: WidgetID, config: BoxConfig, body: untyped
) =
  ## Declare a floating card with the id `id`, positioned under the widget
  ## `anchorID`.
  ##
  ## The card is laid out over the rest of the frame rather than among its
  ## siblings, which is what a dropdown or a popover needs, and holds the
  ## widgets declared in `body` as a column.
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
  ## Declare a dialog header with the id `id`, holding the widgets declared in
  ## `body`.
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

template dialogHeader*(self: var UI, config: BoxConfig, body: untyped) =
  ## Same as the overload taking an explicit `id`, with a generated id, so the widgets inside stay distinct from those of any other unnamed box.
  self.autoScoped:
    self.dialogHeader(autoID, config):
      body

template modalDialog*(
    self: var UI, id: WidgetID, open: bool, config: BoxConfig, body: untyped
) =
  ## Declare a modal dialog with the id `id`, shown while `open` is true.
  ##
  ## The dialog is laid out over the rest of the frame and centred in the
  ## window, holding the widgets declared in `body` as a column. While it is
  ## open it owns the pointer everywhere, so nothing behind it reacts, which
  ## is what makes it modal. Nothing is declared at all while `open` is
  ## false.
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
        self.floatingWidgets.add layoutParent
        self.centeredFloatingWidgets.incl id
        self.modalWidgets.incl id
        self.pushLayout(layoutParent)
        body
        discard
        self.column(config)
        discard self.popFloatingLayout()

template resizableModalDialog*(
    self: var UI,
    dialogWidgetID: WidgetID,
    open: bool,
    dialogWidth: var float64,
    dialogHeight: var float64,
    minWidth: float64,
    minHeight: float64,
    maxWidth: float64,
    maxHeight: float64,
    config: BoxConfig,
    body: untyped,
) =
  ## Declare a centered modal dialog with a bottom-right resize handle.
  block:
    if open:
      let dialogID {.gensym.} = dialogWidgetID
      let handleID {.gensym.} = self.id(dialogID, "resize")
      if self.phase == EventPhase:
        body
        discard
        self.resizeFloating(handleID, dialogWidth, dialogHeight, minWidth, minHeight,
            maxWidth, maxHeight)
      else:
        dialogWidth = dialogWidth.clamp(minWidth, maxWidth)
        dialogHeight = dialogHeight.clamp(minHeight, maxHeight)
        var dialogConfig {.gensym.} = config
        dialogConfig.width = fixed(dialogWidth)
        dialogConfig.height = fixed(dialogHeight)
        self.modalDialog(dialogID, true, dialogConfig):
          body
          self.row(self.id(dialogID, "resize-row"), cfg(width = fill(), height = fit(),
              gap = 0, justifyContent = JustifyEnd)):
            discard self.button(handleID, "◢", width = fixed(28),
                height = fixed(24), buttonPadding = 0)

template menuBar*(self: var UI, id: WidgetID, config: BoxConfig,
    body: untyped) =
  ## Declare a menu bar with the id `id`, laying the entries declared in
  ## `body` out as a row.
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

template menuBar*(self: var UI, config: BoxConfig, body: untyped) =
  ## Same as the overload taking an explicit `id`, with a generated id.
  self.autoScoped:
    self.menuBar(autoID, config):
      body

template table*(self: var UI, id: WidgetID, config: BoxConfig, body: untyped) =
  ## Declare a table with the id `id`, holding the rows declared in `body`.
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

template table*(self: var UI, config: BoxConfig, body: untyped) =
  ## Same as the overload taking an explicit `id`, with a generated id.
  self.autoScoped:
    self.table(autoID, config):
      body

template tableHeader*(self: var UI, id: WidgetID, config: BoxConfig,
    body: untyped) =
  ## Declare a table header with the id `id`, holding the header cells
  ## declared in `body` as a row.
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

template tableHeader*(self: var UI, config: BoxConfig, body: untyped) =
  ## Same as the overload taking an explicit `id`, with a generated id.
  self.autoScoped:
    self.tableHeader(autoID, config):
      body

template tableRow*(self: var UI, id: WidgetID, config: BoxConfig,
    body: untyped) =
  ## Declare a table row with the id `id`, holding the cells declared in
  ## `body` as a row.
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

template tableRow*(self: var UI, config: BoxConfig, body: untyped) =
  ## Same as the overload taking an explicit `id`, with a generated id.
  self.autoScoped:
    self.tableRow(autoID, config):
      body

template tableCell*(self: var UI, id: WidgetID, config: BoxConfig,
    body: untyped) =
  ## Declare a table cell with the id `id`, holding the widgets declared in
  ## `body`.
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

template tableCell*(self: var UI, config: BoxConfig, body: untyped) =
  ## Same as the overload taking an explicit `id`, with a generated id.
  self.autoScoped:
    self.tableCell(autoID, config):
      body

proc box*(
    self: var UI, id: WidgetID, width = fill(),
    height = fill(), alignSelf = AlignAuto
): Widget =
  ## Create a box widget with the id `id` and mark it live for this frame.
  ##
  ## The box is not added to the current parent; the widget helpers do that
  ## once they have attached a component to it.
  self.liveWidgetIDs.incl id
  self.layout.box(id, width = width, height = height).withAlignSelf(alignSelf)

proc container*(
    self: var UI,
    id: WidgetID,
    component: Container,
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
): Widget {.discardable, layoutOnly.} =
  ## Declare a container widget with the id `id` and `component` attached, and
  ## return it.
  ##
  ## Containers hold other widgets in their slots; see `slot` and `place`.
  result = self.box(id, width = width, height = height, alignSelf = alignSelf)
  self.setRenderKey(id, renderKey("container", width, height, alignSelf))
  self.attach(result, Component(component))
  self.addChild(result)

proc component*(
    self: var UI,
    id: WidgetID,
    component: Component,
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
    renderKeyOverride = "",
): Widget {.discardable, layoutOnly.} =
  ## Declare a widget with the id `id` and `component` attached, and return it.
  ##
  ## `renderKeyOverride` replaces the key used to decide when the widget
  ## needs redrawing, which a component whose appearance depends on more than
  ## its size and alignment needs to supply.
  result = self.box(id, width = width, height = height, alignSelf = alignSelf)
  let key =
    if renderKeyOverride.len > 0:
      renderKeyOverride
    else:
      renderKey("component", width, height, alignSelf)
  self.setRenderKey(id, key)
  self.attach(result, component)
  self.addChild(result)

proc spacer*(
    self: var UI, id: WidgetID, width = fill(),
    height = fill(), alignSelf = AlignAuto
): Widget {.discardable, layoutOnly.} =
  ## Declare an empty box that only takes up space.
  result = self.box(id, width = width, height = height, alignSelf = alignSelf)
  self.setRenderKey(id, renderKey("spacer", width, height, alignSelf))
  self.addChild(result)

proc button*(
    ui: var UI,
    id: WidgetID,
    label: string,
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
    textScroll = false,
    fontName = "font",
    buttonPadding = insets(-1.0),
    buttonBorderStyle = ButtonBorderLine,
    buttonChromeStyle = ButtonChromeRaised,
    buttonTextAlign = JustifyCenter,
    buttonVariant = ButtonNormal,
    style = ComponentStyle(),
): bool {.discardable.} =
  ## Declare a button with the id `id` labelled `label`.
  ##
  ## Returns true on the frame it is clicked. `textScroll` lets a label wider
  ## than the button scroll, `buttonPadding` overrides the insets around the
  ## text, and `style` sets an explicit background or opacity.
  if ui.phase == EventPhase:
    return ui.clicked(id)
  var variantConfig = cfg()
  variantConfig.style = style
  variantConfig.buttonPadding = buttonPadding
  variantConfig.buttonBorderStyle = buttonBorderStyle
  variantConfig.buttonChromeStyle = buttonChromeStyle
  variantConfig.buttonTextAlign = buttonTextAlign
  if buttonVariant != ButtonNormal:
    variantConfig = variantConfig.applyButtonVariant(buttonVariant)
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(
    id,
    renderKey("button:" & label & ":" & $textScroll & ":" & fontName & ":" &
        $variantConfig.buttonPadding.left & "," &
        $variantConfig.buttonPadding.top & "," &
        $variantConfig.buttonPadding.right & "," &
        $variantConfig.buttonPadding.bottom, width, height, alignSelf) & "|" &
      $variantConfig.buttonBorderStyle & "|" & $variantConfig.buttonChromeStyle &
      "|" & $variantConfig.buttonTextAlign & "|" &
      styleRenderKey(variantConfig.style),
  )
  let btn = Button.new(label, textScroll, fontName, variantConfig.buttonPadding,
      variantConfig.buttonBorderStyle, variantConfig.buttonChromeStyle,
      variantConfig.buttonTextAlign)
  btn.style = variantConfig.style
  ui.attach(box, Component(btn))
  ui.addChild(box)

proc button*(
    ui: var UI,
    id: WidgetID,
    label: string,
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
    textScroll = false,
    fontName = "font",
    buttonPadding: float64,
    buttonBorderStyle = ButtonBorderLine,
    buttonChromeStyle = ButtonChromeRaised,
    buttonTextAlign = JustifyCenter,
    buttonVariant = ButtonNormal,
    style = ComponentStyle(),
): bool {.discardable.} =
  ## Declare a button with the same `buttonPadding` on every edge.
  ui.button(
    id,
    label,
    width,
    height,
    alignSelf,
    textScroll,
    fontName,
    insets(buttonPadding),
    buttonBorderStyle = buttonBorderStyle,
    buttonChromeStyle = buttonChromeStyle,
    buttonTextAlign = buttonTextAlign,
    buttonVariant = buttonVariant,
    style = style,
  )

proc menu*(
    ui: var UI,
    id: WidgetID,
    label: string,
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
): bool {.discardable.} =
  ## Declare a menu bar entry with the id `id` labelled `label`.
  ##
  ## Returns true on the frame it is clicked, which is when the caller should
  ## open or close its menu.
  if ui.phase == EventPhase:
    return ui.clicked(id)
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(id, renderKey("menu:" & label, width, height, alignSelf))
  ui.attach(box, Component(Menu.new(label)))
  ui.addChild(box)

template menuItem*(self: var UI, id: WidgetID, config: BoxConfig,
    body: untyped) =
  ## Declare a menu item with the id `id`, holding the widgets declared in
  ## `body`.
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
    ui: var UI, id: WidgetID, width = fill(),
    height = fit(), alignSelf = AlignAuto
) {.layoutOnly.} =
  ## Declare a divider between two groups of menu items.
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(id, renderKey("menuDivider", width, height, alignSelf))
  ui.attach(box, Component(MenuDivider.new()))
  ui.addChild(box)

proc button*(
    ui: var UI,
    key: string,
    label: string,
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
): bool {.discardable.} =
  ## Declare a button whose id is built from the name `key`.
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
    padding = insets(0.0),
    style = ComponentStyle(),
    tabStyle = TabStyle(),
) =
  ## Declare a row of tabs with the id `id`, one per entry in `labels`.
  ##
  ## `selected` indexes the current tab; it is clamped into range and set to
  ## the tab the user picks. Does nothing when `labels` is empty.
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
    renderKey("tabs:" & labels.join("|") & ":" & $selected, width, height,
        alignSelf) &
      "|" & $gap & "|" & $padding & "|" & styleRenderKey(style),
  )
  let panel = Panel.new()
  panel.style = style
  ui.attach(layoutParent, Component(panel))
  ui.pushLayout(layoutParent)
  let tabHeight = fixed(ControlHeight.toFloat)
  for i, label in labels:
    let tabID = ui.id(id, "tab", i)
    let box = ui.box(tabID, width = fit(), height = tabHeight)
    ui.setRenderKey(tabID, renderKey("tab:" & label & ":" & $(i == selected),
        fit(), tabHeight, AlignAuto))
    ui.attach(box, Component(TabButton.new(label, i == selected, tabStyle)))
    ui.addChild(box)
  ui.row(cfg(
    width = fill(),
    height = fit(),
    gap = gap,
    paddingLeft = padding.left,
    paddingTop = padding.top,
    paddingRight = padding.right,
    paddingBottom = padding.bottom,
  ))
  discard ui.popLayout()

proc label*(
    ui: var UI,
    id: WidgetID,
    text: string,
    width = fit(),
    height = fit(),
    fontName = "font",
    alignSelf = AlignAuto,
    textScroll = false,
    style = ComponentStyle(),
) {.layoutOnly.} =
  ## Declare a text label with the id `id`.
  ##
  ## `textScroll` lets text wider than the widget scroll rather than be
  ## clipped.
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(
    id,
    renderKey(
      "label:" & text & ":" & fontName & ":" & $textScroll, width, height, alignSelf
    ) & "|" & styleRenderKey(style),
  )
  let lbl = Label.new(text, fontName, textScroll = textScroll)
  lbl.style = style
  ui.attach(box, Component(lbl))
  ui.addChild(box)

proc checkbox*(
    ui: var UI,
    id: WidgetID,
    label: string,
    checked: bool,
    width = fit(),
    height = fit(),
    fontName = "font",
    alignSelf = AlignAuto,
) {.layoutOnly.} =
  ## Declare a checkbox with the id `id` labelled `label`, drawn as `checked`.
  ##
  ## The caller owns the checked state; use `clicked` on the same id to flip
  ## it.
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
    width = fit(),
    height = fit(),
    fontName = "font",
    alignSelf = AlignAuto,
) {.layoutOnly.} =
  ## Declare a text label with the id `id` drawn in `color`.
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
    width = fit(),
    height = fit(),
    clickable = false,
    fontName = "font",
    alignSelf = AlignAuto,
): bool {.discardable.} =
  ## Declare a diagnostic label with the id `id` drawn in `color`.
  ##
  ## With `clickable`, the label highlights under the pointer and returns
  ## true on the frame it is clicked, which suits a compiler message that
  ## opens its source location.
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
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
) {.layoutOnly.} =
  ## Declare an image widget with the id `id` showing the image at `path`.
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
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
) {.layoutOnly.} =
  ## Declare an image widget with the id `id` showing the `source` region of
  ## the image at `path`, as one sprite out of a sheet.
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(id, renderKey("image:" & path & ":" & $source, width, height, alignSelf))
  let img = ImageView.new(path, source)
  ui.attach(box, Component(img))
  ui.addChild(box)

proc imageButton*(
    ui: var UI,
    id: WidgetID,
    path: string,
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
    style = ComponentStyle(),
): bool {.discardable.} =
  ## Declare an image button with the id `id` showing the image at `path`.
  ##
  ## Returns true on the frame it is clicked.
  if ui.phase == EventPhase:
    return ui.clicked(id)
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(
    id,
    renderKey("imageButton:" & path, width, height, alignSelf) & "|" &
      styleRenderKey(style),
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
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
    style = ComponentStyle(),
): bool {.discardable.} =
  ## Declare an image button with the id `id` showing the `source` region of
  ## the image at `path`.
  ##
  ## Returns true on the frame it is clicked.
  if ui.phase == EventPhase:
    return ui.clicked(id)
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(
    id,
    renderKey("imageButton:" & path & ":" & $source, width, height, alignSelf) &
      "|" & styleRenderKey(style),
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
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
): bool {.discardable.} =
  ## Declare a 2D mesh editor with the id `id` over `state`, drawn on top of
  ## the image at `imagePath`.
  ##
  ## Returns true on a frame where the user changed the mesh.
  if ui.phase == EventPhase:
    result = ui.submitted(id)
    if result:
      state.changed = false
    return
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.markRealtime(id)
  ui.setRenderKey(id, renderKey("mesh2d:" & imagePath & ":" & $state,
      width, height, alignSelf))
  let editor = Mesh2DEditor.new(state, imagePath)
  ui.attach(box, Component(editor))
  ui.addChild(box)

proc slider*(
    ui: var UI,
    id: WidgetID,
    value, minimum, maximum: float64,
    width = fill(min = 120),
    height = fit(),
    orientation = SliderHorizontal,
    alignSelf = AlignAuto,
): tuple[active: bool, value: float64] {.discardable.} =
  ## Declare a slider with the id `id` showing `value` within `minimum` to
  ## `maximum`.
  ##
  ## `active` is true while the slider is being dragged, and `value` is the
  ## value under the pointer; the caller owns the value and decides whether
  ## to keep it.
  ##
  ## A drag belongs to the slider the press landed on until the button comes
  ## up: while one slider is being dragged the others report nothing, so
  ## dragging the pointer over them leaves their values alone.
  if ui.phase == EventPhase:
    if not ui.pointerReaches(id):
      return (false, 0.0)
    let
      dragOwner = ui.context.draw.sliderDragging
      dragging = dragOwner == id
    if dragOwner != InvalidWidgetID and not dragging:
      return (false, 0.0)
    let located = ui.widgetFrame(id)
    if located.ok:
      let
        f = located.frame
        hot =
          ui.context.update.mouseX.toFloat >= f.x and
          ui.context.update.mouseX.toFloat < f.x + f.width and
          ui.context.update.mouseY.toFloat >= f.y and
          ui.context.update.mouseY.toFloat < f.y + f.height
        starting =
          (not dragging) and hot and ui.context.update.mouseLeftPressed
        continuing = dragging and ui.context.update.mouseLeftDown
        ending = dragging and not ui.context.update.mouseLeftDown
      if starting or continuing or ending:
        let value = sliderValueFromMouse(
          f, ui.context.update.mouseX, ui.context.update.mouseY, minimum,
          maximum,
          orientation,
        )
        ui.context.draw.sliderValues[id] = value
        ui.context.update.sliderValues[id] = value
        let owner = if ending: InvalidWidgetID else: id
        ui.context.draw.sliderDragging = owner
        ui.context.update.sliderDragging = owner
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

proc colorSwatch*(
    ui: var UI,
    id: WidgetID,
    value: Color,
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
) {.layoutOnly.} =
  ## Declare a colour swatch with the id `id` showing `value`.
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  ui.setRenderKey(id, renderKey("colorSwatch:" & $value, width, height, alignSelf))
  ui.attach(box, Component(ColorSwatch.new(value)))
  ui.addChild(box)

proc colorInput*(
    ui: var UI,
    id: WidgetID,
    label: string,
    value: var Color,
    width = fill(),
    height = fit(),
    alignSelf = AlignAuto,
): bool {.discardable.} =
  ## Declare a colour input with the id `id` labelled `label`: a swatch and
  ## one slider per channel.
  ##
  ## `value` is edited in place, and the call returns true on a frame where
  ## it changed.
  let previous = value
  if ui.phase == EventPhase:
    let red = ui.slider(ui.id(id, "red"), value.r.float64, 0, 255, fill(),
        fixed(28))
    if red.active:
      value.r = red.value.round.int.clamp(0, 255).uint8
    let green = ui.slider(ui.id(id, "green"), value.g.float64, 0, 255, fill(),
        fixed(28))
    if green.active:
      value.g = green.value.round.int.clamp(0, 255).uint8
    let blue = ui.slider(ui.id(id, "blue"), value.b.float64, 0, 255, fill(),
        fixed(28))
    if blue.active:
      value.b = blue.value.round.int.clamp(0, 255).uint8
    return value != previous

  ui.column(
    id,
    cfg(width = width, height = height, gap = 6, padding = 0,
        alignSelf = alignSelf),
  ):
    ui.row(
      ui.id(id, "summary"),
      cfg(width = fill(), height = fixed(34), gap = 8, padding = 0,
          alignItems = AlignCenter),
    ):
      ui.colorSwatch(ui.id(id, "swatch"), value, fixed(44), fixed(30))
      ui.label(ui.id(id, "label"), label, fill(), fit())
      ui.label(ui.id(id, "hex"), "#" & value.r.toHex(2) & value.g.toHex(2) &
          value.b.toHex(2), fit(), fit())
    template channel(key, name: string, channelValue: uint8) =
      ui.row(
        ui.id(id, key, "row"),
        cfg(width = fill(), height = fixed(28), gap = 8, padding = 0,
            alignItems = AlignCenter),
      ):
        ui.label(ui.id(id, key, "label"), name, fixed(16), fit())
        discard ui.slider(ui.id(id, key), channelValue.float64, 0, 255, fill(),
            fixed(28))
        ui.label(ui.id(id, key, "value"), $channelValue.int, fixed(32), fit())
    channel("red", "R", value.r)
    channel("green", "G", value.g)
    channel("blue", "B", value.b)

proc comboboxPopupIndex(
    field: Frame,
    optionCount: int,
    optionHeight: float64,
    windowHeight, mouseX, mouseY: int,
): int =
  ## Return the index of the option under the pointer, or -1 when the pointer
  ## is not over the open list. `optionHeight` is the height of one row, which
  ## is the height of the field itself.
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

proc choicePopoverKey(options: openArray[string], selected: int): string =
  result = $selected
  for option in options:
    result.add "\x1f"
    result.add option

proc choicePopoverData(options: openArray[string]): string =
  var nodes: seq[JsonNode]
  for option in options:
    nodes.add %option
  $(%nodes)

proc closeChoicePopover(self: var UI, id: WidgetID) {.raises: [].} =
  let popover = self.choicePopovers.getOrDefault(id)
  popover.closePopover()
  self.choicePopovers.del id

proc pollChoicePopover(
    self: var UI, id: WidgetID
): tuple[ready: bool, index: int] {.raises: [].} =
  let popover = self.choicePopovers.getOrDefault(id)
  if popover == nil:
    return
  if popover.process != nil:
    try:
      if popover.process.running:
        return
      popover.process.close
    except OSError:
      discard
    except IOError:
      discard
  if popover.resultPath.len > 0 and fileExists(popover.resultPath):
    try:
      result.index = parseInt(readFile(popover.resultPath).strip)
      result.ready = true
      removeFile(popover.resultPath)
    except ValueError:
      discard
    except OSError:
      discard
    except IOError:
      discard
  self.choicePopovers.del id

proc showChoicePopover(
    self: var UI,
    id: WidgetID,
    field: Frame,
    selected: int,
    options: openArray[string],
) {.raises: [].} =
  if not externalPopoverAvailable():
    return
  let key = choicePopoverKey(options, selected)
  let current = self.choicePopovers.getOrDefault(id)
  if current != nil and current.key == key:
    return
  self.closeChoicePopover(id)
  let resultPath =
    getTempDir() / ("nest-choice-" & $getCurrentProcessId() & "-" & $id)
  try:
    if fileExists(resultPath):
      removeFile(resultPath)
  except OSError:
    discard
  self.choicePopovers[id] = startPopoverProcess(
    "choice-popover",
    [
      choicePopoverData(options),
      resultPath,
      self.popoverAnchorJson(field.x.toInt, (field.y + field.height).toInt),
      self.themeName,
      $getCurrentProcessId(),
    ],
    resultPath = resultPath,
    key = key,
  )

proc combobox*(
    ui: var UI,
    id: WidgetID,
    selected: int,
    options: openArray[string],
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
    closeOnSelect = true,
    dismissOnClickaway = true,
): tuple[changed: bool, index: int] {.discardable.} =
  ## Declare a combo box with the id `id` offering `options`, with `selected`
  ## as the current index.
  ##
  ## Returns the index the user picked and whether it differs from
  ## `selected`; the caller owns the selection. The list opens on a click,
  ## closes when the pointer goes elsewhere, and `index` stays at `selected`
  ## for empty `options`. Picking an option closes the list too, unless
  ## `closeOnSelect` is false, which suits a list the user picks from more
  ## than once. `dismissOnClickaway` controls whether a click outside the
  ## field and open list closes it.
  result.index = selected
  if options.len == 0:
    return

  let clampedSelected = selected.clamp(0, options.len - 1)

  if ui.phase == EventPhase:
    let picked = ui.pollChoicePopover(id)
    if picked.ready and picked.index >= 0 and picked.index < options.len:
      return (picked.index != clampedSelected, picked.index)
    if not ui.pointerReaches(id):
      return
    let open = ui.context.draw.focusedWidget == id
    when defined(linux):
      if externalPopoverAvailable():
        let located = ui.widgetFrame(id)
        if located.ok and ui.context.update.mouseLeftPressed:
          let f = located.frame
          let inField =
            ui.context.update.mouseX.float64 >= f.x and
            ui.context.update.mouseX.float64 < f.x + f.width and
            ui.context.update.mouseY.float64 >= f.y and
            ui.context.update.mouseY.float64 < f.y + f.height
          if inField:
            ui.showChoicePopover(id, f, clampedSelected, options)
            ui.eventActiveWidgets.clear()
            ui.context.draw.activeWidgets.clear()
          elif dismissOnClickaway:
            ui.closeChoicePopover(id)
        return
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
            f, options.len, f.height, ui.windowHeight,
            ui.context.update.mouseX,
            ui.context.update.mouseY,
          )
        ui.eventActiveWidgets.clear()
        ui.eventSubmittedWidgets.clear()
        ui.context.draw.activeWidgets.clear()
        ui.context.draw.submittedWidgets.clear()
        if optionIndex >= 0:
          if closeOnSelect:
            ui.closeFocus(id)
          return (optionIndex != clampedSelected, optionIndex)
        elif dismissOnClickaway and not inField:
          ui.closeFocus(id)
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
    ) & "|" & $dismissOnClickaway,
  )
  # One option is as tall as the field, which is only known once the frame is
  # solved; until then the standard control height stands in.
  let solved = ui.widgetFrame(id)
  let optionHeight =
    if solved.ok and solved.frame.height > 0.0:
      solved.frame.height.int
    elif height.value > 0.0:
      height.value.int
    else:
      ControlHeight
  ui.attach(
    box,
    Component(
      ComboBox.new(
        options[clampedSelected], options, clampedSelected, open, optionHeight,
        dismissOnClickaway,
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
    width = fill(min = 160),
    height = fit(),
    fontName = "font",
    alignSelf = AlignAuto,
) =
  ## Declare a single-line text input with the id `id` editing `state`.
  ##
  ## The text, cursor and selection live on `state`, so it must outlive the
  ## frame. Use `submitted` on the same id to react to the Enter key.
  discard ui.component(
    id,
    Component(LineInput.new(state, fontName)),
    width,
    height,
    alignSelf,
    renderKey("lineInput:" & state.text & ":" & fontName, width, height,
        alignSelf),
  )

proc textEditor*(
    ui: var UI,
    id: WidgetID,
    state: EditorState,
    width = fill(min = 240),
    height = fill(min = 160),
    fontName = "font",
    alignSelf = AlignAuto,
    lineNumbers = false,
    scrollbars = true,
    readOnly = false,
    syntax = "",
    gutterMarkers: HashSet[int] = initHashSet[int](),
    activeLine = 0,
) {.layoutOnly.} =
  ## Declare a multi-line text editor with the id `id` editing `state`.
  ##
  ## The text, cursor, selection and scroll position live on `state`, so it
  ## must outlive the frame. `lineNumbers` shows a gutter, `scrollbars` shows
  ## scrollbars when the content overflows, `syntax` names the highlighter,
  ## `gutterMarkers` are the lines to mark, and `activeLine` is the line to
  ## highlight.
  discard ui.component(
    id,
    Component(Editor.new(
      state,
      fontName,
      singleLine = false,
      lineNumbers = lineNumbers,
      scrollbars = scrollbars,
      readOnly = readOnly,
      syntax = syntax,
      gutterMarkers = gutterMarkers,
      activeLine = activeLine,
    )),
    width,
    height,
    alignSelf,
    renderKey(
      "textEditor:" & $state.textVersion & ":" & $state.cursor & ":" &
        $state.selectionAnchor & ":" & fontName & ":" & $lineNumbers & ":" &
        $scrollbars & ":" & $readOnly & ":" & syntax & ":" & $gutterMarkers &
        ":" & $activeLine,
      width,
      height,
      alignSelf,
    ),
  )

proc container*(
    self: var UI,
    component: Container,
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
): Widget {.discardable, layoutOnly.} =
  ## Same as the overload taking an explicit `id`, with a generated id.
  self.container(self.nextAutoID(), component, width, height, alignSelf)

proc component*(
    self: var UI,
    component: Component,
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
    renderKeyOverride = "",
): Widget {.discardable, layoutOnly.} =
  ## Same as the overload taking an explicit `id`, with a generated id.
  self.component(
    self.nextAutoID(), component, width, height, alignSelf, renderKeyOverride
  )

proc spacer*(
    self: var UI, width = fill(),
    height = fill(), alignSelf = AlignAuto
): Widget {.discardable, layoutOnly.} =
  ## Same as the overload taking an explicit `id`, with a generated id.
  self.spacer(self.nextAutoID(), width, height, alignSelf)

proc button*(
    ui: var UI,
    label: string,
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
    textScroll = false,
    buttonBorderStyle = ButtonBorderLine,
    buttonChromeStyle = ButtonChromeRaised,
    buttonTextAlign = JustifyCenter,
    style = ComponentStyle(),
): bool {.discardable.} =
  ## Same as the overload taking an explicit `id`, with a generated id.
  ui.button(
    ui.nextAutoID(), label, width, height, alignSelf,
    textScroll = textScroll, buttonBorderStyle = buttonBorderStyle,
    buttonChromeStyle = buttonChromeStyle, buttonTextAlign = buttonTextAlign,
    style = style
  )

proc menu*(
    ui: var UI,
    label: string,
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
): bool {.discardable.} =
  ## Same as the overload taking an explicit `id`, with a generated id.
  ui.menu(ui.nextAutoID(), label, width, height, alignSelf)

proc menuDivider*(
    ui: var UI, width = fill(),
    height = fit(), alignSelf = AlignAuto
) {.layoutOnly.} =
  ## Same as the overload taking an explicit `id`, with a generated id.
  ui.menuDivider(ui.nextAutoID(), width, height, alignSelf)

proc tabs*(
    ui: var UI,
    labels: openArray[string],
    selected: var int,
    width = fill(),
    height = fit(),
    alignSelf = AlignAuto,
    gap = 0.0,
    padding = insets(0.0),
    style = ComponentStyle(),
    tabStyle = TabStyle(),
) =
  ## Same as the overload taking an explicit `id`, with a generated id.
  ui.tabs(
    ui.nextAutoID(), labels, selected, width, height, alignSelf, gap, padding,
    style, tabStyle
  )

proc label*(
    ui: var UI,
    text: string,
    width = fit(),
    height = fit(),
    fontName = "font",
    alignSelf = AlignAuto,
    textScroll = false,
) {.layoutOnly.} =
  ## Same as the overload taking an explicit `id`, with a generated id.
  ui.label(ui.nextAutoID(), text, width, height, fontName, alignSelf, textScroll)

proc checkbox*(
    ui: var UI,
    label: string,
    checked: bool,
    width = fit(),
    height = fit(),
    fontName = "font",
    alignSelf = AlignAuto,
) {.layoutOnly.} =
  ## Same as the overload taking an explicit `id`, with a generated id.
  ui.checkbox(ui.nextAutoID(), label, checked, width, height, fontName, alignSelf)

proc coloredLabel*(
    ui: var UI,
    text: string,
    color: Color,
    width = fit(),
    height = fit(),
    fontName = "font",
    alignSelf = AlignAuto,
) {.layoutOnly.} =
  ## Same as the overload taking an explicit `id`, with a generated id.
  ui.coloredLabel(ui.nextAutoID(), text, color, width, height, fontName, alignSelf)

proc diagnosticLabel*(
    ui: var UI,
    text: string,
    color: Color,
    width = fit(),
    height = fit(),
    clickable = false,
    fontName = "font",
    alignSelf = AlignAuto,
): bool {.discardable.} =
  ## Same as the overload taking an explicit `id`, with a generated id.
  ui.diagnosticLabel(
    ui.nextAutoID(), text, color, width, height, clickable, fontName, alignSelf
  )

proc image*(
    ui: var UI,
    path: string,
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
) {.layoutOnly.} =
  ## Same as the overload taking an explicit `id`, with a generated id.
  ui.image(ui.nextAutoID(), path, width, height, alignSelf)

proc image*(
    ui: var UI,
    path: string,
    source: Rect,
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
) {.layoutOnly.} =
  ## Same as the overload taking an explicit `id`, with a generated id.
  ui.image(ui.nextAutoID(), path, source, width, height, alignSelf)

proc imageButton*(
    ui: var UI,
    path: string,
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
    style = ComponentStyle(),
): bool {.discardable.} =
  ## Same as the overload taking an explicit `id`, with a generated id.
  ui.imageButton(ui.nextAutoID(), path, width, height, alignSelf, style)

proc imageButton*(
    ui: var UI,
    path: string,
    source: Rect,
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
    style = ComponentStyle(),
): bool {.discardable.} =
  ## Same as the overload taking an explicit `id`, with a generated id.
  ui.imageButton(ui.nextAutoID(), path, source, width, height, alignSelf, style)

proc mesh2d*(
    ui: var UI,
    state: var Mesh2DState,
    imagePath: string,
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
): bool {.discardable.} =
  ## Same as the overload taking an explicit `id`, with a generated id.
  ui.mesh2d(ui.nextAutoID(), state, imagePath, width, height, alignSelf)

proc slider*(
    ui: var UI,
    value, minimum, maximum: float64,
    width = fill(min = 120),
    height = fit(),
    orientation = SliderHorizontal,
    alignSelf = AlignAuto,
): tuple[active: bool, value: float64] {.discardable.} =
  ## Same as the overload taking an explicit `id`, with a generated id.
  ui.slider(
    ui.nextAutoID(), value, minimum, maximum, width, height, orientation, alignSelf
  )

proc colorSwatch*(
    ui: var UI,
    value: Color,
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
) {.layoutOnly.} =
  ## Same as the overload taking an explicit `id`, with a generated id.
  ui.colorSwatch(ui.nextAutoID(), value, width, height, alignSelf)

proc colorInput*(
    ui: var UI,
    label: string,
    value: var Color,
    width = fill(),
    height = fit(),
    alignSelf = AlignAuto,
): bool {.discardable.} =
  ## Same as the overload taking an explicit `id`, with a generated id.
  ui.colorInput(ui.nextAutoID(), label, value, width, height, alignSelf)

proc combobox*(
    ui: var UI,
    selected: int,
    options: openArray[string],
    width = fit(),
    height = fit(),
    alignSelf = AlignAuto,
): tuple[changed: bool, index: int] {.discardable.} =
  ## Same as the overload taking an explicit `id`, with a generated id.
  ui.combobox(ui.nextAutoID(), selected, options, width, height, alignSelf)

proc lineInput*(
    ui: var UI,
    state: LineInputState,
    width = fill(min = 160),
    height = fit(),
    fontName = "font",
    alignSelf = AlignAuto,
) =
  ## Same as the overload taking an explicit `id`, with a generated id.
  ui.lineInput(ui.nextAutoID(), state, width, height, fontName, alignSelf)

proc textEditor*(
    ui: var UI,
    state: EditorState,
    width = fill(min = 240),
    height = fill(min = 160),
    fontName = "font",
    alignSelf = AlignAuto,
    lineNumbers = false,
    scrollbars = true,
    readOnly = false,
    syntax = "",
    gutterMarkers: HashSet[int] = initHashSet[int](),
    activeLine = 0,
) {.layoutOnly.} =
  ## Same as the overload taking an explicit `id`, with a generated id.
  ui.textEditor(
    ui.nextAutoID(), state, width, height, fontName, alignSelf, lineNumbers,
    scrollbars, readOnly, syntax, gutterMarkers, activeLine
  )
