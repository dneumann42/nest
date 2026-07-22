import std/math

import ../[resources, widgets2]
import component
import uirelays/[coords, screen]

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
  T(label: label)

proc new*(T: typedesc[MenuItem], selected = false): T =
  T(selected: selected)

proc new*(T: typedesc[MenuDivider]): T =
  T()

proc drawBorder(f: Frame, c: Color) =
  let
    x = f.x.toInt
    y = f.y.toInt
    w = f.width.toInt
    h = f.height.toInt
  if w <= 0 or h <= 0:
    return
  drawLine(x, y, x + w - 1, y, c)
  drawLine(x, y + h - 1, x + w - 1, y + h - 1, c)
  drawLine(x, y, x, y + h - 1, c)
  drawLine(x + w - 1, y, x + w - 1, y + h - 1, c)

method measure*(self: Menu, resources: Resources): IntrinsicSize =
  let measurement = resources.measureText("font", self.label)
  intrinsicSize(
    (measurement.width + MenuPaddingX * 2).toFloat,
    max(measurement.height + MenuPaddingY * 2, MenuMinHeight).toFloat,
  )

method measure*(self: MenuItem, resources: Resources): IntrinsicSize =
  discard self
  let measurement = resources.measureText("font", "Menu item")
  intrinsicSize(
    (measurement.width + MenuPaddingX * 2).toFloat,
    max(measurement.height + MenuPaddingY * 2, MenuMinHeight).toFloat,
  )

method measure*(self: MenuDivider, resources: Resources): IntrinsicSize =
  discard self
  discard resources
  intrinsicSize(1, DividerHeight)

method update*(self: Menu, widget: Widget, ctx: var UpdateContext) =
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

method draw*(self: Menu, widget: Widget, ctx: DrawContext) =
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

method draw*(self: MenuItem, widget: Widget, ctx: DrawContext) =
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

method draw*(self: MenuDivider, widget: Widget, ctx: DrawContext) =
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
