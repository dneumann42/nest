import std/[sets, atomics]
import resources
import kiwiberry

type
  WidgetFlag = enum
    InteractiveWidget
    StaticWidget
    StretchWidth
    StretchHeight

  Frame* = object
    x*, y*, width*, height*: float64

  WidgetID* = uint64
  Widget* = object
    id*: WidgetID
    x*, y*, w*, h*: Variable
    flags: set[WidgetFlag]

  DrawContext* = object
    resources*: Resources
    mouseX*, mouseY*: int
    windowWidth*, windowHeight*: int

  UpdateContext* = object
    mouseX*, mouseY*: int
    windowWidth*, windowHeight*: int

const InvalidWidgetID* = WidgetID(0)

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
