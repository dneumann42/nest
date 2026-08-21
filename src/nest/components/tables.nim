import ../widgets2
import component
import containers
import nest/[coords, screen]

type
  TableView* = ref object of Container

  TableHeaderView* = ref object of Container

  TableRowView* = ref object of Container

  TableCellView* = ref object of Container

proc new*(T: typedesc[TableView]): T =
  ## Create the surface a table's rows are drawn on.
  T()

proc new*(T: typedesc[TableHeaderView]): T =
  ## Create a table header strip.
  T()

proc new*(T: typedesc[TableRowView]): T =
  ## Create a table row.
  T()

proc new*(T: typedesc[TableCellView]): T =
  ## Create a table cell.
  T()

method draw*(self: TableView, widget: Widget, ctx: var DrawContext) =
  ## Fill the table's frame with its own background colour, or the palette's
  ## card background, and draw its border.
  let f = widget.frame
  fillRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt),
      self.styledBackground(ctx.palette.cardBackground))
  lineRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt),
      ctx.palette.panelBorder)

method draw*(self: TableHeaderView, widget: Widget, ctx: var DrawContext) =
  ## Fill the header's frame with its own background colour, or the palette's
  ## header background, and draw the line under it.
  let f = widget.frame
  fillRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt),
      self.styledBackground(ctx.palette.dialogHeaderBackground))
  fillRect(rect(f.x.toInt, (f.y + f.height - 1).toInt, f.width.toInt, 1),
      ctx.palette.dialogHeaderBorder)

method draw*(self: TableRowView, widget: Widget, ctx: var DrawContext) =
  ## Draw the row's bottom separator line.
  let f = widget.frame
  fillRect(rect(f.x.toInt, (f.y + f.height - 1).toInt, f.width.toInt, 1),
      ctx.palette.panelBorder)

method draw*(self: TableCellView, widget: Widget, ctx: var DrawContext) =
  ## Draw the cell's trailing separator line.
  let f = widget.frame
  fillRect(rect((f.x + f.width - 1).toInt, f.y.toInt, 1, f.height.toInt),
      ctx.palette.panelBorder)
