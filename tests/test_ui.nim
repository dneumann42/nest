import std/unittest

import nest/ui

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
