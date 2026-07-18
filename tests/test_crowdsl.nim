import std/[tables, unittest]

import crow
import nest/[crowdsl, resources, ui]
import uirelays/[coords, screen]

proc widget(ui: UI, id: WidgetID): Widget =
  for box in ui.layout.boxes:
    if box.id == id:
      return box
  raise newException(ValueError, "missing widget: " & $id)

proc render(runtime: NestCrowRuntime; ui: var UI; source: string) =
  runtime.render(ui, parse(source))

suite "Crow GUI DSL":
  test "define initializes GUI state once":
    let runtime = NestCrowRuntime.init()
    var ui = UI.init()

    runtime.render(ui, """
define:
  count = 0
events:
  += count 1
""")
    runtime.render(ui, """
define:
  count = 0
events:
  += count 1
""")

    check runtime.get("count").kind == Number
    check runtime.get("count").number == 2

  test "layout config bindings render through Nest UI":
    let originalFontRelays = fontRelays
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
        metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
        Font(size),
      closeFont: proc(f: Font) =
        discard,
      getFontMetrics: proc(f: Font): FontMetrics =
        FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
        TextExtent(w: max(text.len, 1) * 9, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg, bg: Color): TextExtent =
        TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      let runtime = NestCrowRuntime.init()
      var ui = UI.init()
      ui.initContext(300, 120)
      ui.loadFont("font", "", 18)

      runtime.renderLayoutOnly(ui, parse("""
panel (id "root"):
  width = (fixed 200)
  height = (fixed 80)
  padding = 10
  gap = 5
  alignItems = AlignCenter
  justifyContent = JustifyCenter
  label (id "label") "Counter":
    width = fit
    height = fit
"""), 300, 120)

      check not runtime.hasError
      let root = ui.id("root")
      let label = ui.id("label")
      check ui.widget(root).frame.width == 200
      check ui.widget(root).frame.height == 80
      check ui.widget(label).frame.width > 0
      check ui.widget(label).frame.height > 0
    finally:
      fontRelays = originalFontRelays

  test "counter example renders and button clicks mutate state":
    let app = NestCrowApp.init("example/counter/main.nest")
    var ui = UI.init()
    ui.initContext(360, 180)
    ui.loadFont("font", "", 18)

    app.render(ui)
    check app.lastError == ""
    check app.runtime.get("count").number == 0
    let incrementID = WidgetIDValue(app.runtime.get("incrementID").native).value

    app.runtime.evaluator.native "clicked":
      discard layout
      discard bodyNodes
      if arguments.len == 0:
        return boolean(false)
      let value = env.eval(arguments[0])
      boolean(value.kind == Native and value.native of WidgetIDValue and
        WidgetIDValue(value.native).value == incrementID)

    app.render(ui)

    check app.lastError == ""
    check app.runtime.get("count").number == 1

  test "counter example emits visible draw commands":
    let originalDrawRelays = drawRelays
    let originalFontRelays = fontRelays
    var rects = 0
    var texts = 0

    proc countRect(r: Rect; color: Color) =
      discard color
      if r.w > 0 and r.h > 0:
        inc rects

    proc countText(f: Font; x, y: int; text: string; fg, bg: Color): TextExtent =
      discard f
      discard x
      discard y
      discard fg
      discard bg
      if text.len > 0:
        inc texts
      TextExtent(w: max(text.len, 1) * 9, h: 18)

    drawRelays = DrawRelays(
      fillRect: countRect,
      drawLine: proc(x1, y1, x2, y2: int; color: Color) =
        discard,
      drawPoint: proc(x, y: int; color: Color) =
        discard,
      loadImage: proc(path: string): Image =
        Image(0),
      freeImage: proc(img: Image) =
        discard,
      drawImage: proc(img: Image; src, dst: Rect) =
        discard,
      imageSize: proc(img: Image): TextExtent =
        TextExtent(),
    )
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
        metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
        Font(size),
      closeFont: proc(f: Font) =
        discard,
      getFontMetrics: proc(f: Font): FontMetrics =
        FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
        TextExtent(w: max(text.len, 1) * 9, h: 18),
      drawText: countText,
    )
    try:
      let app = NestCrowApp.init("example/counter/main.nest")
      var ui = UI.init()
      ui.initContext(360, 180)
      ui.loadFont("font", "", 18)

      app.render(ui)

      check app.lastError == ""
      check rects > 0
      check texts >= 4
    finally:
      drawRelays = originalDrawRelays
      fontRelays = originalFontRelays

  test "layer shell bar example renders clock and widgets":
    let originalFontRelays = fontRelays
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
        metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
        Font(size),
      closeFont: proc(f: Font) =
        discard,
      getFontMetrics: proc(f: Font): FontMetrics =
        FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
        TextExtent(w: max(text.len, 1) * 9, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg, bg: Color): TextExtent =
        TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      let app = NestCrowApp.init("example/layerShellBar/main.nest")
      var ui = UI.init()
      ui.initContext(800, 36)
      ui.loadFont("font", "", 18)

      app.runtime.renderLayoutOnly(ui, app.program, 800, 36)

      check app.runtime.lastError == ""
      if app.runtime.lastError == "":
        check app.runtime.get("startID").kind == Native
        check app.runtime.get("clock").kind == Command
        check ui.widget(ui.id("bar")).frame.height == 36
        check ui.widget(ui.id("left")).frame.width > 0
        check ui.widget(ui.id("center")).frame.width > 0
        check ui.widget(ui.id("right")).frame.width > 0
    finally:
      fontRelays = originalFontRelays

  test "dialog commands expose launch data and close value":
    var runtime = NestCrowRuntime.init()
    runtime.dialogData = "Alatar"

    let data = runtime.evaluator.exec(parse("dialogData\n"))
    check data.kind == Text
    check data.text == "Alatar"

    let closeValue = runtime.evaluator.exec(parse("closeDialog \"applications\"\n"))
    check closeValue.kind == Text
    check closeValue.text == "applications"
    check runtime.requestQuit
    check runtime.dialogCloseValue == "applications"

  test "dialog result commands track completed child values":
    var runtime = NestCrowRuntime.init()
    runtime.dialogResults["start"] = "files"

    let result = runtime.evaluator.exec(parse("dialogResult \"start\"\n"))
    check result.kind == Text
    check result.text == "files"

    discard runtime.evaluator.exec(parse("clearDialogResult \"start\"\n"))
    let cleared = runtime.evaluator.exec(parse("dialogResult \"start\"\n"))
    check cleared.kind == Nothing

  test "crow events can test pressed keys":
    let runtime = NestCrowRuntime.init()
    var ui = UI.init()
    ui.initContext(120, 80)
    ui.loadFont("font", "", 18)
    ui.keyDown(KeyEsc, {})

    runtime.render(ui, parse("""
events:
  when (keyPressed "escape"):
    closeDialog "closed"
"""))

    check runtime.requestQuit
    check runtime.dialogCloseValue == "closed"

  test "openDialog reports missing child projects":
    var runtime = NestCrowRuntime.init()

    expect EvaluatorError:
      discard runtime.evaluator.exec(parse("openDialog \"missing\" \"./does-not-exist\"\n"))

  test "crow render errors do not add inline error dialogs":
    let runtime = NestCrowRuntime.init()
    var ui = UI.init()
    ui.initContext(320, 36)
    ui.loadFont("font", "", 18)
    let errorDialogID = ui.id("_nest_error_dialog")

    runtime.renderLayoutOnly(ui, parse("""
panel (id "root"):
  width = fill
  height = fill
  missingCommand
"""), 320, 36)

    check runtime.hasError
    check runtime.lastError.len > 0
    expect ValueError:
      discard ui.widget(errorDialogID)

  test "diagnostic locations parse emacs-compatible report lines":
    let primary = diagnosticLocation("/tmp/app/main.nest:12:7: error: missing field")
    check primary.ok
    check primary.path == "/tmp/app/main.nest"
    check primary.line == 12
    check primary.column == 7

    let frame = diagnosticLocation("  at /tmp/app/main.nest:20:3 in render")
    check frame.ok
    check frame.path == "/tmp/app/main.nest"
    check frame.line == 20
    check frame.column == 3

  test "date intrinsics expose minimal calendar math":
    var runtime = NestCrowRuntime.init()

    check runtime.evaluator.exec(parse("date 2026 7 18\n")).text == "2026-07-18"
    check runtime.evaluator.exec(parse("date-year \"2026-07-18\"\n")).number == 2026
    check runtime.evaluator.exec(parse("date-month \"2026-07-18\"\n")).number == 7
    check runtime.evaluator.exec(parse("date-day \"2026-07-18\"\n")).number == 18
    check runtime.evaluator.exec(parse("date-days-in-month 2024 2\n")).number == 29
    check runtime.evaluator.exec(parse("date-first-weekday 2026 7\n")).number == 3
    check runtime.evaluator.exec(parse("date-month-title 2026 7\n")).text == "July 2026"
    check runtime.evaluator.exec(parse("date-add-months \"2026-03-31\" -1\n")).text == "2026-02-28"

  test "crow calendar component renders and selects previous month":
    let originalFontRelays = fontRelays
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
        metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
        Font(size),
      closeFont: proc(f: Font) =
        discard,
      getFontMetrics: proc(f: Font): FontMetrics =
        FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
        TextExtent(w: max(text.len, 1) * 9, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg, bg: Color): TextExtent =
        TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      let runtime = NestCrowRuntime.init()
      var ui = UI.init()
      ui.initContext(320, 320)
      ui.loadFont("font", "", 18)

      runtime.renderLayoutOnly(ui, parse("""
define:
  selectedDate = "2026-07-18"
import "lib/components/calendar.nest"
dateSelector "cal" selectedDate
"""), 320, 320)

      check not runtime.hasError
      check ui.widget(ui.id("cal", "calendar")).frame.width > 0
      check ui.widget(ui.id("cal", "day", "18")).frame.width > 0

      let previousID = ui.id("cal", "previous-month")
      var eventUi = UI.init()
      eventUi.initContext(320, 320)
      eventUi.loadFont("font", "", 18)
      runtime.evaluator.native "clicked":
        discard layout
        discard bodyNodes
        if arguments.len == 0:
          return boolean(false)
        let value = env.eval(arguments[0])
        boolean(value.kind == Native and value.native of WidgetIDValue and
          WidgetIDValue(value.native).value == previousID)

      runtime.render(eventUi, parse("""
define:
  selectedDate = "2026-07-18"
import "lib/components/calendar.nest"
dateSelector "cal" selectedDate
"""))

      check runtime.get("selectedDate").text == "2026-06-18"
    finally:
      fontRelays = originalFontRelays

  test "nim can render a crow-defined component":
    let originalFontRelays = fontRelays
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
        metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
        Font(size),
      closeFont: proc(f: Font) =
        discard,
      getFontMetrics: proc(f: Font): FontMetrics =
        FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
        TextExtent(w: max(text.len, 1) * 9, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg, bg: Color): TextExtent =
        TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      let runtime = NestCrowRuntime.init()
      runtime.evaluator.env.define("selectedDate", text("2026-07-18"))
      var ui = UI.init()
      ui.initContext(320, 320)
      ui.loadFont("font", "", 18)

      ui.beginLayout(320, 320)
      runtime.renderComponent(
        ui,
        "lib/components/calendar.nest",
        "dateSelector",
        @[stringLiteral("nim-cal"), symbol("selectedDate")],
      )
      ui.applyIntrinsicSizes(ui.resources)
      discard ui.endLayout()

      check not runtime.hasError
      check ui.widget(ui.id("nim-cal", "calendar")).frame.width > 0
      check ui.widget(ui.id("nim-cal", "day", "18")).frame.width > 0
    finally:
      fontRelays = originalFontRelays
