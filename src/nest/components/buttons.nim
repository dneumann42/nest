import ../[layouts, resources, widgets2]
import component
import nest/[coords, screen]

const
  ButtonPaddingX = 8
  ButtonPaddingY = 3
  ButtonMinHeight = ControlHeight

type Button* = ref object of Interactive
  label: string
  textScroll: bool
  fontName: string
  padding: EdgeInsets

proc drawBorder(self: Button, f: Frame, c: Color) =
  self.styledLineRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), c)

proc new*(T: typedesc[Button], label = "", textScroll = false,
    fontName = "font", padding = insets(-1.0)): T =
  ## Create a button component labelled `label`.
  ##
  ## `textScroll` lets a label wider than the button scroll instead of being
  ## clipped, `fontName` picks a loaded font, and `padding` overrides the
  ## default insets around the text; negative insets keep the default.
  T(label: label, textScroll: textScroll, fontName: fontName, padding: padding)

proc new*(T: typedesc[Button], label: string, textScroll: bool,
    fontName: string, padding: float64): T =
  ## Create a button component with the same `padding` on every edge.
  T.new(label, textScroll, fontName, insets(padding))

proc leftPadding(self: Button): float64 =
  if self.padding.left < 0: ButtonPaddingX.toFloat else: self.padding.left

proc rightPadding(self: Button): float64 =
  if self.padding.right < 0: ButtonPaddingX.toFloat else: self.padding.right

proc topPadding(self: Button): float64 =
  if self.padding.top < 0: ButtonPaddingY.toFloat else: self.padding.top

proc bottomPadding(self: Button): float64 =
  if self.padding.bottom < 0: ButtonPaddingY.toFloat else: self.padding.bottom

method measure*(self: Button, resources: Resources): IntrinsicSize =
  ## Return the size of the label plus the button's padding.
  let measurement = resources.measureText(self.fontName, self.label)
  intrinsicSize(
    measurement.width.toFloat + self.leftPadding + self.rightPadding,
    max(measurement.height.toFloat + self.topPadding + self.bottomPadding,
      ButtonMinHeight.toFloat),
  )

method update*(self: Button, widget: Widget, ctx: var UpdateContext) =
  ## Mark the button hot while the pointer is over it and active while the
  ## left button is held on it.
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
  ## Draw the button's background, border and label, styled for its hot and
  ## active state.
  let
    f = widget.frame
    hot = ctx.hot(widget.id)
    active = ctx.active(widget.id)
    bounds = rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt)
  self.drawShadow(bounds)
  if not self.style.hasShadow:
    self.styledFillRect(
      rect(f.x.toInt + 2, f.y.toInt + 2, f.width.toInt, f.height.toInt),
      color(0, 0, 0))
  self.styledFillRect(
    bounds,
    if self.style.hasBackground:
      self.styledBackground(ctx.palette.background)
    elif not active and hot:
      ctx.palette.backgroundHot
    elif active and hot:
      ctx.palette.backgroundActive
    else:
      ctx.palette.background,
  )
  if self.style.cornerStyle == FlatCorners:
    drawLine(
      f.x.toInt + 1,
      f.y.toInt + 1,
      (f.x + f.width - 2).toInt,
      f.y.toInt + 1,
      ctx.palette.buttonHighlight,
    )
  self.drawBorder(
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
    paddingLeft = self.leftPadding.toInt
    paddingTop = self.topPadding.toInt
    paddingRight = self.rightPadding.toInt
    textX = f.x.toInt + max((f.width.toInt - textExtent.width) div 2, paddingLeft)
    textY = f.y.toInt + max((f.height.toInt - textExtent.height) div 2, paddingTop)
    textWidth = max(f.width.toInt - paddingLeft - paddingRight, 0)
  if self.textScroll and textExtent.width > textWidth and textWidth > 0:
    ctx.requestRedrawAfter(33)
    let
      gap = 32
      cycle = textExtent.width + gap
      offset = (ctx.ticks div 24) mod cycle
    saveState()
    setClipRect(ctx.clippedRect(rect(textX, f.y.toInt, textWidth,
        f.height.toInt)))
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
      Font(font), textX, textY, self.label, ctx.palette.textColor, color(0, 0,
          0, 0)
    )
