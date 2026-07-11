import resources, widgets2, uirelays
import palette

type
  Component* = ref object of RootObj
  Interactive* = ref object of Component
    hot, active: bool

proc new*(T: typedesc[Component]): T =
  T(widget: Widget.init())

method update*(c: Component, widget: Widget, ctx: var UpdateContext) {.base.} =
  discard

method draw*(c: Component, widget: Widget, ctx: DrawContext) {.base.} =
  discard

type Button* = ref object of Interactive
  label: string

proc new*(T: typedesc[Button], label = ""): T =
  T(label: label)

method update*(self: Button, widget: Widget, ctx: var UpdateContext) =
  let isHot =
    ctx.mouseX > widget.frame.x.toInt and
    ctx.mouseX < (widget.frame.x + widget.frame.width).toInt and
    ctx.mouseY > widget.frame.y.toInt and
    ctx.mouseY < (widget.frame.y + widget.frame.height).toInt
  if isHot:
    ctx.setHot(widget.id)

method draw*(self: Button, widget: Widget, ctx: DrawContext) =
  let f = widget.frame
  fillRect(
    rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt),
    if ctx.hot(widget.id):
      color(100, 120, 100)
    else:
      color(49, 50, 68),
  )
  let (font, metrics) = ctx.resources.get("font")
  discard drawText(
    Font(font), f.x.toInt, f.y.toInt, self.label, color(200, 150, 50), color(49, 50, 68)
  )
