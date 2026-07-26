import ../[palette, resources, widgets2]
import component
import nest/[coords, screen]

const
  TabPaddingX = 10
  TabPaddingY = 4
  TabMinHeight = 28

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

proc new*(T: typedesc[TabButton], label: string, selected: bool,
    tabStyle: TabStyle): T =
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

proc drawBorder(f: Frame, c: Color) =
  lineRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), c)

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
        tabStyle.selectedBackground
      elif active or hot:
        tabStyle.hotBackground
      else:
        tabStyle.background

  fillRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), background)
  drawBorder(f, if self.selected: tabStyle.selectedBorder else: tabStyle.border)

  let
    (font, _) = ctx.resources.get("font")
    textExtent = ctx.resources.measureText("font", self.label)
    textX = f.x.toInt + max((f.width.toInt - textExtent.width) div 2, TabPaddingX)
    textY = f.y.toInt + max((f.height.toInt - textExtent.height) div 2, TabPaddingY)
  discard drawText(
    Font(font), textX, textY, self.label, tabStyle.text, color(0, 0, 0, 0)
  )
