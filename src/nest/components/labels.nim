import std/[os, strutils]

import ../[layouts, resources, widgets2]
import component
import nest/[coords, screen]

let AnimateTextScroll = getEnv("NEST_TEXT_SCROLL_ANIMATION").normalize in
  ["1", "true", "yes", "on"]

type Label* = ref object of Component
  text: string
  fontName: string
  hasColor: bool
  fg: Color
  textScroll: bool
  padding: EdgeInsets

type DiagnosticLabel* = ref object of Interactive
  text: string
  fontName: string
  hasColor: bool
  fg: Color

proc new*(
    T: typedesc[Label],
    text = "",
    fontName = "font",
    fg = color(0, 0, 0, 0),
    hasColor = false,
    textScroll = false,
    padding = EdgeInsets(),
): T =
  ## Create a text label.
  ##
  ## `fg` together with `hasColor` overrides the palette's text colour.
  ## `textScroll` clips text wider than the widget; marquee animation is
  ## opt-in with NEST_TEXT_SCROLL_ANIMATION=1.
  T(text: text, fontName: fontName, fg: fg, hasColor: hasColor,
      textScroll: textScroll, padding: padding)

proc new*(T: typedesc[DiagnosticLabel], text = "", fontName = "font", fg = color(0, 0, 0, 0), hasColor = false): T =
  ## Create a label that reacts to the pointer, used for clickable
  ## diagnostics such as compiler messages.
  ##
  ## `fg` together with `hasColor` overrides the palette's text colour.
  T(text: text, fontName: fontName, fg: fg, hasColor: hasColor)

method measure*(self: Label, resources: Resources): IntrinsicSize =
  ## Return the size the label's text occupies.
  let measurement = resources.measureText(self.fontName, self.text)
  intrinsicSize(
    measurement.width.toFloat + self.padding.left + self.padding.right,
    measurement.height.toFloat + self.padding.top + self.padding.bottom,
  )

method measure*(self: DiagnosticLabel, resources: Resources): IntrinsicSize =
  ## Return the size the diagnostic's text occupies.
  let measurement = resources.measureText(self.fontName, self.text)
  intrinsicSize(measurement.width.toFloat, measurement.height.toFloat)

method update*(self: DiagnosticLabel, widget: Widget, ctx: var UpdateContext) =
  ## Mark the diagnostic hot while the pointer is over it and active while
  ## the left button is held on it, so a caller can treat it as a click
  ## target.
  let f = widget.frame
  let isHot =
    ctx.mouseX.toFloat >= f.x and ctx.mouseX.toFloat < f.x + f.width and
    ctx.mouseY.toFloat >= f.y and ctx.mouseY.toFloat < f.y + f.height
  if isHot:
    ctx.setHot(widget.id)
    if ctx.mouseLeftPressed:
      ctx.setActive(widget.id)

method draw*(self: Label, widget: Widget, ctx: var DrawContext) =
  ## Draw the label's text, clipped or scrolled to fit its frame.
  let
    f = widget.frame
    bounds = rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt)
    (font, _) = ctx.resources.get(self.fontName)
    fg = if self.hasColor: self.fg else: ctx.palette.textColor
    textExtent = ctx.resources.measureText(self.fontName, self.text)
    textX = f.x.toInt + self.padding.left.toInt
    textY = f.y.toInt + self.padding.top.toInt
    textWidth = max(f.width.toInt - self.padding.left.toInt - self.padding.right.toInt, 0)
    textHeight = max(f.height.toInt - self.padding.top.toInt - self.padding.bottom.toInt, 0)
  self.drawShadow(bounds)
  if self.style.hasBackground:
    self.styledFillRect(bounds, self.styledBackground(ctx.palette.panelMuted))
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
    setClipRect(ctx.clippedRect(rect(textX, textY, textWidth, textHeight)))
    discard drawText(Font(font), textX - offset, textY, self.text, fg, color(0, 0, 0, 0))
    if AnimateTextScroll:
      let gap = 32
      discard drawText(
        Font(font),
        textX - offset + textExtent.width + gap,
        textY,
        self.text,
        fg,
        color(0, 0, 0, 0),
      )
    restoreState()
  else:
    discard drawText(
      Font(font),
      textX,
      textY,
      self.text,
      fg,
      color(0, 0, 0, 0),
    )

method draw*(self: DiagnosticLabel, widget: Widget, ctx: var DrawContext) =
  ## Draw the diagnostic's text, highlighting its background while hot.
  let
    f = widget.frame
    (font, _) = ctx.resources.get(self.fontName)
    fg = if self.hasColor: self.fg else: ctx.palette.textColor
  if ctx.hot(widget.id):
    fillRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), ctx.palette.panelMuted)
  discard drawText(
    Font(font),
    f.x.toInt,
    f.y.toInt,
    self.text,
    fg,
    color(0, 0, 0, 0),
  )
