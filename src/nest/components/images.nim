import std/[math]

import ../[resources, widgets2]
import component
import nest/[coords, screen]

type
  ImageView* = ref object of Component
    path: string
    source: Rect
    hasSource: bool

  PanZoomImageState* = ref object
    zoom*: float64
    offsetX*, offsetY*: float64
    panning*: bool
    lastPanMouseX*, lastPanMouseY*: int

  PanZoomImageView* = ref object of Component
    path: string
    state: PanZoomImageState

  ImageButton* = ref object of Interactive
    path: string
    source: Rect
    hasSource: bool

proc new*(T: typedesc[ImageView], path = ""): T =
  ## Create an image view showing the whole image at `path`.
  T(path: path)

proc new*(T: typedesc[ImageView], path: string, source: Rect): T =
  ## Create an image view showing only the `source` region of the image at
  ## `path`, as one sprite out of a sheet.
  T(path: path, source: source, hasSource: true)

proc new*(T: typedesc[PanZoomImageState]): T =
  T(zoom: 1.0)

proc new*(T: typedesc[PanZoomImageView], path: string,
    state: PanZoomImageState): T =
  ## Create an interactive image view with retained pan and zoom state.
  T(path: path, state: state)

proc new*(T: typedesc[ImageButton], path = ""): T =
  ## Create a clickable image button showing the whole image at `path`.
  T(path: path)

proc new*(T: typedesc[ImageButton], path: string, source: Rect): T =
  ## Create a clickable image button showing only the `source` region of the
  ## image at `path`.
  T(path: path, source: source, hasSource: true)

method measure*(self: ImageView, resources: Resources): IntrinsicSize =
  ## Return the size of the source region, or of the whole image when the
  ## view shows all of it.
  if self.hasSource:
    intrinsicSize(self.source.w.toFloat, self.source.h.toFloat)
  else:
    let size = resources.measureImage(self.path)
    intrinsicSize(size.w.toFloat, size.h.toFloat)

method measure*(self: ImageButton, resources: Resources): IntrinsicSize =
  ## Return the size of the source region, or of the whole image when the
  ## button shows all of it.
  if self.hasSource:
    intrinsicSize(self.source.w.toFloat, self.source.h.toFloat)
  else:
    let size = resources.measureImage(self.path)
    intrinsicSize(size.w.toFloat, size.h.toFloat)

method measure*(self: PanZoomImageView, resources: Resources): IntrinsicSize =
  discard self
  discard resources
  intrinsicSize(160.0, 120.0)

proc isInside(widget: Widget, ctx: UpdateContext): bool =
  let f = widget.frame
  ctx.mouseX.toFloat >= f.x and ctx.mouseX.toFloat < f.x + f.width and
    ctx.mouseY.toFloat >= f.y and ctx.mouseY.toFloat < f.y + f.height

method update*(self: ImageButton, widget: Widget, ctx: var UpdateContext) =
  ## Mark the button hot while the pointer is over it and active while the
  ## left button is held on it.
  let hot = widget.isInside(ctx)
  if hot:
    ctx.setHot(widget.id)
    if ctx.mouseLeftPressed:
      ctx.setActive(widget.id)

method update*(self: PanZoomImageView, widget: Widget, ctx: var UpdateContext) =
  ## Pan with the middle mouse button and zoom around the pointer with the
  ## mouse wheel.
  if self.state.isNil:
    return
  let hot = widget.isInside(ctx)
  if hot:
    ctx.setHot(widget.id)
  if hot and ctx.mouseWheelY != 0:
    let
      oldZoom = self.state.zoom.clamp(0.05, 64.0)
      newZoom = (oldZoom * pow(1.2, ctx.mouseWheelY)).clamp(0.05, 64.0)
      frame = widget.frame
      anchorX = ctx.mouseX.float64 - frame.x - frame.width * 0.5
      anchorY = ctx.mouseY.float64 - frame.y - frame.height * 0.5
    if oldZoom > 0:
      self.state.offsetX = anchorX - (anchorX - self.state.offsetX) *
          (newZoom / oldZoom)
      self.state.offsetY = anchorY - (anchorY - self.state.offsetY) *
          (newZoom / oldZoom)
    self.state.zoom = newZoom
  if hot and ctx.mouseMiddlePressed:
    self.state.panning = true
    self.state.lastPanMouseX = ctx.mouseX
    self.state.lastPanMouseY = ctx.mouseY
  if self.state.panning and ctx.mouseMiddleDown:
    self.state.offsetX += (ctx.mouseX - self.state.lastPanMouseX).float64
    self.state.offsetY += (ctx.mouseY - self.state.lastPanMouseY).float64
    self.state.lastPanMouseX = ctx.mouseX
    self.state.lastPanMouseY = ctx.mouseY
  if not ctx.mouseMiddleDown:
    self.state.panning = false

