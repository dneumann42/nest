import resources, widgets2, uirelays

type
  Component* = ref object of RootObj
  Interactive* = ref object of Component
    hot, active: bool

proc new*(T: typedesc[Component]): T =
  T(widget: Widget.init())

method update*(c: Component, widget: Widget, ctx: UpdateContext) {.base.} =
  discard

method draw*(c: Component, widget: Widget, ctx: DrawContext) {.base.} =
  discard

method update*(self: Interactive, widget: Widget) =
  discard

type Button* = ref object of Interactive
  label: string

proc new*(T: typedesc[Button], label = ""): T =
  T(label: label)

method update*(self: Button, widget: Widget, ctx: UpdateContext) =
  discard

method draw*(self: Button, widget: Widget, ctx: DrawContext) =
  let f = widget.frame
  fillRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), color(49, 50, 68))

  let (font, metrics) = ctx.resources.get("font")

  discard drawText(
    Font(font), f.x.toInt, f.y.toInt, self.label, color(200, 150, 50), color(49, 50, 68)
  )
