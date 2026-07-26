import ../[resources, widgets2]
import component
import nest/[coords, screen]

const
  CheckboxBoxSize = 14
  CheckboxGap = 8
  CheckboxMinHeight = 24

type Checkbox* = ref object of Component
  label: string
  checked: bool
  fontName: string

proc new*(
    T: typedesc[Checkbox],
    label = "",
    checked = false,
    fontName = "font",
): T =
  T(label: label, checked: checked, fontName: fontName)

method measure*(self: Checkbox, resources: Resources): IntrinsicSize =
  let measurement = resources.measureText(self.fontName, self.label)
  intrinsicSize(
    (CheckboxBoxSize + CheckboxGap + measurement.width).toFloat,
    max(measurement.height, CheckboxMinHeight).toFloat,
  )

method draw*(self: Checkbox, widget: Widget, ctx: var DrawContext) =
  let
    f = widget.frame
    (font, _) = ctx.resources.get(self.fontName)
    textExtent = ctx.resources.measureText(self.fontName, self.label)
    boxX = f.x.toInt
    boxY = (f.y + (f.height - CheckboxBoxSize.toFloat) / 2.0).toInt
    textX = boxX + CheckboxBoxSize + CheckboxGap
    textY = (f.y + max((f.height.toInt - textExtent.height) div 2, 0).toFloat).toInt

  fillRect(
    rect(boxX, boxY, CheckboxBoxSize, CheckboxBoxSize),
    if self.checked: ctx.palette.cardAccent else: ctx.palette.background,
  )
  lineRect(
    rect(boxX, boxY, CheckboxBoxSize, CheckboxBoxSize),
    if self.checked: ctx.palette.buttonBorderActive else: ctx.palette.buttonBorder,
  )
  if self.checked:
    drawLine(boxX + 3, boxY + 7, boxX + 6, boxY + 10, ctx.palette.textColor)
    drawLine(boxX + 6, boxY + 10, boxX + 11, boxY + 4, ctx.palette.textColor)

  discard drawText(
    Font(font),
    textX,
    textY,
    self.label,
    ctx.palette.textColor,
    color(0, 0, 0, 0),
  )
