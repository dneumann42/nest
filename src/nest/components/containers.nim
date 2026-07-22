import ../widgets2
import component
import nest/[coords, screen]

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

proc drawBorder(f: Frame, c: Color) =
  lineRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), c)

method draw*(self: Panel, widget: Widget, ctx: var DrawContext) =
  let f = widget.frame
  fillRect(
    rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt),
    self.styledBackground(ctx.palette.panelBackground),
  )
  fillRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, 2), ctx.palette.buttonHighlight)
  drawBorder(f, ctx.palette.panelBorder)

method draw*(self: Card, widget: Widget, ctx: var DrawContext) =
  let f = widget.frame
  let
    x = f.x.toInt
    y = f.y.toInt
    w = f.width.toInt
    h = f.height.toInt
  if w <= 0 or h <= 0:
    return
  fillRect(rect(x, y, w, h), self.styledBackground(ctx.palette.cardBackground))
  drawBorder(f, ctx.palette.cardBorder)
  if w <= 2 or h <= 2:
    return
  fillRect(rect(x + 1, y + 1, max(w - 2, 0), 1), ctx.palette.buttonHighlight)
  fillRect(rect(x + 1, y + 1, 4, max(h - 2, 0)), ctx.palette.cardAccent)
  fillRect(rect(x + 1, y + h - 2, max(w - 2, 0), 1), ctx.palette.panelBorder)
  fillRect(rect(x + w - 2, y + 1, 1, max(h - 2, 0)), ctx.palette.panelBorder)

method draw*(self: DialogHeader, widget: Widget, ctx: var DrawContext) =
  let f = widget.frame
  fillRect(
    rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt),
    self.styledBackground(ctx.palette.dialogHeaderBackground),
  )
  fillRect(
    rect(f.x.toInt, (f.y + f.height).toInt, f.width.toInt, 2),
    ctx.palette.dialogHeaderBorder,
  )
