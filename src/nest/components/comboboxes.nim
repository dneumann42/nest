import ../[resources, widgets2]
import component
import nest/[coords, screen]

const
  ComboPaddingX = 8
  ComboPaddingY = 4
  ComboArrowWidth = 18
  ComboMinHeight = 28

type
  ComboBox* = ref object of Interactive
    label: string
    options: seq[string]
    selected: int
    open: bool
    optionHeight: int

proc new*(
    T: typedesc[ComboBox],
    label = "",
    options: openArray[string] = [],
    selected = 0,
    open = false,
    optionHeight = ComboMinHeight,
): T =
  T(label: label, options: @options, selected: selected, open: open, optionHeight: optionHeight)

proc contains(frame: Frame, x, y: int): bool =
  x.float64 >= frame.x and x.float64 < frame.x + frame.width and
    y.float64 >= frame.y and y.float64 < frame.y + frame.height

proc drawBorder(f: Frame, c: Color) =
  let
    x = f.x.toInt
    y = f.y.toInt
    w = f.width.toInt
    h = f.height.toInt
  if w <= 0 or h <= 0:
    return
  drawLine(x, y, x + w - 1, y, c)
  drawLine(x, y + h - 1, x + w - 1, y + h - 1, c)
  drawLine(x, y, x, y + h - 1, c)
  drawLine(x + w - 1, y, x + w - 1, y + h - 1, c)

proc popupFrame(field: Frame, optionCount, optionHeight, windowHeight: int): Frame =
  let
    popupHeight = max(optionCount, 1) * optionHeight
    belowY = field.y + field.height
    aboveY = field.y - popupHeight.float64
    y =
      if belowY + popupHeight.float64 <= windowHeight.float64 or aboveY < 0.0:
        belowY
      else:
        aboveY
  Frame(x: field.x, y: y, width: field.width, height: popupHeight.float64)

method measure*(self: ComboBox, resources: Resources): IntrinsicSize =
  let measurement = resources.measureText("font", self.label)
  intrinsicSize(
    (measurement.width + ComboPaddingX * 2 + ComboArrowWidth).toFloat,
    max(measurement.height + ComboPaddingY * 2, ComboMinHeight).toFloat,
  )

method update*(self: ComboBox, widget: Widget, ctx: var UpdateContext) =
  let
    fieldHot = widget.frame.contains(ctx.mouseX, ctx.mouseY)
    popover = popupFrame(widget.frame, self.options.len, self.optionHeight, ctx.windowHeight)
    popupHot = self.open and popover.contains(ctx.mouseX, ctx.mouseY)
  if fieldHot or popupHot:
    ctx.setHot(widget.id)
  if ctx.mouseLeftPressed:
    if fieldHot:
      ctx.setActive(widget.id)
      if ctx.focused(widget.id):
        ctx.clearFocus()
      else:
        ctx.setFocus(widget.id)
    elif self.open and not popupHot:
      ctx.clearFocus()

proc drawTextClipped(ctx: DrawContext, f: Frame, text: string, selected = false) =
  let
    (font, _) = ctx.resources.get("font")
    textExtent = ctx.resources.measureText("font", text)
    textX = f.x.toInt + ComboPaddingX
    textY = f.y.toInt + max((f.height.toInt - textExtent.height) div 2, ComboPaddingY)
    textWidth = max(f.width.toInt - ComboPaddingX * 2, 0)
    fg = ctx.palette.textColor
  saveState()
  setClipRect(ctx.clippedRect(rect(textX, f.y.toInt, textWidth, f.height.toInt)))
  discard drawText(Font(font), textX, textY, text, fg, color(0, 0, 0, 0))
  restoreState()
  if selected:
    fillRect(rect(f.x.toInt + 3, f.y.toInt + 3, 3, max(f.height.toInt - 6, 1)), ctx.palette.cardAccent)

method draw*(self: ComboBox, widget: Widget, ctx: DrawContext) =
  let
    f = widget.frame
    hot = ctx.hot(widget.id)
    active = ctx.active(widget.id)
    focused = ctx.focused(widget.id)
    bg =
      if active or focused:
        ctx.palette.backgroundActive
      elif hot:
        ctx.palette.backgroundHot
      else:
        ctx.palette.background
    border =
      if active or focused:
        ctx.palette.buttonBorderActive
      elif hot:
        ctx.palette.buttonBorderHot
      else:
        ctx.palette.buttonBorder
  fillRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), bg)
  drawLine(f.x.toInt + 1, f.y.toInt + 1, (f.x + f.width - 2).toInt, f.y.toInt + 1, ctx.palette.buttonHighlight)
  drawBorder(f, border)
  drawTextClipped(ctx, Frame(x: f.x, y: f.y, width: max(f.width - ComboArrowWidth.float64, 0.0), height: f.height), self.label)

  let
    arrowX = (f.x + f.width).toInt - ComboArrowWidth
    arrowY = f.y.toInt + f.height.toInt div 2
  if self.open:
    drawLine(arrowX + 4, arrowY - 2, arrowX + ComboArrowWidth div 2, arrowY + 3, ctx.palette.textColor)
    drawLine(arrowX + ComboArrowWidth - 4, arrowY - 2, arrowX + ComboArrowWidth div 2, arrowY + 3, ctx.palette.textColor)
  else:
    drawLine(arrowX + 4, arrowY + 2, arrowX + ComboArrowWidth div 2, arrowY - 3, ctx.palette.textColor)
    drawLine(arrowX + ComboArrowWidth - 4, arrowY + 2, arrowX + ComboArrowWidth div 2, arrowY - 3, ctx.palette.textColor)


method drawOverlay*(self: ComboBox, widget: Widget, ctx: DrawContext) =
  if not self.open:
    return
  let
    f = widget.frame
    popover = popupFrame(f, self.options.len, self.optionHeight, ctx.windowHeight)
  fillRect(rect(popover.x.toInt, popover.y.toInt, popover.width.toInt, popover.height.toInt), ctx.palette.panelBackground)
  drawBorder(popover, ctx.palette.buttonBorderActive)
  for index, option in self.options:
    let optionFrame = Frame(
      x: popover.x,
      y: popover.y + index.float64 * self.optionHeight.float64,
      width: popover.width,
      height: self.optionHeight.float64,
    )
    if index == self.selected:
      fillRect(rect(optionFrame.x.toInt, optionFrame.y.toInt, optionFrame.width.toInt, optionFrame.height.toInt), ctx.palette.backgroundActive)
    elif optionFrame.contains(ctx.mouseX, ctx.mouseY):
      fillRect(rect(optionFrame.x.toInt, optionFrame.y.toInt, optionFrame.width.toInt, optionFrame.height.toInt), ctx.palette.backgroundHot)
    drawTextClipped(ctx, optionFrame, option, index == self.selected)
