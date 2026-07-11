import ../[resources, widgets2]
import component
import uirelays

const
  ButtonPaddingX = 8
  ButtonPaddingY = 3
  ButtonMinHeight = 24

type Button* = ref object of Interactive
  label: string

proc new*(T: typedesc[Button], label = ""): T =
  T(label: label)

method measure*(self: Button, resources: Resources): IntrinsicSize =
  let measurement = resources.measureText("font", self.label)
  intrinsicSize(
    (measurement.width + ButtonPaddingX * 2).toFloat,
    max(measurement.height + ButtonPaddingY * 2, ButtonMinHeight).toFloat,
  )

method update*(self: Button, widget: Widget, ctx: var UpdateContext) =
  let isHot =
    ctx.mouseX > widget.frame.x.toInt and
    ctx.mouseX < (widget.frame.x + widget.frame.width).toInt and
    ctx.mouseY > widget.frame.y.toInt and
    ctx.mouseY < (widget.frame.y + widget.frame.height).toInt
  let isActive = isHot and ctx.mouseLeftPressed
  if isHot:
    ctx.setHot(widget.id)
  if isActive:
    ctx.setActive(widget.id)

method draw*(self: Button, widget: Widget, ctx: DrawContext) =
  let
    f = widget.frame
    hot = ctx.hot(widget.id)
    active = ctx.active(widget.id)
  fillRect(
    rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt),
    if not active and hot:
      ctx.palette.backgroundHot
    elif active and hot:
      ctx.palette.backgroundActive
    else:
      ctx.palette.background,
  )
  let (font, _) = ctx.resources.get("font")
  discard drawText(
    Font(font),
    f.x.toInt + ButtonPaddingX,
    f.y.toInt + ButtonPaddingY,
    self.label,
    ctx.palette.textColor,
    color(0, 0, 0, 0),
  )
