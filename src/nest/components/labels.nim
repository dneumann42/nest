import ../[resources, widgets2]
import component
import uirelays

type Label* = ref object of Component
  text: string

proc new*(T: typedesc[Label], text = ""): T =
  T(text: text)

method draw*(self: Label, widget: Widget, ctx: DrawContext) =
  let
    f = widget.frame
    (font, _) = ctx.resources.get("font")
  discard drawText(
    Font(font),
    f.x.toInt,
    f.y.toInt,
    self.text,
    ctx.palette.textColor,
    ctx.palette.panelBackground,
  )
