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
  ## Return the component's own background colour, or `fallback` when its
  ## style does not set one.
  result =
    if component.style.hasBackground:
      component.style.background
    else:
      fallback
  if component.style.hasOpacity:
    result.a = uint8((component.style.opacity.clamp(0.0, 1.0) * 255.0 + 0.5).int)

proc new*(T: typedesc[Component]): T =
  ## Create a bare component that measures, updates and draws as nothing.
  ##
  ## Useful as a placeholder and as the base for subclasses.
  T()

method update*(c: Component, widget: Widget, ctx: var UpdateContext) {.base.} =
  ## React to this frame's input for the widget the component is attached to.
  ##
  ## Called once per frame before drawing, with `widget` already laid out.
  ## Override to mark the widget hot, active or submitted, or to change the
  ## component's own state. Does nothing by default.
  discard

method measure*(c: Component, resources: Resources): IntrinsicSize {.base.} =
  ## Return the size the component's content wants, which a `fit` size
  ## policy resolves to.
  ##
  ## `resources` provides the font and image metrics needed to measure.
  ## Reports no intrinsic size by default.
  discard

method draw*(c: Component, widget: Widget, ctx: var DrawContext) {.base.} =
  ## Draw the component inside its widget's frame. Draws nothing by default.
  discard

method drawOverlay*(c: Component, widget: Widget, ctx: var DrawContext) {.base.} =
  ## Draw the parts of the component that must appear above its siblings,
  ## such as an open dropdown list.
  ##
  ## Called after every component's `draw`. Draws nothing by default.
  discard
