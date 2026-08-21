import ../[resources, widgets2]
import component
import nest/[coords, screen]

const
  SwatchMinSize = 28
  CheckerSize = 6

type ColorSwatch* = ref object of Component
  value: Color
  border: bool

proc new*(T: typedesc[ColorSwatch], value: Color, border = true): T =
  ## Create a swatch that shows `value`, optionally without its border.
  T(value: value, border: border)

method measure*(self: ColorSwatch, resources: Resources): IntrinsicSize =
  ## Return the swatch's minimum size; swatches carry no content to measure.
  discard self
  discard resources
  intrinsicSize(SwatchMinSize.toFloat, SwatchMinSize.toFloat)

proc drawBorder(f: Frame, c: Color) =
  lineRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), c)

method draw*(self: ColorSwatch, widget: Widget, ctx: var DrawContext) =
  ## Draw the swatch: its colour over the card background, so a translucent
  ## value reads correctly, plus its border.
  let f = widget.frame
  let bounds = rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt)
  fillRect(bounds, ctx.palette.cardBackground)

  let
    x0 = f.x.toInt
    y0 = f.y.toInt
    w = max(f.width.toInt, 0)
    h = max(f.height.toInt, 0)
  var y = 0
  while y < h:
    var x = 0
    while x < w:
      let shade =
        if ((x div CheckerSize) + (y div CheckerSize)) mod 2 == 0:
          color(192, 192, 192)
        else:
          color(128, 128, 128)
      fillRect(rect(x0 + x, y0 + y, min(CheckerSize, w - x),
          min(CheckerSize, h - y)), shade)
      x += CheckerSize
    y += CheckerSize

  fillRect(bounds, self.value)
  if self.border:
    drawBorder(f, ctx.palette.buttonBorder)
