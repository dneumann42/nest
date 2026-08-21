import ../[resources, widgets2]
import component
import nest/[coords, screen]

const
  CheckboxBoxSize = 14
  CheckboxGap = 8
  CheckboxMinHeight = 24

type Checkbox* = ref object of Interactive
  label: string
  checked: bool
  fontName: string

proc new*(
    T: typedesc[Checkbox],
    label = "",
    checked = false,
    fontName = "font",
): T =
  ## Create a checkbox component labelled `label`, initially `checked`.
  T(label: label, checked: checked, fontName: fontName)

method measure*(self: Checkbox, resources: Resources): IntrinsicSize =
  ## Return the size of the box, its gap and the label together.
  let measurement = resources.measureText(self.fontName, self.label)
  intrinsicSize(
    (CheckboxBoxSize + CheckboxGap + measurement.width).toFloat,
    max(measurement.height, CheckboxMinHeight).toFloat,
  )

method update*(self: Checkbox, widget: Widget, ctx: var UpdateContext) =
  ## Mark the checkbox hot while the pointer is over it and active while the
  ## left button is held on it.
  let
    f = widget.frame
    isHot =
      ctx.mouseX.float64 >= f.x and ctx.mouseX.float64 < f.x + f.width and
      ctx.mouseY.float64 >= f.y and ctx.mouseY.float64 < f.y + f.height
  if isHot:
    ctx.setHot(widget.id)
    if ctx.mouseLeftPressed:
      ctx.setActive(widget.id)

method draw*(self: Checkbox, widget: Widget, ctx: var DrawContext) =
  ## Draw the box, its check mark when checked, and the label.
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
