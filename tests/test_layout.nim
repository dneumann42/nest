import std/[math, unittest]

import nest

const Epsilon = 0.001

proc closeTo(a, b: float64): bool =
  abs(a - b) <= Epsilon

proc checkFrame(box: LayoutBox, x, y, width, height: float64) =
  let f = box.frame
  check f.x.closeTo(x)
  check f.y.closeTo(y)
  check f.width.closeTo(width)
  check f.height.closeTo(height)

suite "constraint layout":
  test "row distributes fixed, preferred, and fill widths":
    let ui = newLayout()
    let window = ui.box("window")
    let sidebar = ui.box("sidebar", width = prefer(240, min = 180, max = 320))
    let content = ui.box("content", width = fill(min = 300))
    let inspector = ui.box("inspector", width = prefer(280, min = 200, max = 400))

    ui.root window
    ui.row(window, [sidebar, content, inspector], gap = 12, padding = 16)
    ui.resize(1280, 720)
    ui.solve()

    checkFrame sidebar, 16, 16, 240, 688
    checkFrame content, 268, 16, 704, 688
    checkFrame inspector, 984, 16, 280, 688

  test "column composes application regions":
    let ui = newLayout()
    let window = ui.box("window")
    let toolbar = ui.box("toolbar", height = fixed(48))
    let body = ui.box("body")
    let status = ui.box("status", height = fixed(24))

    ui.root window
    ui.column(window, [toolbar, body, status], gap = 8, padding = 12)
    ui.resize(800, 600)
    ui.solve()

    checkFrame toolbar, 12, 12, 776, 48
    checkFrame body, 12, 68, 776, 488
    checkFrame status, 12, 564, 776, 24

  test "column does not force fixed child to fill parent height":
    let ui = newLayout()
    let window = ui.box("window")
    let button = ui.box("button", width = fixed(100), height = fixed(24))

    ui.root window
    ui.column(window, [button])
    ui.resize(800, 600)
    ui.solve()

    checkFrame window, 0, 0, 800, 600
    checkFrame button, 0, 0, 100, 24

  test "row does not force fixed child to fill parent width":
    let ui = newLayout()
    let window = ui.box("window")
    let button = ui.box("button", width = fixed(100), height = fixed(24))

    ui.root window
    ui.row(window, [button])
    ui.resize(800, 600)
    ui.solve()

    checkFrame window, 0, 0, 800, 600
    checkFrame button, 0, 0, 100, 24

  test "row allows fixed children to overflow narrow parents":
    let ui = newLayout()
    let window = ui.box("window")
    let first = ui.box("first", width = fixed(120), height = fixed(20))
    let second = ui.box("second", width = fixed(90), height = fixed(20))

    ui.root window
    ui.row(window, [first, second], gap = 12, padding = 8)
    ui.resize(160, 80)
    ui.solve()

    checkFrame first, 8, 8, 120, 20
    checkFrame second, 140, 8, 90, 20

  test "column allows fixed children to overflow short parents":
    let ui = newLayout()
    let window = ui.box("window")
    let first = ui.box("first", width = fixed(80), height = fixed(70))
    let second = ui.box("second", width = fixed(80), height = fixed(60))

    ui.root window
    ui.column(window, [first, second], gap = 10, padding = 8)
    ui.resize(160, 100)
    ui.solve()

    checkFrame first, 8, 8, 80, 70
    checkFrame second, 8, 88, 80, 60

  test "row align items positions children on the cross axis":
    let ui = newLayout()
    let window = ui.box("window")
    let top = ui.box("top", width = fixed(50), height = fixed(20))
    let middle = ui.box("middle", width = fixed(50), height = fixed(30))
    let bottom = ui.box("bottom", width = fixed(50), height = fixed(40))

    ui.root window
    ui.row(
      window,
      [top.withAlignSelf(AlignStart), middle, bottom.withAlignSelf(AlignEnd)],
      gap = 10,
      padding = 10,
      alignItems = AlignCenter,
    )
    ui.resize(300, 100)
    ui.solve()

    checkFrame top, 10, 10, 50, 20
    checkFrame middle, 70, 35, 50, 30
    checkFrame bottom, 130, 50, 50, 40

  test "column align items positions children on the cross axis":
    let ui = newLayout()
    let window = ui.box("window")
    let left = ui.box("left", width = fixed(50), height = fixed(20))
    let center = ui.box("center", width = fixed(70), height = fixed(20))
    let right = ui.box("right", width = fixed(80), height = fixed(20))

    ui.root window
    ui.column(
      window,
      [left.withAlignSelf(AlignStart), center, right.withAlignSelf(AlignEnd)],
      gap = 10,
      padding = 10,
      alignItems = AlignCenter,
    )
    ui.resize(200, 120)
    ui.solve()

    checkFrame left, 10, 10, 50, 20
    checkFrame center, 65, 40, 70, 20
    checkFrame right, 110, 70, 80, 20

  test "pin constrains all edges with an inset":
    let ui = newLayout()
    let window = ui.box("window")
    let content = ui.box("content")

    ui.root window
    ui.pin(content, window, inset = 20)
    ui.resize(500, 300)
    ui.solve()

    checkFrame content, 20, 20, 460, 260

  test "alignment helpers and relative placement build a card":
    let ui = newLayout()
    let window = ui.box("window")
    let card = ui.box("card", width = fixed(300), height = fixed(120))
    let icon = ui.box("icon", width = fixed(32), height = fixed(32))
    let title = ui.box("title", width = hug(120), height = fixed(24))
    let description = ui.box("description", width = fixed(220), height = fixed(40))

    ui.root window
    ui.alignCenterX(card, window)
    ui.alignCenterY(card, window)
    ui.alignLeft(icon, card, 16)
    ui.alignTop(icon, card, 16)
    ui.after(title, icon, gap = 12)
    ui.alignCenterY(title, icon)
    ui.below(description, title, gap = 8)
    ui.alignLeft(description, title)
    ui.resize(500, 300)
    ui.solve()

    checkFrame card, 100, 90, 300, 120
    checkFrame icon, 116, 106, 32, 32
    checkFrame title, 160, 110, 120, 24
    checkFrame description, 160, 142, 220, 40

  test "right and bottom alignment offsets are solved":
    let ui = newLayout()
    let window = ui.box("window")
    let panel = ui.box("panel", width = fixed(100), height = fixed(80))

    ui.root window
    ui.alignRight(panel, window, -20)
    ui.alignBottom(panel, window, -30)
    ui.resize(400, 300)
    ui.solve()

    checkFrame panel, 280, 190, 100, 80

  test "equal widths and proportional raw constraints share space":
    let ui = newLayout()
    let window = ui.box("window")
    let left = ui.box("left")
    let center = ui.box("center")
    let right = ui.box("right")

    ui.root window
    ui.row(window, [left, center, right], gap = 10)
    discard ui.constrain(center.width == left.width * 2.0)
    discard ui.constrain(right.width == left.width)
    ui.resize(420, 100)
    ui.solve()

    checkFrame left, 0, 0, 100, 100
    checkFrame center, 110, 0, 200, 100
    checkFrame right, 320, 0, 100, 100

  test "equal size helpers constrain repeated cells":
    let ui = newLayout()
    let window = ui.box("window")
    let a = ui.box("a")
    let b = ui.box("b")
    let c = ui.box("c")

    ui.root window
    ui.row(window, [a, b, c], gap = 5)
    ui.equalWidth(a, b, c)
    ui.equalHeight(a, b, c)
    ui.resize(320, 90)
    ui.solve()

    checkFrame a, 0, 0, 103.333333, 90
    checkFrame b, 108.333333, 0, 103.333333, 90
    checkFrame c, 216.666667, 0, 103.333333, 90

  test "fill and hug max policies cap flexible boxes":
    let ui = newLayout()
    let window = ui.box("window")
    let left = ui.box("left", width = fill(max = 120))
    let right = ui.box("right", width = hug(140, max = 160))

    ui.root window
    ui.row(window, [left, right])
    ui.resize(280, 50)
    ui.solve()

    checkFrame left, 0, 0, 120, 50
    checkFrame right, 120, 0, 160, 50

  test "fit containers derive size from known children":
    let ui = newLayout()
    let window = ui.box("window")
    let columnPanel = ui.box("columnPanel", width = fit(), height = fit())
    let wide = ui.box("wide", width = fixed(120), height = fixed(20))
    let narrow = ui.box("narrow", width = fixed(80), height = fixed(30))
    let rowPanel = ui.box("rowPanel", width = fit(), height = fit())
    let short = ui.box("short", width = fixed(40), height = fixed(18))
    let tall = ui.box("tall", width = fixed(60), height = fixed(34))

    ui.root window
    discard ui.constrain(columnPanel.left == window.left)
    discard ui.constrain(columnPanel.top == window.top)
    ui.column(columnPanel, [wide, narrow], gap = 5, padding = 10)
    discard ui.constrain(rowPanel.left == window.left)
    discard ui.constrain(rowPanel.top == columnPanel.bottom + 20)
    ui.row(rowPanel, [short, tall], gap = 7, padding = 4)
    ui.resize(500, 300)
    ui.solve()

    checkFrame columnPanel, 0, 0, 140, 75
    checkFrame rowPanel, 0, 95, 115, 42

  test "constraint groups can switch responsive layouts":
    let ui = newLayout()
    let window = ui.box("window")
    let sidebar = ui.box("sidebar", width = fixed(180), height = fixed(120))
    let content = ui.box("content", width = fixed(320), height = fixed(120))

    ui.root window

    let desktop = ui.collect:
      keep ui.constrain(sidebar.left == window.left)
      keep ui.constrain(sidebar.top == window.top)
      keep ui.constrain(content.left == sidebar.right + 12)
      keep ui.constrain(content.top == sidebar.top)

    ui.resize(700, 300)
    ui.solve()
    checkFrame sidebar, 0, 0, 180, 120
    checkFrame content, 192, 0, 320, 120

    ui.remove desktop
    let mobile = ui.collect:
      keep ui.constrain(sidebar.left == window.left)
      keep ui.constrain(sidebar.top == window.top)
      keep ui.constrain(content.left == window.left)
      keep ui.constrain(content.top == sidebar.bottom + 12)

    ui.resize(360, 600)
    ui.solve()
    check mobile.constraints.len == 4
    checkFrame sidebar, 0, 0, 180, 120
    checkFrame content, 0, 132, 320, 120

  test "resize requires a root":
    let ui = newLayout()
    expect ValueError:
      ui.resize(100, 100)

  test "empty helpers are no-ops":
    let ui = newLayout()
    let window = ui.box("window")

    ui.root window
    ui.row(window, [])
    ui.column(window, [])
    ui.equalWidth()
    ui.equalHeight()
    ui.resize(10, 20)
    ui.solve()

    checkFrame window, 0, 0, 10, 20

  test "frame string is useful in diagnostics":
    let frame = Frame(x: 1, y: 2, width: 3, height: 4)
    check $frame == "Frame(x: 1.0, y: 2.0, width: 3.0, height: 4.0)"
