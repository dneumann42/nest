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
  fontName: string
  padding: float64

proc new*(T: typedesc[Button], label = "", textScroll = false,
    fontName = "font", padding = -1.0): T =
  T(label: label, textScroll: textScroll, fontName: fontName, padding: padding)

proc horizontalPadding(self: Button): float64 =
  if self.padding < 0: ButtonPaddingX.toFloat else: self.padding

proc verticalPadding(self: Button): float64 =
  if self.padding < 0: ButtonPaddingY.toFloat else: self.padding

method measure*(self: Button, resources: Resources): IntrinsicSize =
  let measurement = resources.measureText(self.fontName, self.label)
  intrinsicSize(
    measurement.width.toFloat + self.horizontalPadding * 2.0,
    max(measurement.height.toFloat + self.verticalPadding * 2.0,
      ButtonMinHeight.toFloat),
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
    rect(f.x.toInt + 2, f.y.toInt + 2, f.width.toInt, f.height.toInt),
    color(0, 0, 0))
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
  drawLine(
    f.x.toInt + 1,
    f.y.toInt + 1,
    (f.x + f.width - 2).toInt,
    f.y.toInt + 1,
    ctx.palette.buttonHighlight,
  )
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
    (font, _) = ctx.resources.get(self.fontName)
    textExtent = ctx.resources.measureText(self.fontName, self.label)
    paddingX = self.horizontalPadding.toInt
    paddingY = self.verticalPadding.toInt
    textX = f.x.toInt + max((f.width.toInt - textExtent.width) div 2, paddingX)
    textY = f.y.toInt + max((f.height.toInt - textExtent.height) div 2, paddingY)
    textWidth = max(f.width.toInt - paddingX * 2, 0)
  if self.textScroll and textExtent.width > textWidth and textWidth > 0:
    ctx.requestRedrawAfter(33)
    let
      gap = 32
      cycle = textExtent.width + gap
      offset = (ctx.ticks div 24) mod cycle
    saveState()
    setClipRect(ctx.clippedRect(rect(textX, f.y.toInt, textWidth, f.height.toInt)))
    discard drawText(
      Font(font),
      textX - offset,
      textY,
      self.label,
      ctx.palette.textColor,
      color(0, 0, 0, 0),
    )
    discard drawText(
      Font(font),
      textX - offset + cycle,
      textY,
      self.label,
      ctx.palette.textColor,
      color(0, 0, 0, 0),
    )
    restoreState()
  else:
    discard drawText(
      Font(font), textX, textY, self.label, ctx.palette.textColor, color(0, 0, 0, 0)
    )
