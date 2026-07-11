import ../[resources, widgets2]
import component
import uirelays

type Label* = ref object of Component
  text: string
  fontName: string

proc new*(T: typedesc[Label], text = "", fontName = "font"): T =
  T(text: text, fontName: fontName)

method measure*(self: Label, resources: Resources): IntrinsicSize =
  let measurement = resources.measureText(self.fontName, self.text)
  intrinsicSize(measurement.width.toFloat, measurement.height.toFloat)

method draw*(self: Label, widget: Widget, ctx: DrawContext) =
  let
    f = widget.frame
    (font, _) = ctx.resources.get(self.fontName)
  discard drawText(
    Font(font),
    f.x.toInt,
    f.y.toInt,
    self.text,
    ctx.palette.textColor,
    color(0, 0, 0, 0), #ctx.palette.panelBackground,
  )
