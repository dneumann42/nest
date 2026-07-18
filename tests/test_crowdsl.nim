import std/unittest

import crow
import nest/[crowdsl, resources, ui]
import uirelays

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
