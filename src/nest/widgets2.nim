import std/[atomics, tables, sets]
import resources
import nest/input
export input
import kiwiberry
import palette

type
  KeyInput* = object
    key*: KeyCode
    mods*: set[Modifier]

  WidgetFlag = enum
    InteractiveWidget
    StaticWidget
    StretchWidth
    StretchHeight
    FitWidth
    FitHeight

  Alignment* = enum
    AlignAuto
    AlignStart
    AlignCenter
    AlignEnd
    AlignStretch

  WidgetSizeKind* = enum
    WidgetFill
    WidgetFixed
    WidgetFit
    WidgetHug
    WidgetPrefer

  WidgetSizePolicy* = object
    kind*: WidgetSizeKind
    value*: float64
    min*: float64
    max*: float64

  Frame* = object
    x*, y*, width*, height*: float64

  IntrinsicSize* = object
    hasWidth*, hasHeight*: bool
    width*, height*: float64

  WidgetID* = uint64
  Widget* = object
    id*: WidgetID
    x*, y*, w*, h*: Variable
    alignSelf*: Alignment
    widthPolicy*, heightPolicy*: WidgetSizePolicy
    flags: set[WidgetFlag]

  DrawContext* = object
    resources*: Resources
    mouseX*, mouseY*: int
    windowWidth*, windowHeight*: int
    hotWidgets*: HashSet[WidgetID]
    activeWidgets*: HashSet[WidgetID]
    focusedWidget*: WidgetID
    submittedWidgets*: HashSet[WidgetID]
    sliderValues*: Table[WidgetID, float64]
    sliderDragging*: WidgetID
    dirtyWidgets*: HashSet[WidgetID]
    dirtyAll*: bool
    ticks*: int
    palette*: Palette
    hasClip*: bool
    clipRect*: Rect
    hasRedrawRequest*: bool
    redrawDelayMs*: int

  UpdateContext* = object
    resources*: Resources
    mouseX*, mouseY*: int
    windowWidth*, windowHeight*: int
    mouseLeftPressed*, mouseLeftDown*: bool
    mouseWheelX*, mouseWheelY*: float64
    hotWidgets*: HashSet[WidgetID]
    activeWidgets*: HashSet[WidgetID]
    focusedWidget*: WidgetID
    submittedWidgets*: HashSet[WidgetID]
    sliderValues*: Table[WidgetID, float64]
    sliderDragging*: WidgetID
    keyInputs*: seq[KeyInput]
    textInputs*: seq[string]

const InvalidWidgetID* = WidgetID(0)

proc lerp*(a, b, t: float64): float64 =
  a + (b - a) * t

proc hot*(ctx: UpdateContext | DrawContext, id: WidgetID): bool =
  ctx.hotWidgets.contains(id)

proc setHot*(ctx: var UpdateContext, id: WidgetID) =
  ctx.hotWidgets.incl(id)

proc active*(ctx: UpdateContext | DrawContext, id: WidgetID): bool =
  ctx.activeWidgets.contains(id)

proc setActive*(ctx: var UpdateContext, id: WidgetID) =
  ctx.activeWidgets.incl(id)

proc focused*(ctx: UpdateContext | DrawContext, id: WidgetID): bool =
  ctx.focusedWidget == id

proc setFocus*(ctx: var UpdateContext, id: WidgetID) =
  ctx.focusedWidget = id

proc clearFocus*(ctx: var UpdateContext) =
  ctx.focusedWidget = InvalidWidgetID

proc submitted*(ctx: UpdateContext | DrawContext, id: WidgetID): bool =
  ctx.submittedWidgets.contains(id)

proc intersectRects*(a, b: Rect): Rect =
  let
    x1 = max(a.x, b.x)
    y1 = max(a.y, b.y)
    x2 = min(a.x + a.w, b.x + b.w)
    y2 = min(a.y + a.h, b.y + b.h)
  rect(x1, y1, max(x2 - x1, 0), max(y2 - y1, 0))

proc clippedRect*(ctx: DrawContext, r: Rect): Rect =
  if ctx.hasClip:
    intersectRects(ctx.clipRect, r)
  else:
    r

proc submit*(ctx: var UpdateContext, id: WidgetID) =
  ctx.submittedWidgets.incl(id)

proc requestRedrawAfter*(ctx: var DrawContext, ms: int) =
  let delay = max(ms, 0)
  if not ctx.hasRedrawRequest or delay < ctx.redrawDelayMs:
    ctx.hasRedrawRequest = true
    ctx.redrawDelayMs = delay

proc setSliderValue*(ctx: var UpdateContext, id: WidgetID, value: float64) =
  ctx.sliderValues[id] = value
  ctx.sliderDragging = id

proc switchState*(updateContext: var UpdateContext, drawContext: var DrawContext) =
  drawContext.hotWidgets = updateContext.hotWidgets
  drawContext.activeWidgets = updateContext.activeWidgets
  drawContext.focusedWidget = updateContext.focusedWidget
  drawContext.submittedWidgets = updateContext.submittedWidgets
  drawContext.sliderValues = updateContext.sliderValues
  drawContext.sliderDragging = updateContext.sliderDragging

proc frame*(box: Widget): Frame =
  Frame(
    x: box.x.value.float64,
    y: box.y.value.float64,
    width: box.w.value.float64,
    height: box.h.value.float64,
  )

proc setFrame*(box: Widget, frame: Frame) =
  box.x.value = frame.x
  box.y.value = frame.y
  box.w.value = frame.width
  box.h.value = frame.height

proc nextWidgetID*(): WidgetID =
  var nextID {.global.}: Atomic[uint64]
  result = WidgetID(nextID.fetchAdd(1'u64, moRelaxed) + 1'u64)

proc init*(T: typedesc[Widget], flags: set[WidgetFlag]): T =
  result = T(id: nextWidgetID(), flags: flags)

proc setStretch*(widget: var Widget, width, height: bool) =
  if width:
    widget.flags.incl StretchWidth
  else:
    widget.flags.excl StretchWidth

  if height:
    widget.flags.incl StretchHeight
  else:
    widget.flags.excl StretchHeight

proc stretchWidth*(widget: Widget): bool =
  StretchWidth in widget.flags

proc stretchHeight*(widget: Widget): bool =
  StretchHeight in widget.flags

proc setFit*(widget: var Widget, width, height: bool) =
  if width:
    widget.flags.incl FitWidth
  else:
    widget.flags.excl FitWidth

  if height:
    widget.flags.incl FitHeight
  else:
    widget.flags.excl FitHeight

proc fitWidth*(widget: Widget): bool =
  FitWidth in widget.flags

proc fitHeight*(widget: Widget): bool =
  FitHeight in widget.flags

proc intrinsicSize*(width, height: float64): IntrinsicSize =
  IntrinsicSize(hasWidth: true, hasHeight: true, width: width, height: height)

proc withAlignSelf*(widget: Widget, alignment: Alignment): Widget =
  result = widget
  result.alignSelf = alignment
