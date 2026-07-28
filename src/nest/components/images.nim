import ../[resources, widgets2]
import component
import nest/[coords, screen]

type
  ImageView* = ref object of Component
    path: string
    source: Rect
    hasSource: bool

  ImageButton* = ref object of Interactive
    path: string
    source: Rect
    hasSource: bool

proc new*(T: typedesc[ImageView], path = ""): T =
  T(path: path)

proc new*(T: typedesc[ImageView], path: string, source: Rect): T =
  T(path: path, source: source, hasSource: true)

proc new*(T: typedesc[ImageButton], path = ""): T =
  T(path: path)

proc new*(T: typedesc[ImageButton], path: string, source: Rect): T =
  T(path: path, source: source, hasSource: true)

method measure*(self: ImageView, resources: Resources): IntrinsicSize =
  if self.hasSource:
    intrinsicSize(self.source.w.toFloat, self.source.h.toFloat)
  else:
    let size = resources.measureImage(self.path)
    intrinsicSize(size.w.toFloat, size.h.toFloat)

method measure*(self: ImageButton, resources: Resources): IntrinsicSize =
  if self.hasSource:
    intrinsicSize(self.source.w.toFloat, self.source.h.toFloat)
  else:
    let size = resources.measureImage(self.path)
    intrinsicSize(size.w.toFloat, size.h.toFloat)

proc isInside(widget: Widget, ctx: UpdateContext): bool =
  let f = widget.frame
  ctx.mouseX.toFloat >= f.x and ctx.mouseX.toFloat < f.x + f.width and
    ctx.mouseY.toFloat >= f.y and ctx.mouseY.toFloat < f.y + f.height

method update*(self: ImageButton, widget: Widget, ctx: var UpdateContext) =
  let hot = widget.isInside(ctx)
  if hot:
    ctx.setHot(widget.id)
    if ctx.mouseLeftPressed:
      ctx.setActive(widget.id)

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
  drawImagePath(self.path, widget, ctx, self.source, self.hasSource)

method draw*(self: ImageButton, widget: Widget, ctx: var DrawContext) =
  let f = widget.frame
  if self.style.hasBackground:
    fillRect(
      rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt),
      self.styledBackground(ctx.palette.background),
    )
  elif ctx.hot(widget.id):
    fillRect(
      rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt),
      ctx.palette.backgroundHot,
    )
  drawImagePath(self.path, widget, ctx, self.source, self.hasSource)
