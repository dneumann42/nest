import std/sets

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
  ## Return the ids of `widgets` as a slot.
  for widget in widgets:
    result.add widget.id

proc setSlot*(container: Container, slot: var WidgetID, widget: Widget) =
  ## Point a single-widget slot at `widget`.
  slot = widget.id

proc setSlot*(container: Container, slot: var Slot, widget: Widget) =
  ## Point a slot at `widget` alone, replacing whatever it held.
  slot = @[widget.id]

proc setSlot*(container: Container, slot: var Slot, widgets: openArray[Widget]) =
  ## Point a slot at `widgets`, replacing whatever it held.
  slot = widgets.ids

proc setDefaultSlot*(container: Container, widget: Widget) =
  ## Make `widget` the container's default slot, replacing its contents.
  container.defaultSlot = @[widget.id]

proc setDefaultSlot*(container: Container, widgets: openArray[Widget]) =
  ## Make `widgets` the container's default slot, replacing its contents.
  container.defaultSlot = widgets.ids

proc new*(T: typedesc[Panel]): T =
  ## Create a plain panel: a background and nothing else.
  T()

proc new*(T: typedesc[Card]): T =
  ## Create a card: a raised, bordered surface that also swallows pointer
  ## presses that land on it.
  T()

proc new*(T: typedesc[DialogHeader]): T =
  ## Create a dialog header: a titled strip with a left slot and a slot of
  ## trailing controls.
  T()

method update*(self: Card, widget: Widget, ctx: var UpdateContext) =
  ## Swallow a left-button press that lands anywhere on the card.
  ##
  ## Floating cards, menu popovers included, are opaque input surfaces, so
  ## any widget that had claimed the press underneath the card loses it. The
  ## card's own children update afterwards and can claim the press again.
  discard self
  let frame = widget.frame
  let containsPointer =
    ctx.mouseX.toFloat >= frame.x and
    ctx.mouseX.toFloat < frame.x + frame.width and
    ctx.mouseY.toFloat >= frame.y and
    ctx.mouseY.toFloat < frame.y + frame.height
  if containsPointer and ctx.mouseLeftPressed:
    # Floating cards, including menu popovers, are opaque input surfaces.
    # Their children are updated after the card and may claim the press.
    ctx.activeWidgets.clear()

proc drawBorder(f: Frame, c: Color) =
  lineRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), c)

method draw*(self: Panel, widget: Widget, ctx: var DrawContext) =
  ## Fill the panel's frame with its own background colour, or the palette's.
  let f = widget.frame
  fillRect(
    rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt),
    self.styledBackground(ctx.palette.panelBackground),
  )
  fillRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, 2), ctx.palette.buttonHighlight)
  drawBorder(f, ctx.palette.panelBorder)

method draw*(self: Card, widget: Widget, ctx: var DrawContext) =
  ## Draw the card: its background, border and drop shadow.
  let f = widget.frame
  let
    x = f.x.toInt
    y = f.y.toInt
    w = f.width.toInt
    h = f.height.toInt
  if w <= 0 or h <= 0:
    return
  fillRect(rect(x + 2, y + 2, w, h), color(0, 0, 0))
  fillRect(rect(x, y, w, h), self.styledBackground(ctx.palette.cardBackground))
  drawBorder(f, ctx.palette.cardBorder)
  if w <= 2 or h <= 2:
    return
  fillRect(rect(x + 1, y + 1, max(w - 2, 0), 1), ctx.palette.buttonHighlight)
  fillRect(rect(x + 1, y + 1, 2, max(h - 2, 0)), ctx.palette.cardAccent)
  fillRect(rect(x + 1, y + h - 2, max(w - 2, 0), 1), ctx.palette.panelBorder)
  fillRect(rect(x + w - 2, y + 1, 1, max(h - 2, 0)), ctx.palette.panelBorder)

method draw*(self: DialogHeader, widget: Widget, ctx: var DrawContext) =
  ## Draw the dialog header's background and its separating border.
  let f = widget.frame
  fillRect(
    rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt),
    self.styledBackground(ctx.palette.dialogHeaderBackground),
  )
  fillRect(
    rect(f.x.toInt, (f.y + f.height).toInt, f.width.toInt, 2),
    ctx.palette.dialogHeaderBorder,
  )
