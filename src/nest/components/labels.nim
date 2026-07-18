import ../[resources, widgets2]
import component
import uirelays/screen

type Label* = ref object of Component
  text: string
  fontName: string
  hasColor: bool
  fg: Color

type DiagnosticLabel* = ref object of Interactive
  text: string
  fontName: string
  hasColor: bool
  fg: Color

proc new*(T: typedesc[Label], text = "", fontName = "font", fg = color(0, 0, 0, 0), hasColor = false): T =
  T(text: text, fontName: fontName, fg: fg, hasColor: hasColor)

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

method draw*(self: Label, widget: Widget, ctx: DrawContext) =
  let
    f = widget.frame
    (font, _) = ctx.resources.get(self.fontName)
  discard drawText(
    Font(font),
    f.x.toInt,
    f.y.toInt,
    self.text,
    if self.hasColor: self.fg else: ctx.palette.textColor,
    color(0, 0, 0, 0), #ctx.palette.panelBackground,
  )

method draw*(self: DiagnosticLabel, widget: Widget, ctx: DrawContext) =
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
