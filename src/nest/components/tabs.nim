import ../[palette, resources, widgets2]
import component
import nest/[coords, screen]

const
  TabPaddingX = 14
  TabPaddingY = 5
  TabMinHeight = 26
  TabInsetTop = 2
  TabAccentHeight = 3

type
  TabStyle* = object
    selectedBackground*: Color
    background*: Color
    hotBackground*: Color
    border*: Color
    selectedBorder*: Color
    text*: Color

  TabButton* = ref object of Interactive
    label: string
    selected: bool
    tabStyle: TabStyle

proc defaultTabStyle*(palette: Palette): TabStyle =
  TabStyle(
    selectedBackground: palette.backgroundActive,
    background: palette.background,
    hotBackground: palette.backgroundHot,
    border: palette.buttonBorder,
    selectedBorder: palette.buttonBorderActive,
    text: palette.textColor,
  )

proc new*(
    T: typedesc[TabButton], label: string, selected: bool, tabStyle: TabStyle
): T =
  T(label: label, selected: selected, tabStyle: tabStyle)

method measure*(self: TabButton, resources: Resources): IntrinsicSize =
  let measurement = resources.measureText("font", self.label)
  intrinsicSize(
    (measurement.width + TabPaddingX * 2).toFloat,
    max(measurement.height + TabPaddingY * 2, TabMinHeight).toFloat,
  )

method update*(self: TabButton, widget: Widget, ctx: var UpdateContext) =
  let isHot =
    ctx.mouseX > widget.frame.x.toInt and
    ctx.mouseX < (widget.frame.x + widget.frame.width).toInt and
    ctx.mouseY > widget.frame.y.toInt and
    ctx.mouseY < (widget.frame.y + widget.frame.height).toInt
  let isActive = isHot and ctx.mouseLeftPressed
  if isHot:
    ctx.setHot(widget.id)
  if isActive:
    ctx.setActive(widget.id)

proc drawTabFrame(f: Frame, border, highlight, shadow: Color, selected: bool) =
  let
    x = f.x.toInt + 1
    y = f.y.toInt
    w = max(f.width.toInt - 2, 0)
    h = f.height.toInt
    top = if selected: y + 1 else: y + TabInsetTop + 1
    bottom = y + h - 2
    right = x + w - 1
  if w <= 0 or h <= 0:
    return
  drawLine(x, top, right, top, highlight)
  drawLine(x, top, x, bottom, border)
  drawLine(right, top, right, bottom, shadow)
  if not selected:
    drawLine(x, bottom, x + w - 1, bottom, shadow)

method draw*(self: TabButton, widget: Widget, ctx: var DrawContext) =
  let
    f = widget.frame
    hot = ctx.hot(widget.id)
    active = ctx.active(widget.id)
    tabStyle =
      if self.tabStyle.text.a == 0 and self.tabStyle.border.a == 0:
        defaultTabStyle(ctx.palette)
      else:
        self.tabStyle
    background =
      if self.selected:
        ctx.palette.cardBackground
      elif active or hot:
        ctx.palette.cardBackgroundHot
      else:
        ctx.palette.panelMuted
    frameY = if self.selected: f.y + 1 else: f.y + TabInsetTop.toFloat + 1
    frameHeight =
      if self.selected:
        max(f.height - 2, 1)
      else:
        max(f.height - TabInsetTop.toFloat - 2, 1.0)

  fillRect(
    rect(f.x.toInt + 1, frameY.toInt, max(f.width.toInt - 2, 0), frameHeight.toInt),
    background,
  )
  drawTabFrame(
    Frame(x: f.x, y: f.y, width: f.width, height: f.height),
    if self.selected: tabStyle.selectedBorder else: tabStyle.border,
    ctx.palette.buttonHighlight,
    ctx.palette.panelBorder,
    self.selected,
  )
  if self.selected:
    fillRect(
      rect(
        f.x.toInt + 2,
        f.y.toInt + 1,
        max(f.width.toInt - 4, 0),
        TabAccentHeight,
      ),
      ctx.palette.cardAccent,
    )
    fillRect(
      rect(f.x.toInt + 2, (f.y + f.height - 2).toInt, max(f.width.toInt - 4, 0), 1),
      background,
    )

  let
    (font, _) = ctx.resources.get("font")
    textExtent = ctx.resources.measureText("font", self.label)
    textX = f.x.toInt + max((f.width.toInt - textExtent.width) div 2, TabPaddingX)
    textY =
      (if self.selected: f.y.toInt else: f.y.toInt + TabInsetTop) +
      max((frameHeight.toInt - textExtent.height) div 2, TabPaddingY)
  discard
    drawText(Font(font), textX, textY, self.label, tabStyle.text, color(0, 0, 0, 0))
