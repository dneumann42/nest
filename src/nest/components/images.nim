import ../[resources, widgets2]
import component
import nest/[coords, screen]

type
  ImageView* = ref object of Component
    path: string

  ImageButton* = ref object of Interactive
    path: string

proc new*(T: typedesc[ImageView], path = ""): T =
  T(path: path)

proc new*(T: typedesc[ImageButton], path = ""): T =
  T(path: path)

method measure*(self: ImageView, resources: Resources): IntrinsicSize =
  let size = resources.measureImage(self.path)
  intrinsicSize(size.w.toFloat, size.h.toFloat)

method measure*(self: ImageButton, resources: Resources): IntrinsicSize =
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

proc drawImagePath(path: string, widget: Widget, ctx: var DrawContext) =
  let
    image = ctx.resources.loadImage(path)
    size = ctx.resources.measureImage(path)
    f = widget.frame
  if image.int == 0 or size.w <= 0 or size.h <= 0 or f.width <= 0 or f.height <= 0:
    fillRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), ctx.palette.panelMuted)
    return
  let
    scale = min(f.width / size.w.toFloat, f.height / size.h.toFloat)
    width = size.w.toFloat * scale
    height = size.h.toFloat * scale
    x = f.x + (f.width - width) / 2.0
    y = f.y + (f.height - height) / 2.0
  drawImage(
    image,
    rect(0, 0, size.w, size.h),
    rect(x.toInt, y.toInt, width.toInt, height.toInt),
  )

method draw*(self: ImageView, widget: Widget, ctx: var DrawContext) =
  drawImagePath(self.path, widget, ctx)

method draw*(self: ImageButton, widget: Widget, ctx: var DrawContext) =
  if ctx.hot(widget.id):
    let f = widget.frame
    fillRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), ctx.palette.backgroundHot)
  drawImagePath(self.path, widget, ctx)
