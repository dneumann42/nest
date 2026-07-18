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
