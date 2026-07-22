import std/[os, strutils, tables, unittest]

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

  test "async shell output can refresh state after first render":
    let runtime = NestCrowRuntime.init()
    var ui = UI.init()
    ui.initContext(300, 120)
    ui.loadFont("font", "", 18)

    let source = """
define:
  value = ""
set value (shellAsync "async-test" "printf ready" 1000)
label (id "value") value:
  width = fit
  height = fit
"""

    for _ in 0 ..< 10:
      runtime.render(ui, source)
      if runtime.get("value").text == "ready":
        break
      os.sleep(20)

    check runtime.get("value").text == "ready"

  test "zero interval async shell replaces stale command for same key":
    let runtime = NestCrowRuntime.init()
    var ui = UI.init()
    ui.initContext(300, 120)
    ui.loadFont("font", "", 18)
    let outputPath = getTempDir() / "nest-shell-async-replace-test"
    if fileExists(outputPath):
      removeFile(outputPath)

    runtime.render(ui, """
set value (shellAsync "replace-test" "sleep 0.2; printf old > """ & outputPath & """" 0)
label (id "value") value:
  width = fit
  height = fit
""")
    runtime.render(ui, """
set value (shellAsync "replace-test" "printf new > """ & outputPath & """" 0)
label (id "value") value:
  width = fit
  height = fit
""")

    for _ in 0 ..< 10:
      runtime.render(ui, """
set value (shellAsync "replace-test" "printf new > """ & outputPath & """" 0)
label (id "value") value:
  width = fit
  height = fit
""")
      if fileExists(outputPath) and readFile(outputPath) == "new":
        break
      os.sleep(20)

    os.sleep(250)
    check fileExists(outputPath)
    check readFile(outputPath) == "new"
    if fileExists(outputPath):
      removeFile(outputPath)

  test "shell launch survives runtime shell cleanup":
    let runtime = NestCrowRuntime.init()
    let outputPath = getTempDir() / "nest-shell-launch-test"
    if fileExists(outputPath):
      removeFile(outputPath)

    let launched = runtime.evaluator.exec(parse(
      "shellLaunch \"sleep 0.1; printf launched > " & outputPath & "\"\n"
    ))
    runtime.closeShellProcesses()

    for _ in 0 ..< 10:
      if fileExists(outputPath):
        break
      os.sleep(30)

    check launched.kind == Boolean
    check launched.boolean
    check fileExists(outputPath)
    if fileExists(outputPath):
      check readFile(outputPath) == "launched"
      removeFile(outputPath)

  test "start popover terminal commands use foot with script paths":
    let source = readFile("apps/layerShellBar/startPopover/main.nest")

    check source.contains(
      "cmd = \"foot /home/dneumann/.config/sway/scripts/monitors.sh pick\""
    )
    check source.contains(
      "cmd = \"foot /home/dneumann/.config/sway/scripts/sway-float-rules\""
    )
    check not source.contains("cmd = \"~/.config/sway/scripts/monitors.sh pick\"")
    check not source.contains("cmd = \"foot sway-float-rules\"")

  test "volume dialog status does not reuse bar percentage command":
    let
      dialogSource = readFile("apps/layerShellBar/volume/main.nest")
      componentSource = readFile("apps/layerShellBar/components/volume.nest")

    check dialogSource.contains("set status (shell (volumeDialogStatusCommand))")
    check not dialogSource.contains("set status (shell (volumeStatusCommand))")
    check componentSource.contains("fun volumeDialogStatusCommand:")
    check componentSource.contains("printf 'Muted'")
    check componentSource.contains("printf 'Unmuted'")

  test "notification mailbox uses uncapped indexed scroll list":
    let
      dialogSource = readFile("apps/layerShellBar/notifications/main.nest")
      componentSource = readFile("apps/layerShellBar/components/notifications.nest")

    check dialogSource.contains("scrollY = true")
    check dialogSource.contains("rows = list")
    check dialogSource.contains("set rows (textLines (shellAsync")
    check dialogSource.contains("rowIndex = 0")
    check dialogSource.contains("set rowIndex 0")
    check dialogSource.contains("card (id \"notifications\" \"row\" rowIndex)")
    check dialogSource.contains("+= rowIndex 1")
    check not dialogSource.contains("rows = (textLines (shellAsync")
    check not componentSource.contains("rows[:5]")
    check componentSource.contains("for item in rows:")

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
    let app = NestCrowApp.init("apps/counter/main.nest")
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
      let app = NestCrowApp.init("apps/counter/main.nest")
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
    var app: NestCrowApp = nil
    try:
      app = NestCrowApp.init("apps/layerShellBar/main.nest")
      var ui = UI.init()
      ui.initContext(800, 30)
      ui.loadFont("font", "", 18)

      app.runtime.renderLayoutOnly(ui, app.program, 800, 30)

      check app.runtime.lastError == ""
      if app.runtime.lastError == "":
        check app.runtime.get("startID").kind == Native
        check app.runtime.get("clock").kind == Command
        check ui.widget(ui.id("bar")).frame.height == 30
        check ui.widget(ui.id("content")).frame.width > 0
        let clockFrame = ui.widget(ui.id("clock")).frame
        check abs((clockFrame.x + clockFrame.width / 2) - 400) <= 2
        check ui.widget(ui.id("right")).frame.width > 0
        check ui.widget(ui.id("bar", "active-window")).frame.width > 0
        check ui.widget(ui.id("bar", "volume")).frame.width > 0
        check ui.widget(ui.id("bar-media", "art")).frame.width == 26
        check ui.widget(ui.id("bar", "cpu")).frame.width > 0
        check ui.widget(ui.id("bar", "memory")).frame.width > 0
        check ui.widget(ui.id("bar", "storage")).frame.width > 0
        check ui.widget(ui.id("bar", "notifications")).frame.width > 0
        check ui.widget(ui.id("bar", "network")).frame.width > 0

      let mediaApp = NestCrowApp.init("apps/layerShellBar/media/main.nest")
      var mediaUi = UI.init()
      mediaUi.initContext(420, 560)
      mediaUi.loadFont("font", "", 18)

      mediaApp.runtime.renderLayoutOnly(mediaUi, mediaApp.program, 420, 560)

      check mediaApp.runtime.lastError == ""
      if mediaApp.runtime.lastError == "":
        let artworkFrame = mediaUi.widget(mediaUi.id("media", "artwork")).frame
        let tableFrame = mediaUi.widget(mediaUi.id("media", "metadata-table")).frame
        check artworkFrame.height == 280
        check tableFrame.width > 0
        check tableFrame.x > artworkFrame.x + artworkFrame.width

      for spec in [
        ("apps/layerShellBar/startPopover/main.nest", 420, 420, ui.id("menu", "panel")),
        ("apps/layerShellBar/volume/main.nest", 260, 170, ui.id("volume", "panel")),
        ("apps/layerShellBar/notifications/main.nest", 420, 260, ui.id("notifications", "panel")),
      ]:
        let (path, width, height, rootID) = spec
        let dialogApp = NestCrowApp.init(path)
        var dialogUi = UI.init()
        dialogUi.initContext(width, height)
        dialogUi.loadFont("font", "", 18)
        dialogApp.runtime.renderLayoutOnly(dialogUi, dialogApp.program, width, height)
        check dialogApp.runtime.lastError == ""
        if dialogApp.runtime.lastError == "":
          check dialogUi.widget(rootID).frame.width > 0
          if path == "apps/layerShellBar/startPopover/main.nest":
            let
              panelFrame = dialogUi.widget(rootID).frame
              leftFrame = dialogUi.widget(dialogUi.id("menu", "left")).frame
              rightFrame = dialogUi.widget(dialogUi.id("menu", "right")).frame
            check leftFrame.width > 0
            check rightFrame.width > 0
            check rightFrame.x > leftFrame.x
            check rightFrame.x + rightFrame.width <= panelFrame.x + panelFrame.width
    finally:
      if app != nil:
        app.runtime.closeDialogProcesses()
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

  test "sway workspace intrinsics parse state and quote activation commands":
    var runtime = NestCrowRuntime.init()

    let parsed = runtime.evaluator.exec(parse("""
swayWorkspaces "[{\"name\":\"1\",\"num\":1,\"focused\":true,\"visible\":true,\"urgent\":false},{\"name\":\"dev's\",\"num\":2,\"focused\":false,\"visible\":false,\"urgent\":true}]"
"""))

    check parsed.kind == List
    check parsed.items.len == 2
    check parsed.items[0].entries["name"].text == "1"
    check parsed.items[0].entries["num"].number == 1
    check parsed.items[0].entries["focused"].boolean
    check parsed.items[1].entries["urgent"].boolean
    check runtime.evaluator.exec(parse("swayWorkspaceCommand \"dev's\"\n")).text ==
      "swaymsg workspace 'dev'\\''s'"

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
import "apps/layerShellBar/components/calendar.nest"
dateSelector "cal" selectedDate
"""), 320, 320)

      check runtime.lastError == ""
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
import "apps/layerShellBar/components/calendar.nest"
dateSelector "cal" selectedDate
"""))

      check runtime.get("selectedDate").text == "2026-06-18"
    finally:
      fontRelays = originalFontRelays

  test "crow calendar component signals selected day clicks":
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
      let dayID = UI.init().id("cal", "day", "18")
      var ui = UI.init()
      ui.initContext(320, 320)
      ui.loadFont("font", "", 18)

      runtime.evaluator.native "clicked":
        discard layout
        discard bodyNodes
        if arguments.len == 0:
          return boolean(false)
        let value = env.eval(arguments[0])
        boolean(value.kind == Native and value.native of WidgetIDValue and
          WidgetIDValue(value.native).value == dayID)

      runtime.render(ui, parse("""
define:
  selectedDate = "2026-07-18"
  clickedDate = nothing
import "apps/layerShellBar/components/calendar.nest"
dateSelectorWithSignal "cal" selectedDate clickedDate
"""))

      check runtime.get("selectedDate").text == "2026-07-18"
      check runtime.get("clickedDate").text == "2026-07-18"
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
        "apps/layerShellBar/components/calendar.nest",
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
