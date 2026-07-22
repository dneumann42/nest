import ../[resources, widgets2]
import component
import nest/[coords, screen]

const
  ButtonPaddingX = 8
  ButtonPaddingY = 3
  ButtonMinHeight = 24

proc drawBorder(f: Frame, c: Color) =
  lineRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), c)

type Button* = ref object of Interactive
  label: string
  textScroll: bool

proc new*(T: typedesc[Button], label = "", textScroll = false): T =
  T(label: label, textScroll: textScroll)

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

method draw*(self: Button, widget: Widget, ctx: var DrawContext) =
  let
    f = widget.frame
    hot = ctx.hot(widget.id)
    active = ctx.active(widget.id)
  fillRect(
    rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt),
    if self.style.hasBackground:
      self.styledBackground(ctx.palette.background)
    elif not active and hot:
      ctx.palette.backgroundHot
    elif active and hot:
      ctx.palette.backgroundActive
    else:
      ctx.palette.background,
  )
  drawLine(f.x.toInt + 1, f.y.toInt + 1, (f.x + f.width - 2).toInt, f.y.toInt + 1, ctx.palette.buttonHighlight)
  drawBorder(
    f,
    if active and hot:
      ctx.palette.buttonBorderActive
    elif hot:
      ctx.palette.buttonBorderHot
    else:
      ctx.palette.buttonBorder,
  )
  let
    (font, _) = ctx.resources.get("font")
    textExtent = ctx.resources.measureText("font", self.label)
    textX = f.x.toInt + max((f.width.toInt - textExtent.width) div 2, ButtonPaddingX)
    textY = f.y.toInt + max((f.height.toInt - textExtent.height) div 2, ButtonPaddingY)
    textWidth = max(f.width.toInt - ButtonPaddingX * 2, 0)
  if self.textScroll and textExtent.width > textWidth and textWidth > 0:
    let
      gap = 32
      cycle = textExtent.width + gap
      offset = (ctx.ticks div 24) mod cycle
    saveState()
    setClipRect(ctx.clippedRect(rect(textX, f.y.toInt, textWidth, f.height.toInt)))
    discard drawText(Font(font), textX - offset, textY, self.label, ctx.palette.textColor, color(0, 0, 0, 0))
    discard drawText(Font(font), textX - offset + cycle, textY, self.label, ctx.palette.textColor, color(0, 0, 0, 0))
    restoreState()
  else:
    discard drawText(
      Font(font),
      textX,
      textY,
      self.label,
      ctx.palette.textColor,
      color(0, 0, 0, 0),
    )