proc drawImagePath(
    path: string, widget: Widget, ctx: var DrawContext, source: Rect,
        hasSource: bool
) =
  let
    size = ctx.resources.measureImage(path)
    f = widget.frame
  if size.w <= 0 or size.h <= 0 or f.width <= 0 or f.height <= 0:
    fillRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt),
        ctx.palette.panelMuted)
    ctx.requestRedrawAfter(250)
    return
  let src =
    if hasSource and source.w > 0 and source.h > 0:
      rect(
        max(source.x, 0),
        max(source.y, 0),
        min(source.w, max(size.w - source.x, 0)),
        min(source.h, max(size.h - source.y, 0)),
      )
    else:
      rect(0, 0, size.w, size.h)
  if src.w <= 0 or src.h <= 0:
    return
  let
    scale = min(f.width / src.w.toFloat, f.height / src.h.toFloat)
    width = src.w.toFloat * scale
    height = src.h.toFloat * scale
    x = f.x + (f.width - width) / 2.0
    y = f.y + (f.height - height) / 2.0
  drawImage(
    path,
    src,
    rect(x.toInt, y.toInt, width.toInt, height.toInt),
  )

method draw*(self: ImageView, widget: Widget, ctx: var DrawContext) =
  ## Draw the image, scaled into the widget's frame.
  drawImagePath(self.path, widget, ctx, self.source, self.hasSource)

method draw*(self: PanZoomImageView, widget: Widget, ctx: var DrawContext) =
  let
    f = widget.frame
    bounds = rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt)
    size = ctx.resources.measureImage(self.path)
  fillRect(bounds, ctx.palette.panelMuted)
  if size.w <= 0 or size.h <= 0 or f.width <= 0 or f.height <= 0:
    let
      (font, _) = ctx.resources.get("font")
      message =
        if self.path.len == 0:
          "No image path"
        else:
          "Image failed to load: " & self.path
      textSize = ctx.resources.measureText("font", message)
      textX = f.x.toInt + max((f.width.toInt - textSize.width) div 2, 8)
      textY = f.y.toInt + max((f.height.toInt - textSize.height) div 2, 8)
    discard drawText(Font(font), textX, textY, message, ctx.palette.textColor,
        color(0, 0, 0, 0))
    ctx.requestRedrawAfter(250)
    return
  let
    fitScale = min(f.width / size.w.float64, f.height / size.h.float64)
    zoom =
      if self.state.isNil:
        1.0
      else:
        self.state.zoom.clamp(0.05, 64.0)
    drawScale = fitScale * zoom
    width = size.w.float64 * drawScale
    height = size.h.float64 * drawScale
    offsetX =
      if self.state.isNil: 0.0 else: self.state.offsetX
    offsetY =
      if self.state.isNil: 0.0 else: self.state.offsetY
    x = f.x + (f.width - width) / 2.0 + offsetX
    y = f.y + (f.height - height) / 2.0 + offsetY
    previousHasClip = ctx.hasClip
    previousClip = ctx.clipRect
    clip = ctx.clippedRect(bounds)
  ctx.hasClip = true
  ctx.clipRect = clip
  saveState()
  setClipRect(clip)
  drawImage(self.path, rect(0, 0, size.w, size.h),
      rect(x.toInt, y.toInt, width.toInt, height.toInt))
  restoreState()
  ctx.hasClip = previousHasClip
  ctx.clipRect = previousClip

method draw*(self: ImageButton, widget: Widget, ctx: var DrawContext) =
  ## Draw the button's background when it has one, then the image, tinted for
  ## its hot and active state.
  let f = widget.frame
  let bounds = rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt)
  if self.style.hasBackground:
    self.drawShadow(bounds)
    self.styledFillRect(
      bounds,
      self.styledBackground(ctx.palette.background),
    )
  elif ctx.hot(widget.id):
    self.drawShadow(bounds)
    self.styledFillRect(
      bounds,
      ctx.palette.backgroundHot,
    )
  drawImagePath(self.path, widget, ctx, self.source, self.hasSource)
