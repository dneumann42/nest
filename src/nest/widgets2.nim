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
    Auto
    Start
    Center
    End
    Stretch

  Justification* = enum
    Auto
    Start
    Center
    End

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

  IOOpenFile* = proc(id: WidgetID, defaultLocation: cstring): bool {.cdecl.}
  IOFileValue* = proc(id: WidgetID): cstring {.cdecl.}
  IOFileError* = proc(id: WidgetID): cstring {.cdecl.}
  IOClearFile* = proc(id: WidgetID) {.cdecl.}

  FileIO* = object
    openFile*: IOOpenFile
    fileValue*: IOFileValue
    fileError*: IOFileError
    clearFile*: IOClearFile

  IO* = object
    files*: FileIO

  Widget* = object
    id*: WidgetID
    x*, y*, w*, h*: Variable
    alignSelf*: Alignment
    justifySelf*: Justification
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
    middleDragging*: WidgetID
    middleDragStartX*: int
    dirtyWidgets*: HashSet[WidgetID]
    dirtyAll*: bool
    ticks*: int
    palette*: Palette
    hasClip*: bool
    clipRect*: Rect
    hasRedrawRequest*: bool
    redrawDelayMs*: int
    drawCommands*: ptr seq[DrawCommand]
    commandMeasureText*: proc(f: Font, text: string): TextExtent {.nimcall.}
    commandMeasureImage*: proc(path: string): TextExtent {.nimcall.}
    io*: IO

  UpdateContext* = object
    resources*: Resources
    mouseX*, mouseY*: int
    windowWidth*, windowHeight*: int
    mouseLeftPressed*, mouseLeftDown*: bool
    mouseMiddlePressed*, mouseMiddleDown*: bool
    mouseRightPressed*: bool
    mouseWheelX*, mouseWheelY*: float64
    hotWidgets*: HashSet[WidgetID]
    activeWidgets*: HashSet[WidgetID]
    focusedWidget*: WidgetID
    submittedWidgets*: HashSet[WidgetID]
    dirtyWidgets*: HashSet[WidgetID]
    sliderValues*: Table[WidgetID, float64]
    sliderDragging*: WidgetID
    middleDragging*: WidgetID
    middleDragStartX*: int
    keyInputs*: seq[KeyInput]
    textInputs*: seq[string]

const InvalidWidgetID* = WidgetID(0)

proc lerp*(a, b, t: float64): float64 =
  ## Interpolate linearly between `a` and `b` by `t`.
  a + (b - a) * t

proc hot*(ctx: UpdateContext | DrawContext, id: WidgetID): bool =
  ## Test whether the widget is hot, that is, under the pointer.
  ctx.hotWidgets.contains(id)

proc setHot*(ctx: var UpdateContext, id: WidgetID) =
  ## Mark the widget as hot for this frame.
  ctx.hotWidgets.incl(id)

proc active*(ctx: UpdateContext | DrawContext, id: WidgetID): bool =
  ## Test whether the widget is active, that is, being pressed.
  ctx.activeWidgets.contains(id)

proc setActive*(ctx: var UpdateContext, id: WidgetID) =
  ## Mark the widget as active for this frame.
  ctx.activeWidgets.incl(id)

proc focused*(ctx: UpdateContext | DrawContext, id: WidgetID): bool =
  ## Test whether the widget currently holds keyboard focus.
  ctx.focusedWidget == id

proc setFocus*(ctx: var UpdateContext, id: WidgetID) =
  ## Give keyboard focus to the widget.
  ctx.focusedWidget = id

proc clearFocus*(ctx: var UpdateContext) =
  ## Drop keyboard focus, leaving no widget focused.
  ctx.focusedWidget = InvalidWidgetID

proc submitted*(ctx: UpdateContext | DrawContext, id: WidgetID): bool =
  ## Test whether the widget was submitted this frame, as a line input is by
  ## the Enter key.
  ctx.submittedWidgets.contains(id)

proc intersectRects*(a, b: Rect): Rect =
  ## Return the overlap of `a` and `b`, which is empty when they do not
  ## intersect.
  let
    x1 = max(a.x, b.x)
    y1 = max(a.y, b.y)
    x2 = min(a.x + a.w, b.x + b.w)
    y2 = min(a.y + a.h, b.y + b.h)
  rect(x1, y1, max(x2 - x1, 0), max(y2 - y1, 0))

proc clippedRect*(ctx: DrawContext, r: Rect): Rect =
  ## Return `r` clipped to the context's clip rectangle, or `r` itself when
  ## no clip is in force.
  if ctx.hasClip:
    intersectRects(ctx.clipRect, r)
  else:
    r

