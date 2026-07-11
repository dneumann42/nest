import ../widgets2
import component
import uirelays

type
  Slot* = seq[WidgetID]

  Container* = ref object of Component
    defaultSlot*: Slot

  Panel* = ref object of Container

  Card* = ref object of Container

  DialogHeader* = ref object of Container
    left*: WidgetID
    right*: Slot

proc ids*(widgets: openArray[Widget]): Slot =
  for widget in widgets:
    result.add widget.id

proc setSlot*(container: Container, slot: var WidgetID, widget: Widget) =
  slot = widget.id

proc setSlot*(container: Container, slot: var Slot, widget: Widget) =
  slot = @[widget.id]

proc setSlot*(container: Container, slot: var Slot, widgets: openArray[Widget]) =
  slot = widgets.ids

proc setDefaultSlot*(container: Container, widget: Widget) =
  container.defaultSlot = @[widget.id]

proc setDefaultSlot*(container: Container, widgets: openArray[Widget]) =
  container.defaultSlot = widgets.ids

proc new*(T: typedesc[Panel]): T =
  T()

proc new*(T: typedesc[Card]): T =
  T()

proc new*(T: typedesc[DialogHeader]): T =
  T()

method draw*(self: Panel, widget: Widget, ctx: DrawContext) =
  let f = widget.frame
  fillRect(
    rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt),
    ctx.palette.panelBackground,
  )
  fillRect(
    rect(f.x.toInt, f.y.toInt, f.width.toInt, 1),
    ctx.palette.panelBorder,
  )

method draw*(self: Card, widget: Widget, ctx: DrawContext) =
  let f = widget.frame
  fillRect(
    rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt),
    ctx.palette.cardBackground,
  )
  fillRect(
    rect(f.x.toInt, f.y.toInt, 3, f.height.toInt),
    ctx.palette.cardAccent,
  )

method draw*(self: DialogHeader, widget: Widget, ctx: DrawContext) =
  let f = widget.frame
  fillRect(
    rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt),
    ctx.palette.dialogHeaderBackground,
  )
  fillRect(
    rect(f.x.toInt, (f.y + f.height - 1).toInt, f.width.toInt, 1),
    ctx.palette.dialogHeaderBorder,
  )
