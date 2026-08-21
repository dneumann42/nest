import std/math

import ../[resources, widgets2]
import component
import nest/[coords, screen]

const
  MenuPaddingX = 8
  MenuPaddingY = 3
  MenuMinHeight = 24
  DividerHeight = 9

type
  Menu* = ref object of Interactive
    label: string

  MenuItem* = ref object of Interactive
    selected: bool

  MenuDivider* = ref object of Component

proc new*(T: typedesc[Menu], label = ""): T =
  ## Create a menu bar entry labelled `label`.
  T(label: label)

proc new*(T: typedesc[MenuItem], selected = false): T =
  ## Create a menu item, marked `selected` when it is the current choice.
  T(selected: selected)

proc new*(T: typedesc[MenuDivider]): T =
  ## Create a horizontal divider between groups of menu items.
  T()

proc drawBorder(f: Frame, c: Color) =
  lineRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), c)

method measure*(self: Menu, resources: Resources): IntrinsicSize =
  ## Return the size of the entry's label plus the menu's padding.
  let measurement = resources.measureText("font", self.label)
  intrinsicSize(
    (measurement.width + MenuPaddingX * 2).toFloat,
    max(measurement.height + MenuPaddingY * 2, MenuMinHeight).toFloat,
  )

method measure*(self: MenuItem, resources: Resources): IntrinsicSize =
  ## Return the height of one menu item, measured from a sample string, and
  ## leave the width to the enclosing menu.
  discard self
  let measurement = resources.measureText("font", "Menu item")
  intrinsicSize(
    (measurement.width + MenuPaddingX * 2).toFloat,
    max(measurement.height + MenuPaddingY * 2, MenuMinHeight).toFloat,
  )

method measure*(self: MenuDivider, resources: Resources): IntrinsicSize =
  ## Return the divider's height; it has no width of its own.
  discard self
  discard resources
  intrinsicSize(1, DividerHeight)

method update*(self: Menu, widget: Widget, ctx: var UpdateContext) =
  ## Mark the menu entry hot while the pointer is over it and active while
  ## the left button is held on it.
  discard self
  let isHot =
    ctx.mouseX > widget.frame.x.toInt and
    ctx.mouseX < (widget.frame.x + widget.frame.width).toInt and
    ctx.mouseY > widget.frame.y.toInt and
    ctx.mouseY < (widget.frame.y + widget.frame.height).toInt
  if isHot:
    ctx.setHot(widget.id)
  if isHot and ctx.mouseLeftPressed:
    ctx.setActive(widget.id)

method update*(self: MenuItem, widget: Widget, ctx: var UpdateContext) =
  ## Mark the menu item hot while the pointer is over it and active while the
  ## left button is held on it.
  discard self
  let isHot =
    ctx.mouseX > widget.frame.x.toInt and
    ctx.mouseX < (widget.frame.x + widget.frame.width).toInt and
    ctx.mouseY > widget.frame.y.toInt and
    ctx.mouseY < (widget.frame.y + widget.frame.height).toInt
  if isHot:
    ctx.setHot(widget.id)
  if isHot and ctx.mouseLeftPressed:
    ctx.setActive(widget.id)

method draw*(self: Menu, widget: Widget, ctx: var DrawContext) =
  ## Draw the menu entry's background and label, highlighted while hot or
  ## open.
  let
    f = widget.frame
    hot = ctx.hot(widget.id)
    active = ctx.active(widget.id)
    bg =
      if active and hot:
        ctx.palette.backgroundActive
      elif hot:
        ctx.palette.backgroundHot
      else:
        self.styledBackground(ctx.palette.panelBackground)
  fillRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), bg)
  if hot:
    drawBorder(f, if active: ctx.palette.buttonBorderActive else: ctx.palette.buttonBorderHot)
  let
    (font, _) = ctx.resources.get("font")
    textExtent = ctx.resources.measureText("font", self.label)
    textX = f.x.toInt + max((f.width.toInt - textExtent.width) div 2, MenuPaddingX)
    textY = f.y.toInt + max((f.height.toInt - textExtent.height) div 2, MenuPaddingY)
  discard drawText(
    Font(font),
    textX,
    textY,
    self.label,
    ctx.palette.textColor,
    color(0, 0, 0, 0),
  )

method draw*(self: MenuItem, widget: Widget, ctx: var DrawContext) =
  ## Draw the menu item's background, its label and its selection marker.
  let
    f = widget.frame
    hot = ctx.hot(widget.id)
    active = ctx.active(widget.id)
    bg =
      if active and hot:
        ctx.palette.backgroundActive
      elif hot or self.selected:
        ctx.palette.backgroundHot
      else:
        self.styledBackground(ctx.palette.panelBackground)
  fillRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), bg)

method draw*(self: MenuDivider, widget: Widget, ctx: var DrawContext) =
  ## Draw the divider as a single line across the middle of its frame.
  discard self
  let f = widget.frame
  let y = (f.y + f.height / 2).toInt
  drawLine(
    f.x.toInt + MenuPaddingX,
    y,
    (f.x + f.width).toInt - MenuPaddingX,
    y,
    ctx.palette.panelBorder,
  )
