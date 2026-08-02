import ../[resources, widgets2]
import component
import nest/[coords, screen]

type Label* = ref object of Component
  text: string
  fontName: string
  hasColor: bool
  fg: Color
  textScroll: bool

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
): T =
  T(text: text, fontName: fontName, fg: fg, hasColor: hasColor, textScroll: textScroll)

proc new*(T: typedesc[DiagnosticLabel], text = "", fontName = "font", fg = color(0, 0, 0, 0), hasColor = false): T =
  T(text: text, fontName: fontName, fg: fg, hasColor: hasColor)

method measure*(self: Label, resources: Resources): IntrinsicSize =
  let measurement = resources.measureText(self.fontName, self.text)
  intrinsicSize(measurement.width.toFloat, measurement.height.toFloat)

method measure*(self: DiagnosticLabel, resources: Resources): IntrinsicSize =
  let measurement = resources.measureText(self.fontName, self.text)
  intrinsicSize(measurement.width.toFloat, measurement.height.toFloat)

method update*(self: DiagnosticLabel, widget: Widget, ctx: var UpdateContext) =
  let f = widget.frame
  let isHot =
    ctx.mouseX.toFloat >= f.x and ctx.mouseX.toFloat < f.x + f.width and
    ctx.mouseY.toFloat >= f.y and ctx.mouseY.toFloat < f.y + f.height
  if isHot:
    ctx.setHot(widget.id)
    if ctx.mouseLeftPressed:
      ctx.setActive(widget.id)

method draw*(self: Label, widget: Widget, ctx: var DrawContext) =
  let
    f = widget.frame
    (font, _) = ctx.resources.get(self.fontName)
    fg = if self.hasColor: self.fg else: ctx.palette.textColor
    textExtent = ctx.resources.measureText(self.fontName, self.text)
    textWidth = max(f.width.toInt, 0)
  if self.textScroll and textExtent.width > textWidth and textWidth > 0:
    ctx.requestRedrawAfter(33)
    let
      gap = 32
      cycle = textExtent.width + gap
      offset = (ctx.ticks div 24) mod cycle
    saveState()
    setClipRect(ctx.clippedRect(rect(f.x.toInt, f.y.toInt, textWidth, f.height.toInt)))
    discard drawText(Font(font), f.x.toInt - offset, f.y.toInt, self.text, fg, color(0, 0, 0, 0))
    discard drawText(Font(font), f.x.toInt - offset + cycle, f.y.toInt, self.text, fg, color(0, 0, 0, 0))
    restoreState()
  else:
    discard drawText(
      Font(font),
      f.x.toInt,
      f.y.toInt,
      self.text,
      fg,
      color(0, 0, 0, 0),
    )

method draw*(self: DiagnosticLabel, widget: Widget, ctx: var DrawContext) =
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
