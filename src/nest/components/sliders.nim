import ../[resources, widgets2]
import component
import nest/[coords, screen]

const
  SliderMinThickness = 28
  TrackThickness = 4
  ThumbSize = 16

type
  SliderOrientation* = enum
    SliderHorizontal
    SliderVertical

  Slider* = ref object of Interactive
    value, minimum, maximum: float64
    orientation: SliderOrientation

proc new*(
    T: typedesc[Slider],
    value = 0.0,
    minimum = 0.0,
    maximum = 1.0,
    orientation = SliderHorizontal,
): T =
  T(value: value, minimum: minimum, maximum: maximum, orientation: orientation)

proc clamp(value, lo, hi: float64): float64 =
  min(max(value, lo), hi)

proc normalized(value, minimum, maximum: float64): float64 =
  if maximum <= minimum:
    0.0
  else:
    ((value - minimum) / (maximum - minimum)).clamp(0.0, 1.0)

proc denormalized(value, minimum, maximum: float64): float64 =
  minimum + value.clamp(0.0, 1.0) * (maximum - minimum)

proc sliderValueFromMouse*(
    frame: Frame,
    mouseX, mouseY: int,
    minimum, maximum: float64,
    orientation: SliderOrientation,
): float64 =
  let n =
    case orientation
    of SliderHorizontal:
      if frame.width <= 0: 0.0
      else: ((mouseX.toFloat - frame.x) / frame.width).clamp(0.0, 1.0)
    of SliderVertical:
      if frame.height <= 0: 0.0
      else: (1.0 - (mouseY.toFloat - frame.y) / frame.height).clamp(0.0, 1.0)
  denormalized(n, minimum, maximum)

proc contains(frame: Frame, x, y: int): bool =
  x.toFloat >= frame.x and x.toFloat < frame.x + frame.width and
    y.toFloat >= frame.y and y.toFloat < frame.y + frame.height

method measure*(self: Slider, resources: Resources): IntrinsicSize =
  discard resources
  case self.orientation
  of SliderHorizontal:
    intrinsicSize(120, SliderMinThickness)
  of SliderVertical:
    intrinsicSize(SliderMinThickness, 120)

method update*(self: Slider, widget: Widget, ctx: var UpdateContext) =
  let hot = widget.frame.contains(ctx.mouseX, ctx.mouseY)
  if hot:
    ctx.setHot(widget.id)
  if ctx.mouseLeftDown and (hot or ctx.sliderDragging == widget.id):
    ctx.setActive(widget.id)
    ctx.setSliderValue(
      widget.id,
      sliderValueFromMouse(widget.frame, ctx.mouseX, ctx.mouseY, self.minimum, self.maximum, self.orientation),
    )

proc drawBorder(f: Frame, c: Color) =
  lineRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), c)

method draw*(self: Slider, widget: Widget, ctx: var DrawContext) =
  let
    f = widget.frame
    n = normalized(self.value, self.minimum, self.maximum)
    hot = ctx.hot(widget.id)
    active = ctx.active(widget.id)
    border =
      if active:
        ctx.palette.buttonBorderActive
      elif hot:
        ctx.palette.buttonBorderHot
      else:
        ctx.palette.buttonBorder
  fillRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), ctx.palette.cardBackground)
  drawBorder(f, border)

  case self.orientation
  of SliderHorizontal:
    let
      trackX = f.x.toInt + 8
      trackY = (f.y + f.height / 2.0).toInt - TrackThickness div 2
      trackW = max(f.width.toInt - 16, 1)
      fillW = max((trackW.toFloat * n).toInt, TrackThickness)
      thumbX = trackX + (trackW.toFloat * n).toInt - ThumbSize div 2
      thumbY = (f.y + f.height / 2.0).toInt - ThumbSize div 2
    fillRect(rect(trackX, trackY, trackW, TrackThickness), ctx.palette.panelMuted)
    fillRect(rect(trackX, trackY, fillW, TrackThickness), ctx.palette.cardAccent)
    fillRect(rect(thumbX, thumbY, ThumbSize, ThumbSize), ctx.palette.backgroundActive)
    drawBorder(Frame(x: thumbX.toFloat, y: thumbY.toFloat, width: ThumbSize.toFloat, height: ThumbSize.toFloat), border)
  of SliderVertical:
    let
      trackX = (f.x + f.width / 2.0).toInt - TrackThickness div 2
      trackY = f.y.toInt + 8
      trackH = max(f.height.toInt - 16, 1)
      fillH = max((trackH.toFloat * n).toInt, TrackThickness)
      fillY = trackY + trackH - fillH
      thumbX = (f.x + f.width / 2.0).toInt - ThumbSize div 2
      thumbY = trackY + trackH - (trackH.toFloat * n).toInt - ThumbSize div 2
    fillRect(rect(trackX, trackY, TrackThickness, trackH), ctx.palette.panelMuted)
    fillRect(rect(trackX, fillY, TrackThickness, fillH), ctx.palette.cardAccent)
    fillRect(rect(thumbX, thumbY, ThumbSize, ThumbSize), ctx.palette.backgroundActive)
    drawBorder(Frame(x: thumbX.toFloat, y: thumbY.toFloat, width: ThumbSize.toFloat, height: ThumbSize.toFloat), border)
