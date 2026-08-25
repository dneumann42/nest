import std/[os, strutils]

import ../[layouts, resources, widgets2]
import component
import nest/[coords, screen]

const
  ButtonPaddingX = 8
  ButtonPaddingY = 3
  ButtonMinHeight = ControlHeight

let AnimateTextScroll = getEnv("NEST_TEXT_SCROLL_ANIMATION").normalize in
  ["1", "true", "yes", "on"]

type Button* = ref object of Interactive
  label: string
  textScroll: bool
  fontName: string
  padding: EdgeInsets
  borderStyle: ButtonBorderStyle
  chromeStyle: ButtonChromeStyle
  textAlign: Justification

proc drawBorder(self: Button, f: Frame, c: Color) =
  self.styledLineRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), c)

proc new*(T: typedesc[Button], label = "", textScroll = false,
    fontName = "font", padding = insets(-1.0),
    borderStyle = ButtonBorderLine, chromeStyle = ButtonChromeRaised,
    textAlign = JustifyCenter): T =
  ## Create a button component labelled `label`.
  ##
  ## `textScroll` clips text wider than the button. Marquee animation is
  ## opt-in with NEST_TEXT_SCROLL_ANIMATION=1. `fontName` picks a loaded font,
  ## and `padding` overrides the default insets around the text; negative
  ## insets keep the default.
  T(label: label, textScroll: textScroll, fontName: fontName, padding: padding,
      borderStyle: borderStyle, chromeStyle: chromeStyle,
      textAlign: textAlign)

proc new*(T: typedesc[Button], label: string, textScroll: bool,
    fontName: string, padding: float64,
    borderStyle = ButtonBorderLine, chromeStyle = ButtonChromeRaised,
    textAlign = JustifyCenter): T =
  ## Create a button component with the same `padding` on every edge.
  T.new(label, textScroll, fontName, insets(padding), borderStyle, chromeStyle,
      textAlign)

proc leftPadding(self: Button): float64 =
  if self.padding.left < 0: ButtonPaddingX.toFloat else: self.padding.left

proc rightPadding(self: Button): float64 =
  if self.padding.right < 0: ButtonPaddingX.toFloat else: self.padding.right

proc topPadding(self: Button): float64 =
  if self.padding.top < 0: ButtonPaddingY.toFloat else: self.padding.top

proc bottomPadding(self: Button): float64 =
  if self.padding.bottom < 0: ButtonPaddingY.toFloat else: self.padding.bottom

proc isIconButton(self: Button): bool =
  self.fontName.startsWith("icon")

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
    iconButton = self.isIconButton()
  if self.chromeStyle == ButtonChromeRaised and not iconButton:
    self.drawShadow(bounds)
  if self.chromeStyle == ButtonChromeRaised and not iconButton and
      not self.style.hasShadow:
    self.styledFillRect(
      rect(f.x.toInt + 2, f.y.toInt + 2, f.width.toInt, f.height.toInt),
      color(0, 0, 0))
  if not iconButton:
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
  if self.chromeStyle == ButtonChromeRaised and not iconButton and
      self.style.cornerStyle == FlatCorners:
    drawLine(
      f.x.toInt + 1,
      f.y.toInt + 1,
      (f.x + f.width - 2).toInt,
      f.y.toInt + 1,
      ctx.palette.buttonHighlight,
    )
  if self.borderStyle == ButtonBorderLine and not iconButton:
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
    centeredTextX = f.x.toInt + max((f.width.toInt - textExtent.width) div 2,
        paddingLeft)
    textX =
      case self.textAlign
      of JustifyEnd:
        f.x.toInt + max(f.width.toInt - textExtent.width - paddingRight,
            paddingLeft)
      of JustifyCenter:
        centeredTextX
      else:
        f.x.toInt + paddingLeft
    textY = f.y.toInt + max((f.height.toInt - textExtent.height) div 2, paddingTop)
    textWidth = max(f.width.toInt - paddingLeft - paddingRight, 0)
    textColor =
      if iconButton and active and hot:
        ctx.palette.buttonBorderActive
      elif iconButton and hot:
        ctx.palette.buttonBorderHot
      else:
        ctx.palette.textColor
  if self.textScroll and textExtent.width > textWidth and textWidth > 0:
    let offset =
      if AnimateTextScroll:
        ctx.requestRedrawAfter(33)
        let
          gap = 32
          cycle = textExtent.width + gap
        (ctx.ticks div 24) mod cycle
      else:
        0
    saveState()
    setClipRect(ctx.clippedRect(rect(textX, f.y.toInt, textWidth,
        f.height.toInt)))
    discard drawText(
      Font(font),
      textX - offset,
      textY,
      self.label,
      textColor,
      color(0, 0, 0, 0),
    )
    if AnimateTextScroll:
      let gap = 32
      discard drawText(
        Font(font),
        textX - offset + textExtent.width + gap,
        textY,
        self.label,
        textColor,
        color(0, 0, 0, 0),
      )
    restoreState()
  else:
    if iconButton and hot:
      discard drawText(
        Font(font), textX + 1, textY + 1, self.label, color(0, 0, 0, 150),
        color(0, 0, 0, 0)
      )
    discard drawText(
      Font(font), textX, textY, self.label, textColor, color(0, 0,
          0, 0)
    )