proc submit*(ctx: var UpdateContext, id: WidgetID) =
  ## Mark the widget as submitted for this frame.
  ctx.submittedWidgets.incl(id)

proc markDirty*(ctx: var UpdateContext, id: WidgetID) =
  ## Mark the widget as needing a redraw. Ignores `InvalidWidgetID`.
  if id != InvalidWidgetID:
    ctx.dirtyWidgets.incl(id)

proc requestRedrawAfter*(ctx: var DrawContext, ms: int) =
  ## Ask for another frame in at most `ms` milliseconds.
  ##
  ## The shortest request wins, so an animation can keep asking for the next
  ## frame without cancelling a sooner one.
  let delay = max(ms, 0)
  if not ctx.hasRedrawRequest or delay < ctx.redrawDelayMs:
    ctx.hasRedrawRequest = true
    ctx.redrawDelayMs = delay

proc setSliderValue*(ctx: var UpdateContext, id: WidgetID, value: float64) =
  ## Record the value a slider was dragged to this frame, and mark it as the
  ## slider being dragged.
  ctx.sliderValues[id] = value
  ctx.sliderDragging = id

proc switchState*(updateContext: var UpdateContext,
    drawContext: var DrawContext) =
  ## Copy the interaction state collected while updating into the draw
  ## context, so drawing sees the same hot, active and focused widgets.
  drawContext.hotWidgets = updateContext.hotWidgets
  drawContext.activeWidgets = updateContext.activeWidgets
  drawContext.focusedWidget = updateContext.focusedWidget
  drawContext.submittedWidgets = updateContext.submittedWidgets
  drawContext.sliderValues = updateContext.sliderValues
  drawContext.sliderDragging = updateContext.sliderDragging

proc frame*(box: Widget): Frame =
  ## Return the widget's solved position and size.
  Frame(
    x: box.x.value.float64,
    y: box.y.value.float64,
    width: box.w.value.float64,
    height: box.h.value.float64,
  )

proc setFrame*(box: Widget, frame: Frame) =
  ## Overwrite the widget's solved position and size, bypassing the layout
  ## solver.
  box.x.value = frame.x
  box.y.value = frame.y
  box.w.value = frame.width
  box.h.value = frame.height

proc nextWidgetID*(): WidgetID =
  ## Return a process-wide unique widget id. Safe to call from any thread.
  var nextID {.global.}: Atomic[uint64]
  result = WidgetID(nextID.fetchAdd(1'u64, moRelaxed) + 1'u64)

proc init*(T: typedesc[Widget], flags: set[WidgetFlag]): T =
  ## Create a widget with a fresh id and the given layout `flags`.
  result = T(id: nextWidgetID(), flags: flags)

proc setStretch*(widget: var Widget, width, height: bool) =
  ## Set whether the widget stretches to fill its parent along each axis.
  if width:
    widget.flags.incl StretchWidth
  else:
    widget.flags.excl StretchWidth

  if height:
    widget.flags.incl StretchHeight
  else:
    widget.flags.excl StretchHeight

proc stretchWidth*(widget: Widget): bool =
  ## Test whether the widget stretches horizontally.
  StretchWidth in widget.flags

proc stretchHeight*(widget: Widget): bool =
  ## Test whether the widget stretches vertically.
  StretchHeight in widget.flags

proc setFit*(widget: var Widget, width, height: bool) =
  ## Set whether the widget shrinks to fit its content along each axis.
  if width:
    widget.flags.incl FitWidth
  else:
    widget.flags.excl FitWidth

  if height:
    widget.flags.incl FitHeight
  else:
    widget.flags.excl FitHeight

proc fitWidth*(widget: Widget): bool =
  ## Test whether the widget fits its content horizontally.
  FitWidth in widget.flags

proc fitHeight*(widget: Widget): bool =
  ## Test whether the widget fits its content vertically.
  FitHeight in widget.flags

proc intrinsicSize*(width, height: float64): IntrinsicSize =
  ## Return an intrinsic size that constrains both axes, as a component
  ## reports the size of its content.
  IntrinsicSize(hasWidth: true, hasHeight: true, width: width, height: height)

proc withAlignSelf*(widget: Widget, alignment: Alignment): Widget =
  ## Return a copy of `widget` with its cross-axis alignment set to
  ## `alignment`.
  result = widget
  result.alignSelf = alignment

proc withJustifySelf*(widget: Widget, justification: Justification): Widget =
  ## Return a copy of `widget` with its main-axis justification set to
  ## `justification`.
  result = widget
  result.justifySelf = justification
