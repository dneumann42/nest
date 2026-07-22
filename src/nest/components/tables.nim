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
  T()

proc new*(T: typedesc[TableHeaderView]): T =
  T()

proc new*(T: typedesc[TableRowView]): T =
  T()

proc new*(T: typedesc[TableCellView]): T =
  T()

method draw*(self: TableView, widget: Widget, ctx: var DrawContext) =
  let f = widget.frame
  fillRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt),
      self.styledBackground(ctx.palette.cardBackground))
  lineRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt),
      ctx.palette.panelBorder)

method draw*(self: TableHeaderView, widget: Widget, ctx: var DrawContext) =
  let f = widget.frame
  fillRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt),
      self.styledBackground(ctx.palette.dialogHeaderBackground))
  fillRect(rect(f.x.toInt, (f.y + f.height - 1).toInt, f.width.toInt, 1),
      ctx.palette.dialogHeaderBorder)

method draw*(self: TableRowView, widget: Widget, ctx: var DrawContext) =
  let f = widget.frame
  fillRect(rect(f.x.toInt, (f.y + f.height - 1).toInt, f.width.toInt, 1),
      ctx.palette.panelBorder)

method draw*(self: TableCellView, widget: Widget, ctx: var DrawContext) =
  let f = widget.frame
  fillRect(rect((f.x + f.width - 1).toInt, f.y.toInt, 1, f.height.toInt),
      ctx.palette.panelBorder)
