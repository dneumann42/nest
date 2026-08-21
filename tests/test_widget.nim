## Tests for the `widget` macro: expansion, id scoping and return values.

import std/unittest

import nest
import nest/screen

type
  Msg = enum
    Decrement
    Increment

  Model = object
    count: int

widget counter(model: Model, msgs: var seq[Msg]):
  ui.row(ui.id("row"), cfg(width = fit(), height = fit(), gap = 8)):
    if ui.button(ui.id("dec"), "-", fixed(30), fixed(24)):
      msgs.add Decrement
    ui.label(ui.id("count"), $model.count, fixed(40), fixed(24))
    if ui.button(ui.id("inc"), "+", fixed(30), fixed(24)):
      msgs.add Increment

widget badge*(text: string, tone = 0):
  ui.label(ui.id("text"), text & ":" & $tone, fit(), fit())

widget swatch(value: Color) -> bool:
  ui.colorSwatch(ui.id("swatch"), value, fixed(24), fixed(24))
  result = ui.clicked(ui.id("swatch"))

widget pair(first, second: string):
  ui.row(ui.id("row"), cfg(width = fit(), height = fit(), gap = 4)):
    ui.label(ui.id("first"), first, fit(), fit())
    ui.label(ui.id("second"), second, fit(), fit())

proc frame(ui: var UI, body: proc(ui: var UI)) =
  ui.beginInputFrame()
  ui.markAllDirty()
  ui.layout:
    body(ui)
  ui.finishInputFrame()

suite "widget macro":
  setup:
    var ui = UI.init()
    ui.initContext(400, 300)
    ui.loadFont("font", "", 18)

  test "a widget declares its children":
    var msgs: seq[Msg]
    let model = Model(count: 3)
    ui.frame(proc(ui: var UI) = ui.counter(model, msgs))

    check ui.widgetFrame(ui.scopedID(ui.id("counter"), "row")).ok == false
    check msgs.len == 0

  test "ids inside a widget are scoped by its name":
    var msgs: seq[Msg]
    let model = Model()
    ui.frame(proc(ui: var UI) = ui.counter(model, msgs))

    # The same id spelled outside the component does not resolve to its widget.
    check ui.widgetFrame(ui.id("row")).ok == false
    ui.scope("counter"):
      check ui.widgetFrame(ui.id("row")).ok
      check ui.widgetFrame(ui.id("count")).ok

  test "two instances stay apart when the caller scopes them":
    var msgs: seq[Msg]
    let model = Model()
    ui.frame(
      proc(ui: var UI) =
        ui.row(ui.id("root"), cfg(width = fit(), height = fit(), gap = 8)):
          ui.scope("left"):
            ui.counter(model, msgs)
          ui.scope("right"):
            ui.counter(model, msgs)
    )

    var left, right: WidgetID
    ui.scope("left"):
      ui.scope("counter"):
        left = ui.id("count")
    ui.scope("right"):
      ui.scope("counter"):
        right = ui.id("count")

    check left != right
    check ui.widgetFrame(left).ok
    check ui.widgetFrame(right).ok

  test "widgets take defaults and grouped parameters":
    ui.frame(
      proc(ui: var UI) =
        ui.column(ui.id("root"), cfg(width = fit(), height = fit())):
          ui.badge("beta")
          ui.pair("a", "b")
    )

    ui.scope("badge"):
      check ui.widgetFrame(ui.id("text")).ok
    ui.scope("pair"):
      check ui.widgetFrame(ui.id("first")).ok
      check ui.widgetFrame(ui.id("second")).ok

  test "a widget can report an event and is discardable":
    var clicked = false
    ui.frame(
      proc(ui: var UI) =
        ui.row(ui.id("root"), cfg(width = fit(), height = fit())):
          clicked = ui.swatch(color(10, 20, 30))
          ui.swatch(color(40, 50, 60))
    )
    check clicked == false

  test "a widget body works unchanged as a plain procedure":
    proc counterProc(ui: var UI, model: Model, msgs: var seq[Msg]) =
      ui.scope("counter"):
        ui.row(ui.id("row"), cfg(width = fit(), height = fit(), gap = 8)):
          if ui.button(ui.id("dec"), "-", fixed(30), fixed(24)):
            msgs.add Decrement
          ui.label(ui.id("count"), $model.count, fixed(40), fixed(24))
          if ui.button(ui.id("inc"), "+", fixed(30), fixed(24)):
            msgs.add Increment

    var
      fromMacro = UI.init()
      fromProc = UI.init()
      msgs: seq[Msg]
    let model = Model(count: 7)
    for target in [addr fromMacro, addr fromProc]:
      target[].initContext(400, 300)
      target[].loadFont("font", "", 18)
    fromMacro.frame(proc(ui: var UI) = ui.counter(model, msgs))
    fromProc.frame(proc(ui: var UI) = ui.counterProc(model, msgs))

    var id: WidgetID
    fromMacro.scope("counter"):
      id = fromMacro.id("count")

    let a = fromMacro.widgetFrame(id)
    let b = fromProc.widgetFrame(id)
    check a.ok
    check b.ok
    check a.frame == b.frame
