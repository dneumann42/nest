import ../widgets2
import ../resources

type
  Component* = ref object of RootObj
  Interactive* = ref object of Component
    hot, active: bool

proc new*(T: typedesc[Component]): T =
  T(widget: Widget.init())

method update*(c: Component, widget: Widget, ctx: var UpdateContext) {.base.} =
  discard

method measure*(c: Component, resources: Resources): IntrinsicSize {.base.} =
  discard

method draw*(c: Component, widget: Widget, ctx: DrawContext) {.base.} =
  discard
