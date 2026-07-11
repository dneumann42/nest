import std/[atomics, sets]
import resources
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
    flags: set[WidgetFlag]

  DrawContext* = object
    resources*: Resources
    mouseX*, mouseY*: int
    windowWidth*, windowHeight*: int
    hotWidgets*: HashSet[WidgetID]
    activeWidgets*: HashSet[WidgetID]
    focusedWidget*: WidgetID
    submittedWidgets*: HashSet[WidgetID]
    palette*: Palette

  UpdateContext* = object
    mouseX*, mouseY*: int
    windowWidth*, windowHeight*: int
    mouseLeftPressed*, mouseLeftDown*: bool
    hotWidgets*: HashSet[WidgetID]
    activeWidgets*: HashSet[WidgetID]
    focusedWidget*: WidgetID
    submittedWidgets*: HashSet[WidgetID]
    keyInputs*: seq[KeyInput]
    textInputs*: seq[string]

const InvalidWidgetID* = WidgetID(0)

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

proc submit*(ctx: var UpdateContext, id: WidgetID) =
  ctx.submittedWidgets.incl(id)

proc switchState*(updateContext: var UpdateContext, drawContext: var DrawContext) =
  drawContext.hotWidgets = updateContext.hotWidgets
  drawContext.activeWidgets = updateContext.activeWidgets
  drawContext.focusedWidget = updateContext.focusedWidget
  drawContext.submittedWidgets = updateContext.submittedWidgets

proc frame*(box: Widget): Frame =
  Frame(
    x: box.x.value.float64,
    y: box.y.value.float64,
    width: box.w.value.float64,
    height: box.h.value.float64,
  )

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
