import ../widgets2
import ../resources
import nest/screen

type
  ComponentStyle* = object
    hasBackground*: bool
    background*: Color
    hasOpacity*: bool
    opacity*: float64

  Component* = ref object of RootObj
    style*: ComponentStyle
  Interactive* = ref object of Component
    hot, active: bool

proc clamp(value, lo, hi: float64): float64 =
  min(max(value, lo), hi)

proc styledBackground*(component: Component, fallback: Color): Color =
  result =
    if component.style.hasBackground:
      component.style.background
    else:
      fallback
  if component.style.hasOpacity:
    result.a = uint8((component.style.opacity.clamp(0.0, 1.0) * 255.0 + 0.5).int)

proc new*(T: typedesc[Component]): T =
  T()

method update*(c: Component, widget: Widget, ctx: var UpdateContext) {.base.} =
  discard

method measure*(c: Component, resources: Resources): IntrinsicSize {.base.} =
  discard

method draw*(c: Component, widget: Widget, ctx: var DrawContext) {.base.} =
  discard

method drawOverlay*(c: Component, widget: Widget, ctx: var DrawContext) {.base.} =
  discard
