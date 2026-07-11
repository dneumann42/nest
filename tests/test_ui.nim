import std/unittest

import nest/[palette, resources, ui]

const
  Toolbar = WidgetID(101)
  Body = WidgetID(102)
  Sidebar = WidgetID(103)
  Content = WidgetID(104)
  Button1 = WidgetID(105)
  Button2 = WidgetID(106)
  Button3 = WidgetID(107)
  Button4 = WidgetID(108)
  Spacer = WidgetID(109)
  Button5 = WidgetID(110)
  Panel1 = WidgetID(111)
  CenterBox = WidgetID(112)
  Label1 = WidgetID(113)
  Label2 = WidgetID(114)

proc widget(ui: UI, id: WidgetID): Widget =
  for box in ui.layout.boxes:
    if box.id == id:
      return box
  raise newException(ValueError, "missing widget: " & $id)

proc checkFrame(box: Widget, x, y, width, height: float64) =
  let frame = box.frame
  check frame.x == x
  check frame.y == y
  check frame.width == width
  check frame.height == height

suite "ui layout nesting":
  test "block layouts add their parent to the enclosing layout":
    var ui = UI.init()
    ui.beginLayout(400, 200)

    ui.column(10.0, 10.0):
      ui.row(Toolbar, fill(), fixed(30), 5.0, 0.0):
        ui.button(Button1, "One", width = fixed(50), height = fixed(20))
        ui.button(Button2, "Two", width = fixed(60), height = fixed(20))

      ui.row(Body, fill(), fill(), 10.0, 0.0):
        ui.column(Sidebar, fixed(80), fill(), 4.0, 4.0):
          ui.button(Button3, "Three", width = fill(), height = fixed(20))
        ui.column(Content, fill(), fill(), 0.0, 0.0):
          ui.button(Button4, "Four", width = fixed(70), height = fixed(20))

    ui.endLayout()

    checkFrame(ui.widget(Toolbar), 10, 10, 380, 30)
    checkFrame(ui.widget(Button1), 10, 10, 50, 20)
    checkFrame(ui.widget(Button2), 65, 10, 60, 20)
    checkFrame(ui.widget(Body), 10, 50, 380, 28)
    checkFrame(ui.widget(Sidebar), 10, 50, 80, 28)
    checkFrame(ui.widget(Button3), 14, 54, 72, 20)
    checkFrame(ui.widget(Content), 100, 50, 290, 28)
    checkFrame(ui.widget(Button4), 100, 50, 70, 20)

  test "spacers participate in row layout":
    var ui = UI.init()
    ui.beginLayout(500, 120)

    ui.row(Body, fill(), fixed(30), 10.0, 0.0):
      ui.column(Sidebar, fixed(100), fill(), 0.0, 0.0):
        ui.button(Button1, "Left", width = fill(), height = fixed(20))
      ui.spacer(Spacer, width = fill(), height = fill())
      ui.column(Content, prefer(80), fill(), 0.0, 0.0):
        ui.button(Button2, "Right", width = fixed(80), height = fixed(20))

    ui.endLayout()

    checkFrame(ui.widget(Sidebar), 0, 0, 100, 30)
    checkFrame(ui.widget(Spacer), 110, 0, 300, 30)
    checkFrame(ui.widget(Content), 420, 0, 80, 30)

  test "aligned row helpers center children and allow align self override":
    var ui = UI.init()
    ui.beginLayout(300, 100)

    ui.rowAligned(Body, fill(), fixed(80), 10.0, 10.0, AlignCenter):
      ui.button(Button1, "One", width = fixed(40), height = fixed(20))
      ui.button(Button2, "Two", width = fixed(40), height = fixed(20), alignSelf = AlignEnd)
      ui.button(Button5, "Three", width = fixed(40), height = fixed(20), alignSelf = AlignStart)

    ui.endLayout()

    checkFrame(ui.widget(Button1), 10, 30, 40, 20)
    checkFrame(ui.widget(Button2), 60, 50, 40, 20)
    checkFrame(ui.widget(Button5), 110, 10, 40, 20)

  test "row and column layouts justify children on the main axis":
    var ui = UI.init()
    ui.beginLayout(300, 120)

    ui.column(10.0, 0.0):
      ui.rowAlignedJustified(Body, fill(), fixed(40), 10.0, 0.0, AlignCenter, JustifyCenter):
        ui.button(Button1, "One", width = fixed(40), height = fixed(20))
        ui.button(Button2, "Two", width = fixed(50), height = fixed(20))
      ui.rowAlignedJustified(Toolbar, fill(), fixed(40), 10.0, 0.0, AlignCenter, JustifyEnd):
        ui.button(Button3, "Three", width = fixed(40), height = fixed(20))
        ui.button(Button4, "Four", width = fixed(50), height = fixed(20))

    ui.endLayout()

    checkFrame(ui.widget(Button1), 100, 10, 40, 20)
    checkFrame(ui.widget(Button2), 150, 10, 50, 20)
    checkFrame(ui.widget(Button3), 200, 60, 40, 20)
    checkFrame(ui.widget(Button4), 250, 60, 50, 20)

  test "panel wrapper draws a container parent and lays out labels":
    var ui = UI.init()
    ui.beginLayout(400, 300)

    ui.center(CenterBox, fill(), fill()):
      ui.panelJustified(Panel1, fixed(200), fixed(100), 10.0, 10.0, AlignCenter, JustifyCenter):
        ui.label(Label1, "Counter", width = fixed(80), height = fixed(20))
        ui.label(Label2, "0", width = fixed(80), height = fixed(20))

    ui.endLayout()

    checkFrame(ui.widget(CenterBox), 0, 0, 400, 300)
    checkFrame(ui.widget(Panel1), 100, 100, 200, 100)
    checkFrame(ui.widget(Label1), 160, 125, 80, 20)
    checkFrame(ui.widget(Label2), 160, 155, 80, 20)

  test "slot captures can be placed as a list":
    var ui = UI.init()
    ui.beginLayout(240, 100)

    let actions = ui.slot:
      ui.button(Button1, "One", width = fixed(50), height = fixed(20))
      ui.button(Button2, "Two", width = fixed(60), height = fixed(20))

    ui.row(Body, fill(), fixed(30), 8.0, 0.0):
      ui.container(Panel1, Panel.new(), width = fixed(40), height = fixed(30))
      ui.place(actions)

    ui.endLayout()

    checkFrame(ui.widget(Panel1), 0, 0, 40, 30)
    checkFrame(ui.widget(Button1), 48, 0, 50, 20)
    checkFrame(ui.widget(Button2), 106, 0, 60, 20)

  test "container state can bind typed slot fields":
    var ui = UI.init()
    var header = DialogHeader.new()
    ui.beginLayout(300, 80)

    let left = ui.singleSlot:
      ui.button(Button1, "Left", width = fixed(50), height = fixed(20))
    let right = ui.slot:
      ui.button(Button2, "Right A", width = fixed(60), height = fixed(20))
      ui.button(Button5, "Right B", width = fixed(70), height = fixed(20))

    header.setSlot(header.left, left)
    header.setSlot(header.right, right)

    ui.row(Body, fill(), fixed(30), 10.0, 0.0):
      ui.place(left)
      ui.spacer(Spacer, width = fill(), height = fixed(1))
      ui.place(right)

    ui.endLayout()

    check header.left == Button1
    check header.right == @[Button2, Button5]
    checkFrame(ui.widget(Button1), 0, 0, 50, 20)
    checkFrame(ui.widget(Button2), 160, 0, 60, 20)
    checkFrame(ui.widget(Button5), 230, 0, 70, 20)

  test "list slot fields can accept a single child":
    var ui = UI.init()
    var card = Card.new()
    ui.beginLayout(180, 80)

    let content = ui.singleSlot:
      ui.button(Button1, "Only", width = fixed(50), height = fixed(20))

    card.setSlot(card.defaultSlot, content)
    ui.place(content)
    ui.endLayout()

    check card.defaultSlot == @[Button1]
    checkFrame(ui.widget(Button1), 0, 0, 50, 20)

  test "layout template resets reusable ui after draw":
    var ui = UI.init()
    var updateContext = UpdateContext(windowWidth: 200, windowHeight: 80)
    var drawContext = DrawContext(
      resources: Resources.new(), palette: Palette.init(), windowWidth: 200, windowHeight: 80
    )
    drawContext.resources.loadFont("font", "", 18)

    let rootID = ui.root.id

    ui.layout(updateContext, drawContext):
      ui.button(Button1, "One", width = fixed(50), height = fixed(20))

    check ui.root.id == rootID
    check ui.layout.boxes.len == 1
    check ui.components.len == 0

    ui.layout(updateContext, drawContext):
      ui.button(Button2, "Two", width = fixed(60), height = fixed(20))

    check ui.root.id == rootID
    check ui.layout.boxes.len == 1
    check ui.components.len == 0

  test "event blocks consume the previous frame hit state before layout":
    var ui = UI.init()
    var count = 0
    var updateContext = UpdateContext(windowWidth: 200, windowHeight: 80)
    var drawContext = DrawContext(
      resources: Resources.new(), palette: Palette.init(), windowWidth: 200, windowHeight: 80
    )
    drawContext.resources.loadFont("font", "", 18)

    ui.layout(updateContext, drawContext):
      ui.events:
        if drawContext.active(Button1):
          inc count
      ui.button(Button1, "One", width = fixed(50), height = fixed(20))

    check count == 0

    updateContext.mouseX = 10
    updateContext.mouseY = 10
    updateContext.mouseLeftPressed = true
    updateContext.mouseLeftDown = true

    ui.layout(updateContext, drawContext):
      ui.events:
        if drawContext.active(Button1):
          inc count
      ui.button(Button1, "One", width = fixed(50 + count.toFloat), height = fixed(20))

    check count == 0
    check drawContext.active(Button1)

    updateContext.mouseLeftPressed = false

    ui.layout(updateContext, drawContext):
      ui.events:
        if drawContext.active(Button1):
          inc count
      ui.button(Button1, "One", width = fixed(50 + count.toFloat), height = fixed(20))

    check count == 1
