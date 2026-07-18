import std/[hashes, sugar]
import layout
import uirelays/[coords, screen]

type
  WidgetID* = distinct string
  Direction* = enum
    Row
    Column

  Theme* = object
    foreground*, background*, alternative*: Color
    text*, border*: Color
    borderPixels*: int

proc hash*(id: WidgetID): Hash {.borrow.}
proc `==`*(a, b: WidgetID): bool {.borrow.}
proc `$`*(a: WidgetID): string =
  string(a)

proc fgColor*(theme: Theme, color: Color): Theme =
  result = dup theme:
    foreground = color

proc bgColor*(theme: Theme, color: Color): Theme =
  result = dup theme:
    background = color

proc altColor*(theme: Theme, color: Color): Theme =
  result = dup theme:
    alternative = color

proc textColor*(theme: Theme, color: Color): Theme =
  result = dup theme:
    text = color

proc borderColor*(theme: Theme, color: Color): Theme =
  result = dup theme:
    border = color

proc borderThickness*(theme: Theme, thickness: int): Theme =
  result = dup theme:
    borderPixels = thickness

proc default*(T: typedesc[Theme]): Theme =
  T(
    foreground: color(120, 120, 120),
    background: color(245, 250, 240),
    alternative: color(160, 120, 130),
    text: color(10, 10, 0),
    border: color(10, 10, 0),
  )

proc wid*(s: string): WidgetID =
  WidgetID(s)

type
  DrawWidgetProc* = proc(box: LayoutBox, theme: Theme, id: WidgetID) {.closure.}
  DrawCommand* = object
    box*: LayoutBox
    id*: WidgetID
    theme*: Theme
    draw*: DrawWidgetProc

proc drawPanelBox(box: LayoutBox, theme: Theme) =
  let
    f = box.frame
    x = f.x.toInt
    y = f.y.toInt
    w = f.width.toInt
    h = f.height.toInt
    th = theme.borderPixels
  fillRect(rect(x, y, w, h), theme.foreground)
  if theme.borderPixels > 0:
    fillRect(rect(x, y, th, h), theme.border)
    fillRect(rect(x + w - th, y, th, h), theme.border)
    fillRect(rect(x + th, y, w - th * 2, th), theme.border)
    fillRect(rect(x + th, y + h - th, w - th * 2, th), theme.border)

proc drawPanelCommand(box: LayoutBox, theme: Theme, id: WidgetID) =
  drawPanelBox(box, theme)

var parentWidth = 800.0
var parentHeight = 600.0

template layout*(widgetIdExpr: untyped, body: untyped) =
  let ui {.inject.} = newLayout()
  let rootId: WidgetID = widgetIdExpr
  let parentId {.inject.} = rootId
  var rooted {.inject.} = false
  var drawCommands {.inject.}: seq[DrawCommand] = @[]
  var theme {.inject.} = Theme.default()

  proc draw(box: LayoutBox, theme: Theme, id: WidgetID, cmd: DrawWidgetProc) =
    drawCommands.add(DrawCommand(box: box, theme: theme, id: id, draw: cmd))

  body
  ui.resize(parentWidth, parentHeight)
  ui.solve()
  for command in drawCommands:
    command.draw(command.box, command.theme, command.id)

template view*(widgetIdExpr: untyped, body: untyped) =
  layout(widgetIdExpr):
    body

template stack(
    widgetIdExpr: untyped,
    direction: Direction,
    g = 8,
    p = 12,
    boxWidth = fill(),
    boxHeight = fill(),
    blk: untyped,
) =
  mixin ui
  block:
    let widgetId: WidgetID = widgetIdExpr
    let
      parent {.inject.} =
        ui.box($parentId & "." & $widgetId, width = boxWidth, height = boxHeight)
      parentId {.inject.} = widgetId
    if not rooted:
      ui.root(parent)
      rooted = true
    when defined(children):
      children.add(parent)
    var children {.inject.} = newSeq[LayoutBox]()
    blk
    if direction == Column:
      ui.column(parent, children, gap = g, padding = p)
    else:
      ui.row(parent, children, gap = g, padding = p)

template column*(
    widgetIdExpr: untyped, g = 8, p = 12, width = fill(), height = fill(), blk: untyped
) =
  stack widgetIdExpr, Column, g, p, width, height:
    blk

template row*(
    widgetIdExpr: untyped, g = 8, p = 12, width = fill(), height = fill(), blk: untyped
) =
  stack widgetIdExpr, Row, g, p, width, height:
    blk

template panelBox(
    widgetIdExpr: untyped,
    direction: Direction,
    height: SizePolicy,
    width: SizePolicy,
    blk: untyped,
) =
  if direction == Column:
    var theme {.inject.} = Theme.default()
    stack widgetIdExpr, Column, 8, 12, width, height:
      draw(parent, theme, widgetIdExpr, drawPanelCommand)
      blk
  else:
    var theme {.inject.} = Theme.default()
    stack widgetIdExpr, Row, 8, 12, width, height:
      draw(parent, theme, widgetIdExpr, drawPanelCommand)
      blk

template panel*(widgetIdExpr: untyped, direction: Direction, blk: untyped) =
  panelBox widgetIdExpr, direction, fill(), fill():
    blk

template panel*(
    widgetIdExpr: untyped, direction: Direction, height: SizePolicy, blk: untyped
) =
  panelBox widgetIdExpr, direction, height, fill():
    blk

template panel*(
    widgetIdExpr: untyped,
    direction: Direction,
    height: SizePolicy,
    width: SizePolicy,
    blk: untyped,
) =
  panelBox widgetIdExpr, direction, height, width:
    blk
