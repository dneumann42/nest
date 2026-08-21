## Exercises per-widget events: emitting, handling in a parent, raising further
## up, and container widgets that take children.

import std/[strutils, unittest]

import nest
import nest/screen

type
  CounterModel = object
    count: int

  CounterEvent = enum
    Incremented
    Decremented

  PageEvent = enum
    CountChanged
    Reset

  ShellEvent = enum
    Dirty

  RowEvent = object
    key: string
    removed: bool

# --- a leaf widget with its own event type -------------------------------

widget counter(model: CounterModel) emits CounterEvent:
  ui.row(ui.id("row"), cfg(width = fit(), height = fit(), gap = 6)):
    if ui.button(ui.id("dec"), "-", fixed(30), fixed(24)):
      emit Decremented
    ui.label(ui.id("count"), $model.count, fixed(40), fixed(24))
    if ui.button(ui.id("inc"), "+", fixed(30), fixed(24)):
      emit Incremented

# --- a parent that handles a child's events and raises its own -----------

widget page(model: CounterModel, log: var seq[string]) emits PageEvent:
  ui.column(ui.id("root"), cfg(width = fit(), height = fit(), gap = 6)):
    for event in ui.counter(model):
      case event
      of Incremented, Decremented:
        log.add "page saw " & $event
        emit CountChanged
    if ui.button(ui.id("reset"), "Reset", fixed(60), fixed(24)):
      emit Reset

# --- a grandparent that handles some events and raises others ------------

widget shell(model: CounterModel, log: var seq[string]) emits ShellEvent:
  ui.column(ui.id("root"), cfg(width = fit(), height = fit(), gap = 6)):
    for event in ui.page(model, log):
      case event
      of CountChanged:
        emit Dirty
      of Reset:
        log.add "shell handled Reset"

# --- a container that takes children ------------------------------------

widget titledCard(title: string, body: untyped):
  ui.card(ui.id("root"), cfg(width = fill(), height = fit(), padding = 8,
      gap = 6)):
    ui.label(ui.id("title"), title, fill(), fit())
    body

# --- a container that takes children and emits its own events ------------

widget removableRow(rowKey: string, events: var seq[RowEvent],
    body: untyped):
  ## A container takes its events as a parameter, since it expands to a
  ## template. Its parameter names are substituted textually, so `rowKey`
  ## rather than `key`, which would also replace the field name in
  ## `RowEvent(key: ...)`.
  ui.row(ui.id("row"), cfg(width = fill(), height = fit(), gap = 6)):
    body
    if ui.button(ui.id("remove"), "x", fixed(24), fixed(24)):
      events.add RowEvent(key: rowKey, removed: true)

var drawn: seq[string]

proc stubFonts() =
  fontRelays = FontRelays(
    openFont: proc(path: string, size: int, metrics: var FontMetrics): Font =
      metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
      Font(size),
    closeFont: proc(f: Font) = discard,
    getFontMetrics: proc(f: Font): FontMetrics =
      FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
    measureText: proc(f: Font, text: string): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    drawText: proc(f: Font, x, y: int, text: string, fg, bg: Color): TextExtent =
      drawn.add text
      TextExtent(w: max(text.len, 1) * 9, h: 18),
  )

proc newUI(): UI =
  result = UI.init()
  result.initContext(400, 300)
  result.loadFont("font", "", 18)

template frame(ui: var UI, body: untyped) =
  ## One frame. `body` runs twice, as it does in an application, so anything it
  ## collects has to be accumulated rather than assigned.
  block:
    drawn.setLen(0)
    ui.beginInputFrame()
    ui.markAllDirty()
    ui.layout:
      body
    ui.finishInputFrame()

proc clickCentre(ui: var UI, id: WidgetID) =
  let located = ui.widgetFrame(id)
  doAssert located.ok, "widget has no frame"
  ui.mouseMove((located.frame.x + located.frame.width / 2).int,
      (located.frame.y + located.frame.height / 2).int)
  ui.mouseDown()

suite "widget events":
  setup:
    stubFonts()
    var
      ui = newUI()
      log: seq[string]
      shellEvents: seq[ShellEvent]

  test "a leaf widget emits nothing without input":
    var events: seq[CounterEvent]
    ui.frame:
      events.add ui.counter(CounterModel(count: 1))
    check events.len == 0
    check "1" in drawn

  test "a click travels from leaf to grandparent":
    let model = CounterModel(count: 0)
    ui.frame:
      shellEvents.add ui.shell(model, log)

    # The `+` button belongs to `counter`, nested in `page`, nested in `shell`.
    var plus: WidgetID
    ui.scope("shell"):
      ui.scope("page"):
        ui.scope("counter"):
          plus = ui.id("inc")

    ui.beginInputFrame()
    ui.clickCentre(plus)
    ui.frame:
      shellEvents.add ui.shell(model, log)

    ui.frame:
      shellEvents.add ui.shell(model, log)

    check log == @["page saw Incremented"]
    check shellEvents == @[Dirty]

  test "a parent can handle an event instead of raising it":
    let model = CounterModel()
    ui.frame:
      shellEvents.add ui.shell(model, log)

    var reset: WidgetID
    ui.scope("shell"):
      ui.scope("page"):
        reset = ui.id("reset")

    ui.beginInputFrame()
    ui.clickCentre(reset)
    ui.frame:
      shellEvents.add ui.shell(model, log)
    ui.frame:
      shellEvents.add ui.shell(model, log)

    check log == @["shell handled Reset"]
    check shellEvents.len == 0

  test "a container widget wraps the children it is given":
    ui.frame:
      ui.titledCard("Details"):
        ui.label(ui.id("inside"), "child text", fill(), fit())

    check "Details" in drawn
    check "child text" in drawn
    ui.scope("titledCard"):
      check ui.widgetFrame(ui.id("root")).ok

  test "a container widget emits its own events":
    var rowEvents: seq[RowEvent]
    ui.frame:
      ui.removableRow("alpha", rowEvents):
        ui.label(ui.id("label"), "alpha", fill(), fit())
    check rowEvents.len == 0
    check "alpha" in drawn

    var remove: WidgetID
    ui.scope("removableRow"):
      remove = ui.id("remove")

    ui.beginInputFrame()
    ui.clickCentre(remove)
    ui.frame:
      ui.removableRow("alpha", rowEvents):
        ui.label(ui.id("label"), "alpha", fill(), fit())
    ui.frame:
      ui.removableRow("alpha", rowEvents):
        ui.label(ui.id("label"), "alpha", fill(), fit())

    check rowEvents == @[RowEvent(key: "alpha", removed: true)]

  test "children of a container emit into the caller's own queue":
    var counterEvents: seq[CounterEvent]
    let model = CounterModel()
    ui.frame:
      ui.titledCard("Wrapped"):
        counterEvents.add ui.counter(model)
    check counterEvents.len == 0

    var plus: WidgetID
    ui.scope("titledCard"):
      ui.scope("counter"):
        plus = ui.id("inc")

    ui.beginInputFrame()
    ui.clickCentre(plus)
    ui.frame:
      ui.titledCard("Wrapped"):
        counterEvents.add ui.counter(model)
    ui.frame:
      ui.titledCard("Wrapped"):
        counterEvents.add ui.counter(model)

    check counterEvents == @[Incremented]
