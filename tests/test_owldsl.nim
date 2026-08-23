import std/[os, strutils, tables, unittest]

import owl
import nest/[owldsl, input, perf, projectConfig, resources, ui]
import nest/[coords, screen]

proc widget(ui: UI, id: WidgetID): Widget =
  for box in ui.layout.boxes:
    if box.id == id:
      return box
  raise newException(ValueError, "missing widget: " & $id)

proc render(runtime: NestOwlRuntime; ui: var UI; source: string) =
  runtime.render(ui, parse(source))

suite "Owl GUI DSL":
  test "state initializes GUI state once":
    let runtime = NestOwlRuntime.init()
    var ui = UI.init()

    runtime.render(ui, """
state "root":
  count = 0
events:
  += count 1
""")
    runtime.render(ui, """
state "root":
  count = 0
events:
  += count 1
""")

    check runtime.get("count").kind == Number
    check runtime.get("count").number == 2

  test "state persists a widget model through ordinary set":
    let runtime = NestOwlRuntime.init()
    var ui = UI.init()

    runtime.render(ui, """
state "counter":
  count = 0
events:
  += count 1
""")
    runtime.render(ui, """
state "counter":
  count = 0
events:
  += count 1
""")

    check runtime.get("count").kind == Number
    check runtime.get("count").number == 2

  test "state initializes structured values":
    let runtime = NestOwlRuntime.init()
    var ui = UI.init()

    runtime.render(ui, """
fun leaf:
  {}:
    kind = "leaf"
state "tree":
  value = (leaf)
""")

    check runtime.get("value").kind == Dictionary
    check runtime.get("value").entries["kind"].text == "leaf"

  test "Owl functions retain dictionary arguments in dictionary fields":
    let runtime = NestOwlRuntime.init()
    let value = runtime.evaluator.exec(parse("""
fun leaf name:
  {}:
    kind = "leaf"
    id = name
fun split direction left right:
  {}:
    kind = "split"
    direction = direction
    first = left
    second = right
dict-get (split "vertical" (leaf "one") (leaf "two")) "first"
"""))

    check value.kind == Dictionary
    check value.entries["kind"].text == "leaf"

  test "imports are loaded once per runtime":
    let dir = getTempDir() / "nest-owl-import-once-test"
    createDir(dir)
    writeFile(dir / "module.owl", """
fun importedLabel:
  label (id "imported") "Imported":
    width = fit
    height = fit
""")

    let runtime = NestOwlRuntime.init()
    var ui = UI.init()
    ui.initContext(300, 120)
    ui.loadFont("font", "", 18)

    let source = """
import "module.owl"
importedLabel
"""
    let before = registeredSourceCount()
    runtime.render(ui, parse(source, dir / "main.owl"))
    let afterFirst = registeredSourceCount()
    runtime.render(ui, parse(source, dir / "main.owl"))

    check afterFirst == before + 2
    check registeredSourceCount() == afterFirst

  test "perf overlay can be toggled from owl":
    setPerfOverlay(false)
    let runtime = NestOwlRuntime.init()
    var ui = UI.init()
    ui.initContext(300, 120)
    ui.loadFont("font", "", 18)

    runtime.render(ui, parse("""
events:
  togglePerfOverlay
"""))

    check perfOverlayEnabled()
    check runtime.evaluator.exec(parse("perfOverlay\n")).boolean
    discard runtime.evaluator.exec(parse("setPerfOverlay false\n"))
    check not perfOverlayEnabled()

  test "async shell output can refresh state after first render":
    let runtime = NestOwlRuntime.init()
    var ui = UI.init()
    ui.initContext(300, 120)
    ui.loadFont("font", "", 18)

    let source = """
state "root":
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
    let runtime = NestOwlRuntime.init()
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
    let runtime = NestOwlRuntime.init()
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

  test "shellQuote and copyText expose shell-safe clipboard actions":
    let runtime = NestOwlRuntime.init()
    let originalClipboard = clipboardRelays
    var copied = ""
    clipboardRelays = ClipboardRelays(
      getText: proc (): string = copied,
      putText: proc (text: string) =
      copied = text,
    )
    defer:
      clipboardRelays = originalClipboard

    check runtime.evaluator.exec(parse("shellQuote \"dev's path\"\n")).text ==
      "'dev'\\''s path'"
    let copiedValue = runtime.evaluator.exec(parse("copyText \"debug output\"\n"))
    check copiedValue.kind == Boolean
    check copiedValue.boolean
    check copied == "debug output"

  test "start popover terminal commands use foot with script paths":
    let source = readFile("apps/layerShellBar/startPopover/main.owl")

    check source.contains(
      "cmd = \"foot /home/dneumann/.config/sway/scripts/monitors.sh pick\""
    )
    check source.contains(
      "cmd = \"foot /home/dneumann/.config/sway/scripts/sway-float-rules\""
    )
    check not source.contains("cmd = \"~/.config/sway/scripts/monitors.sh pick\"")
    check not source.contains("cmd = \"foot sway-float-rules\"")

  test "volume dialog uses async dialog status command":
    let
      dialogSource = readFile("apps/layerShellBar/volume/main.owl")
      widgetSource = readFile("apps/layerShellBar/components/volume.owl")

    check dialogSource.contains(
      "set status (shellAsync (id \"volume\" \"query\" \"status\") (volumeDialogStatusCommand) FastPollInterval)"
    )
    check not dialogSource.contains("set status (shell (volumeStatusCommand))")
    check not dialogSource.contains("set percent (shell (volumePercentCommand))")
    check not dialogSource.contains("set defaultSink (shell (volumeDefaultSinkCommand))")
    check not dialogSource.contains("set sinks (textLines (shell (volumeSinkListCommand)))")
    check widgetSource.contains("fun volumeDialogStatusCommand:")
    check widgetSource.contains("printf 'Muted'")
    check widgetSource.contains("printf 'Unmuted'")

  test "notification mailbox uses uncapped indexed scroll list":
    let
      dialogSource = readFile("apps/layerShellBar/notifications/main.owl")
      widgetSource = readFile("apps/layerShellBar/components/notifications.owl")

    check dialogSource.contains("scrollY = true")
    check dialogSource.contains("rows = list")
    check dialogSource.contains("set rows (textLines (shellAsync")
    check dialogSource.contains("rowIndex = 0")
    check dialogSource.contains("set rowIndex 0")
    check dialogSource.contains("card (id \"notifications\" \"row\" rowIndex)")
    check dialogSource.contains("+= rowIndex 1")
    check not dialogSource.contains("rows = (textLines (shellAsync")
    check not widgetSource.contains("rows[:5]")
    check widgetSource.contains("for item in rows:")

  test "network dialog exposes only actionable controls":
    let dialogSource = readFile("apps/layerShellBar/network/main.owl")

    check dialogSource.contains("Loading network status...")
    check dialogSource.contains("Loading Wi-Fi networks...")
    check dialogSource.contains("rowKind = \"\"")
    check dialogSource.contains("set rowSelected (tsvCell rowText 0 2)")
    check dialogSource.contains("button (id \"network\" \"wifi\" \"row\" rowName) rowLabel")
    check dialogSource.contains("background = (pick (= rowSelected \"yes\")")
    check dialogSource.contains("when (and (= editorAvailable \"yes\") (clicked editorID)):")
    check dialogSource.contains("shellLaunch (connectionEditorCommand)")
    check not dialogSource.contains("editor-action")

  test "start popover can request parent-owned actions":
    let
      menuSource = readFile("apps/layerShellBar/startPopover/main.owl")
      barSource = readFile("apps/layerShellBar/main.owl")

    check menuSource.contains("label = \"Perf Overlay\"")
    check menuSource.contains("cmd = \"toggle-perf-overlay\"")
    check menuSource.contains("label = \"Wallpaper\"")
    check menuSource.contains("cmd = \"open-wallpaper-switcher\"")
    check menuSource.contains(
      "if (or (= command.cmd \"toggle-perf-overlay\") (= command.cmd \"open-wallpaper-switcher\")):"
    )
    check barSource.contains("when (= lastAction \"toggle-perf-overlay\"):")
    check barSource.contains("togglePerfOverlay")
    check barSource.contains("when (= lastAction \"open-wallpaper-switcher\"):")
    check barSource.contains("shellLaunch (wallpaperSwitcherCommand)")

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
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      let runtime = NestOwlRuntime.init()
      var ui = UI.init()
      ui.initContext(300, 120)
      ui.loadFont("font", "", 18)

      runtime.renderLayoutOnly(ui, parse(
          """
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

  test "layout config supports owl insets and padding edge overrides":
    let runtime = NestOwlRuntime.init()
    var ui = UI.init()
    ui.initContext(300, 120)

    runtime.renderLayoutOnly(ui, parse(
        """
row (id "root"):
  width = (fixed 200)
  height = (fixed 80)
  padding = (insets 4 8 12 16)
  paddingLeft = 20
  gap = 5
  label (id "label") "Inset":
    width = (fixed 40)
    height = (fixed 20)
"""), 300, 120)

    check not runtime.hasError
    let label = ui.id("label")
    check ui.widget(label).frame.x == 20
    check ui.widget(label).frame.y == 8
    check ui.widget(label).frame.width == 40
    check ui.widget(label).frame.height == 20

  test "tabs command renders labels and clamps selected symbol":
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
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      let runtime = NestOwlRuntime.init()
      var ui = UI.init()
      ui.initContext(300, 120)
      ui.loadFont("font", "", 18)

      runtime.renderLayoutOnly(ui, parse(
          """
state "root":
  selected = 9
  labels = []:
    "one"
    "two"
tabs (id "tabs") labels selected:
  width = fill
  height = fit
"""), 300, 120)

      check not runtime.hasError
      check runtime.get("selected").number == 1
      check ui.widget(ui.id("tabs")).frame.width > 0
      check ui.widget(ui.id(ui.id("tabs"), "tab", 0)).frame.width > 0
      check ui.widget(ui.id(ui.id("tabs"), "tab", 1)).frame.width > 0
    finally:
      fontRelays = originalFontRelays

  test "owl widget commands share Nim UI driver sizing defaults":
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
      TextExtent(w: max(text.len, 1) * 8, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 8, h: 18),
    )
    try:
      let runtime = NestOwlRuntime.init()
      var ui = UI.init()
      ui.initContext(420, 260)
      ui.loadFont("font", "", 18)

      runtime.renderLayoutOnly(ui, parse(
          """
state "root":
  selected = 0
  options = []:
    "one"
    "two"
row (id "leaf-row"):
  width = (fixed 420)
  height = (fixed 60)
  gap = 8
  alignItems = AlignStart
  label (id "label") "Label"
  button (id "button") "Button"
  checkbox (id "checkbox") "Check" true
  combobox (id "combo") selected options
row (id "fill-row"):
  width = (fixed 420)
  height = (fixed 60)
  gap = 8
  alignItems = AlignStart
  lineInput (id "input") ""
  horizontalSlider (id "slider") 20 0 100
  tabs (id "tabs") options selected
editor (id "editor")
"""), 420, 260)

      check not runtime.hasError
      for id in ["label", "button", "checkbox", "combo"]:
        let frame = ui.widget(ui.id(id)).frame
        check frame.width > 0
        check frame.width < 120
        check frame.height > 0
        check frame.height < 60

      check ui.widget(ui.id("input")).frame.width >= 160
      check ui.widget(ui.id("slider")).frame.width >= 120
      check ui.widget(ui.id("tabs")).frame.width > 0
      for id in ["input", "slider", "tabs"]:
        check ui.widget(ui.id(id)).frame.height > 0

      let editorFrame = ui.widget(ui.id("editor")).frame
      check editorFrame.width == 420
      check editorFrame.height >= 160
    finally:
      fontRelays = originalFontRelays

  test "duck app renders with at least one buffer tab":
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
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      let app = NestOwlApp.init("apps/duck/main.owl")
      var ui = UI.init()
      ui.initContext(800, 600)
      ui.loadFont("font", "", 18)
      ui.loadFont("editor", "", 18)

      app.runtime.render(ui, app.program)
      check app.runtime.lastError == ""
      discard app.runtime.evaluator.exec(parse("send \"duck.editor.split\" true\n"))
      app.runtime.render(ui, app.program)
      check app.runtime.lastError == ""
      discard app.runtime.evaluator.exec(parse("send \"duck.editor.split-horizontal\" true\n"))
      app.runtime.render(ui, app.program)
      check app.runtime.lastError == ""
      discard app.runtime.evaluator.exec(parse("send \"duck.editor.split\" true\n"))
      app.runtime.render(ui, app.program)
      check app.runtime.lastError == ""
      app.runtime.renderLayoutOnly(ui, app.program, 800, 600)
      let
        leftPane = ui.widget(ui.id("duck:workspace", "pane", "pane-1")).frame
        upperPane = ui.widget(ui.id("duck:workspace", "pane", "pane-2")).frame
        lowerPane = ui.widget(ui.id("duck:workspace", "pane", "pane-3")).frame
        rightPane = ui.widget(ui.id("duck:workspace", "pane", "pane-4")).frame
      check leftPane.x < upperPane.x
      check upperPane.y < lowerPane.y
      check lowerPane.x < rightPane.x

      for _ in 0 ..< 2:
        discard app.runtime.evaluator.exec(parse("send \"duck.editor.split\" true\n"))
        var splitUi = UI.init()
        splitUi.initContext(800, 600)
        splitUi.loadFont("font", "", 18)
        splitUi.loadFont("editor", "", 18)
        app.runtime.render(splitUi, app.program)
        check app.runtime.lastError == ""

      discard app.runtime.evaluator.exec(parse(
        "setEditorText \"duck:buffer:1\" \"shared pane content\"\n"
      ))
      var focusedPaneUi = UI.init()
      focusedPaneUi.initContext(800, 600)
      focusedPaneUi.loadFont("font", "", 18)
      focusedPaneUi.loadFont("editor", "", 18)
      app.runtime.render(focusedPaneUi, app.program)
      check app.runtime.lastError == ""
      let focusedText = app.runtime.evaluator.exec(parse(
        "editorText \"duck:buffer:1\"\n"
      ))
      check focusedText.kind == Text
      check focusedText.text == "shared pane content"

      check app.runtime.lastError == ""
      check app.runtime.get("activeBuffer").number == 0
      check app.runtime.get("buffers").items.len >= 1
      check ui.widget(ui.id(ui.id("duck", "tabs"), "tab", 0)).frame.width > 0
      check ui.widget(ui.id("duck:workspace", "pane", "pane-1",
          "editor")).frame.height > 0
    finally:
      fontRelays = originalFontRelays

  test "counter example renders and button clicks mutate state":
    let app = NestOwlApp.init("apps/counter/main.owl")
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

  test "reloading an app schedules an immediate redraw":
    let app = NestOwlApp.init("apps/counter/main.owl")
    var ui = UI.init()
    ui.initContext(360, 180)
    ui.loadFont("font", "", 18)
    app.program = nil

    app.render(ui)

    check app.program != nil
    check ui.redrawDelayMs() == 0

  test "apps poll for hot reloads while idle":
    let app = NestOwlApp.init("apps/counter/main.owl")
    var ui = UI.init()
    ui.initContext(360, 180)
    ui.loadFont("font", "", 18)

    app.render(ui)

    check ui.redrawDelayMs() >= 0

  test "app mouse hover updates retained frame without rerunning owl":
    let
      originalInputRelays = inputRelays
      path = getTempDir() / "nest-retained-hover-test.owl"
    var ticks = 1000
    inputRelays.getTicks = proc(): int =
      ticks
    writeFile(path, """
state "root":
  count = 0
  hoverID = (id "hover")

events:
  += count 1

button hoverID "Hover":
  width = fixed 120
  height = fixed 32
""")
    try:
      let app = NestOwlApp.init(path)
      var ui = UI.init()
      ui.initContext(360, 180)
      ui.loadFont("font", "", 18)

      app.render(ui)
      check app.runtime.get("count").number == 1

      ticks = 1010
      ui.mouseMove(10, 10)
      app.render(ui)

      check app.runtime.get("count").number == 1
      check ui.redrewFrame()
    finally:
      inputRelays = originalInputRelays
      if fileExists(path):
        removeFile(path)

  test "app retained redraw advances owl animations with current ticks":
    let
      originalInputRelays = inputRelays
      path = getTempDir() / "nest-retained-animation-test.owl"
    var ticks = 1000
    inputRelays.getTicks = proc(): int =
      ticks
    writeFile(path, """
state "root":
  count = 0

events:
  += count 1

animation (id "panel"):
  duration = 120
  curve = "linear"
  fromOpacity = 0
  maxOpacity = 0.95
  card (id "panel"):
    width = fixed 120
    height = fixed 48
    label (id "text") "Animated":
      width = fit
      height = fit
""")
    try:
      let app = NestOwlApp.init(path)
      var ui = UI.init()
      ui.initContext(360, 180)
      ui.loadFont("font", "", 18)

      ui.setDrawTicks(ticks)
      app.render(ui)
      let initial = ui.animationValue(ui.id("panel"))
      check initial.progress == 0.0
      check app.runtime.get("count").number == 1

      ticks = 1050
      app.render(ui)
      let advanced = ui.animationValue(ui.id("panel"))
      check app.runtime.get("count").number == 1
      check advanced.progress > initial.progress
      check advanced.opacity > initial.opacity
      check advanced.running
    finally:
      inputRelays = originalInputRelays
      if fileExists(path):
        removeFile(path)

  test "app pending dialog close forces full render for reverse animation":
    let
      originalInputRelays = inputRelays
      path = getTempDir() / "nest-dialog-close-animation-test.owl"
    var ticks = 1000
    inputRelays.getTicks = proc(): int =
      ticks
    writeFile(path, """
animation (id "panel") (not (dialogClosing?)):
  duration = 120
  curve = "linear"
  fromOpacity = 0
  maxOpacity = 0.95
  card (id "panel"):
    width = fixed 120
    height = fixed 48
    label (id "text") "Animated":
      width = fit
      height = fit
""")
    try:
      let app = NestOwlApp.init(path)
      var ui = UI.init()
      ui.initContext(360, 180)
      ui.loadFont("font", "", 18)

      ui.setDrawTicks(ticks)
      app.render(ui)
      ticks = 1200
      ui.setDrawTicks(ticks)
      app.render(ui)
      check ui.animationValue(ui.id("panel")).progress == 1.0

      app.runtime.requestDialogClose("")
      ticks = 1210
      ui.setDrawTicks(ticks)
      app.render(ui)

      let closing = ui.animationValue(ui.id("panel"))
      check app.runtime.dialogCloseRequested
      check closing.running

      ticks = 1230
      ui.setDrawTicks(ticks)
      app.render(ui)
      let closingAdvanced = ui.animationValue(ui.id("panel"))
      check closingAdvanced.running
      check closingAdvanced.progress < closing.progress
      check closingAdvanced.opacity < closing.opacity
    finally:
      inputRelays = originalInputRelays
      if fileExists(path):
        removeFile(path)

  test "counter example emits visible draw commands":
    let originalDrawRelays = drawRelays
    let originalFontRelays = fontRelays
    var rects = 0
    var texts = 0

    proc countRect(r: Rect; color: Color) =
      discard color
      if r.w > 0 and r.h > 0:
        inc rects

    proc countText(f: Font; x, y: int; text: string; fg,
        bg: Color): TextExtent =
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
      let app = NestOwlApp.init("apps/counter/main.owl")
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

  test "wallpaper switcher app renders across repeated frames":
    let originalDrawRelays = drawRelays
    let originalFontRelays = fontRelays
    var rects = 0
    var texts = 0

    proc countRect(r: Rect; color: Color) =
      discard color
      if r.w > 0 and r.h > 0:
        inc rects

    proc countText(f: Font; x, y: int; text: string; fg,
        bg: Color): TextExtent =
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
      let app = NestOwlApp.init("apps/wallpaperSwitcher/main.owl")
      var ui = UI.init()
      ui.initContext(420, 240)
      ui.loadFont("font", "", 18)

      app.render(ui)
      check app.lastError == ""
      app.render(ui)
      check app.lastError == ""
      check rects > 0
      check texts >= 4

      var layoutUi = UI.init()
      layoutUi.initContext(420, 240)
      layoutUi.loadFont("font", "", 18)
      app.runtime.renderLayoutOnly(layoutUi, app.program, 420, 240)
      check app.runtime.lastError == ""

      layoutUi = UI.init()
      layoutUi.initContext(420, 240)
      layoutUi.loadFont("font", "", 18)
      app.runtime.renderLayoutOnly(layoutUi, app.program, 420, 240)
      check app.runtime.lastError == ""

      if app.runtime.lastError == "":
        check layoutUi.widget(layoutUi.id("wallpaper", "panel")).frame.width > 0
        check layoutUi.widget(layoutUi.id("wallpaper",
            "duration")).frame.width > 0
        check layoutUi.widget(layoutUi.id("wallpaper", "enabled")).frame.width > 0
        check layoutUi.widget(layoutUi.id("wallpaper", "random")).frame.width > 0
        check layoutUi.widget(layoutUi.id("wallpaper", "picker")).frame.width > 0
        check layoutUi.widget(layoutUi.id("wallpaper", "footer")).frame.width > 0
        check layoutUi.widget(layoutUi.id("wallpaper", "status")).frame.width > 0
    finally:
      drawRelays = originalDrawRelays
      fontRelays = originalFontRelays

  test "wallpaper switcher checkbox toggles timer command":
    let app = NestOwlApp.init("apps/wallpaperSwitcher/main.owl")
    var ui = UI.init()
    ui.initContext(420, 240)
    ui.loadFont("font", "", 18)
    var
      timerEnabled = true
      disableCalls = 0
      enableCalls = 0
      checkboxClicked = false

    app.runtime.evaluator.native "shell":
      discard layout
      discard bodyNodes
      let command = env.eval(arguments[0]).text
      if command.contains("disable --now wallpaper-switch.timer"):
        timerEnabled = false
        inc disableCalls
        text("")
      elif command.contains("enable --now wallpaper-switch.timer"):
        timerEnabled = true
        inc enableCalls
        text("")
      elif command.contains("is-enabled"):
        text(if timerEnabled: "enabled" else: "disabled")
      elif command.contains("OnUnitInactiveSec"):
        text("1")
      elif command.contains("is-active") or command.contains("show wallpaper-switch.timer"):
        text(if timerEnabled: "enabled, active, every 10m" else: "disabled, inactive, every 10m")
      else:
        text("")

    app.runtime.evaluator.native "clicked":
      discard layout
      discard bodyNodes
      if arguments.len == 0:
        return boolean(false)
      let value = env.eval(arguments[0])
      let matched = checkboxClicked and value.kind == Native and
        value.native of WidgetIDValue and
        WidgetIDValue(value.native).value == ui.id("wallpaper", "enabled")
      if matched:
        checkboxClicked = false
      boolean(matched)

    app.render(ui)
    check app.lastError == ""
    check app.runtime.get("switchEnabled").kind == Boolean
    check app.runtime.get("switchEnabled").boolean
    let enabledFrame = ui.widgetFrame(ui.id("wallpaper", "enabled"))
    check enabledFrame.ok

    checkboxClicked = true
    app.render(ui)

    check app.lastError == ""
    check disableCalls == 1
    check enableCalls == 0
    check app.runtime.get("switchEnabled").kind == Boolean
    check not app.runtime.get("switchEnabled").boolean

  test "owl if else inside event-style block runs only one branch":
    let runtime = NestOwlRuntime.init()
    let value = runtime.evaluator.exec(parse("""
define:
  wasClicked = true
  enabled = true
  actions = ""
when wasClicked:
  if enabled:
    set actions (string actions "disable")
  else:
    set actions (string actions "enable")
actions
"""))

    check value.kind == Text
    check value.text == "disable"

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
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    var app: NestOwlApp = nil
    try:
      app = NestOwlApp.init("apps/layerShellBar/main.owl")
      var ui = UI.init()
      let barHeight = loadProjectConfig("apps/layerShellBar").height
      ui.initContext(800, barHeight)
      ui.loadFont("font", "", 18)

      app.runtime.renderLayoutOnly(ui, app.program, 800, barHeight)

      check app.runtime.lastError == ""
      if app.runtime.lastError == "":
        check app.runtime.get("startID").kind == Native
        check app.runtime.get("clock").kind == Command
        check ui.widget(ui.id("bar")).frame.height == barHeight
        check ui.widget(ui.id("content")).frame.width > 0
        let clockFrame = ui.widget(ui.id("clock")).frame
        check abs((clockFrame.x + clockFrame.width / 2) - 400) <= 2
        check ui.widget(ui.id("right")).frame.width > 0
        check ui.widget(ui.id("bar", "active-window")).frame.width > 0
        check ui.widget(ui.id("bar", "volume")).frame.width > 0
        check ui.widget(ui.id("bar-media", "art")).frame.width ==
          app.runtime.get("MediaBarArtSize").number
        check ui.widget(ui.id("bar", "cpu")).frame.width > 0
        check ui.widget(ui.id("bar", "memory")).frame.width > 0
        check ui.widget(ui.id("bar", "storage")).frame.width > 0
        check ui.widget(ui.id("bar", "notifications")).frame.width > 0
        check ui.widget(ui.id("bar", "network")).frame.width > 0

      let mediaApp = NestOwlApp.init("apps/layerShellBar/media/main.owl")
      var mediaUi = UI.init()
      mediaUi.initContext(760, 400)
      mediaUi.loadFont("font", "", 18)

      mediaApp.runtime.renderLayoutOnly(mediaUi, mediaApp.program, 760, 400)

      check mediaApp.runtime.lastError == ""
      if mediaApp.runtime.lastError == "":
        let artworkFrame = mediaUi.widget(mediaUi.id("media", "artwork")).frame
        let tableFrame = mediaUi.widget(mediaUi.id("media",
            "metadata-table")).frame
        let detailsFrame = mediaUi.widget(mediaUi.id("media", "details")).frame
        check artworkFrame.height == 240
        check tableFrame.width > 0
        check detailsFrame.x > artworkFrame.x + artworkFrame.width
        check tableFrame.x >= detailsFrame.x

      for spec in [
        ("apps/layerShellBar/startPopover/main.owl", 420, 420, ui.id("menu",
            "panel")),
        ("apps/layerShellBar/volume/main.owl", 260, 170, ui.id("volume",
            "panel")),
        ("apps/layerShellBar/notifications/main.owl", 420, 260, ui.id(
            "notifications", "panel")),
        ("apps/layerShellBar/network/main.owl", 620, 520, ui.id("network",
            "panel")),
      ]:
        let (path, width, height, rootID) = spec
        let dialogApp = NestOwlApp.init(path)
        var dialogUi = UI.init()
        dialogUi.initContext(width, height)
        dialogUi.loadFont("font", "", 18)
        dialogApp.runtime.renderLayoutOnly(dialogUi, dialogApp.program, width, height)
        check dialogApp.runtime.lastError == ""
        if dialogApp.runtime.lastError == "":
          check dialogUi.widget(rootID).frame.width > 0
          if path == "apps/layerShellBar/startPopover/main.owl":
            let
              panelFrame = dialogUi.widget(rootID).frame
              leftFrame = dialogUi.widget(dialogUi.id("menu", "left")).frame
              rightFrame = dialogUi.widget(dialogUi.id("menu", "right")).frame
            check leftFrame.width > 0
            check rightFrame.width > 0
            check rightFrame.x > leftFrame.x
            check rightFrame.x + rightFrame.width <= panelFrame.x +
                panelFrame.width
    finally:
      if app != nil:
        app.runtime.closeDialogProcesses()
      fontRelays = originalFontRelays

  test "dialog commands expose launch data and close value":
    var runtime = NestOwlRuntime.init()
    runtime.dialogData = "Alatar"

    let data = runtime.evaluator.exec(parse("dialogData\n"))
    check data.kind == Text
    check data.text == "Alatar"

    let closeValue = runtime.evaluator.exec(parse("closeDialog \"applications\"\n"))
    check closeValue.kind == Text
    check closeValue.text == "applications"
    check runtime.requestQuit
    check runtime.dialogCloseValue == "applications"

    let requested = runtime.evaluator.exec(parse("requestCloseDialog \"files\"\n"))
    check requested.kind == Text
    check requested.text == "files"
    check runtime.dialogCloseRequested
    check runtime.dialogCloseValue == "files"
    check runtime.evaluator.exec(parse("dialogClosing?\n")).isTruthy

  test "dialog result commands track completed child values":
    var runtime = NestOwlRuntime.init()
    runtime.dialogResults["start"] = "files"

    let result = runtime.evaluator.exec(parse("dialogResult \"start\"\n"))
    check result.kind == Text
    check result.text == "files"

    discard runtime.evaluator.exec(parse("clearDialogResult \"start\"\n"))
    let cleared = runtime.evaluator.exec(parse("dialogResult \"start\"\n"))
    check cleared.kind == Nothing

  test "menu result commands track completed child paths":
    var runtime = NestOwlRuntime.init()
    runtime.dialogResults["menu:main"] = "file.saveas"

    let result = runtime.evaluator.exec(parse("menuResult \"main\"\n"))
    check result.kind == Text
    check result.text == "file.saveas"

    discard runtime.evaluator.exec(parse("clearMenuResult \"main\"\n"))
    let cleared = runtime.evaluator.exec(parse("menuResult \"main\"\n"))
    check cleared.kind == Nothing

  test "menu result can drive event branches":
    var runtime = NestOwlRuntime.init()
    var ui = UI.init()
    ui.initContext(240, 80)
    ui.loadFont("font", "", 18)
    runtime.dialogResults["menu:duck:menubar"] = "file.open"

    runtime.render(ui, parse("""
state "root":
  menuAction = nothing
events:
  when (not (= (menuResult "duck:menubar") nothing)):
    set menuAction (menuResult "duck:menubar")
    when (= menuAction "file.open"):
      set menuAction "open clicked"
    clearMenuResult "duck:menubar"
"""))

    let action = runtime.get("menuAction")
    check action.kind == Text
    check action.text == "open clicked"
    check "menu:duck:menubar" notin runtime.dialogResults

  test "pickFile calls callback with selected path":
    let originalPickFileDialog = pickFileDialog
    pickFileDialog = proc(callback: PathSelectedProc) {.closure, raises: [].} =
      if not callback.isNil:
        callback("/tmp/example.txt")
    try:
      var runtime = NestOwlRuntime.init()
      var ui = UI.init()
      ui.initContext(240, 80)
      ui.loadFont("font", "", 18)

      runtime.render(ui, parse("""
state "root":
  picked = ""
fun pickedFile path:
  set picked path
events:
  when (= picked ""):
    pickFile pickedFile
"""))
      runtime.render(ui, parse("""
state "root":
  picked = ""
fun pickedFile path:
  set picked path
events:
  when (= picked ""):
    pickFile pickedFile
"""))

      let picked = runtime.get("picked")
      check picked.kind == Text
      check picked.text == "/tmp/example.txt"
    finally:
      pickFileDialog = originalPickFileDialog

  test "pickDirectory calls callback with selected path":
    let originalPickDirectoryDialog = pickDirectoryDialog
    pickDirectoryDialog = proc(callback: PathSelectedProc) {.closure, raises: [].} =
      if not callback.isNil:
        callback("/tmp/example-dir")
    try:
      var runtime = NestOwlRuntime.init()
      var ui = UI.init()
      ui.initContext(240, 80)
      ui.loadFont("font", "", 18)

      runtime.render(ui, parse("""
state "root":
  picked = ""
fun pickedDirectory path:
  set picked path
events:
  when (= picked ""):
    pickDirectory pickedDirectory
"""))
      runtime.render(ui, parse("""
state "root":
  picked = ""
fun pickedDirectory path:
  set picked path
events:
  when (= picked ""):
    pickDirectory pickedDirectory
"""))

      let picked = runtime.get("picked")
      check picked.kind == Text
      check picked.text == "/tmp/example-dir"
    finally:
      pickDirectoryDialog = originalPickDirectoryDialog

  test "pickFileEvent posts external event with selected path":
    let originalPickFileDialog = pickFileDialog
    pickFileDialog = proc(callback: PathSelectedProc) {.closure, raises: [].} =
      if not callback.isNil:
        callback("/tmp/event-file.txt")
    try:
      var runtime = NestOwlRuntime.init()
      var ui = UI.init()
      ui.initContext(240, 80)
      ui.loadFont("font", "", 18)

      runtime.render(ui, parse("""
state "root":
  picked = ""
  requested = false
events:
  when (external "file-picked"):
    set picked (pickResult "file-picked")
    clearPickResult "file-picked"
  when (= requested false):
    set requested true
    pickFileEvent "file-picked"
"""))
      runtime.render(ui, parse("""
state "root":
  picked = ""
  requested = false
events:
  when (external "file-picked"):
    set picked (pickResult "file-picked")
    clearPickResult "file-picked"
  when (= requested false):
    set requested true
    pickFileEvent "file-picked"
"""))

      let picked = runtime.get("picked")
      check picked.kind == Text
      check picked.text == "/tmp/event-file.txt"
      let cleared = runtime.evaluator.exec(parse("pickResult \"file-picked\"\n"))
      check cleared.kind == Nothing
    finally:
      pickFileDialog = originalPickFileDialog

  test "pickDirectoryEvent posts external event with selected path":
    let originalPickDirectoryDialog = pickDirectoryDialog
    pickDirectoryDialog = proc(callback: PathSelectedProc) {.closure, raises: [].} =
      if not callback.isNil:
        callback("/tmp/event-dir")
    try:
      var runtime = NestOwlRuntime.init()
      var ui = UI.init()
      ui.initContext(240, 80)
      ui.loadFont("font", "", 18)

      runtime.render(ui, parse("""
state "root":
  picked = ""
  requested = false
events:
  when (external "dir-picked"):
    set picked (pickResult "dir-picked")
    clearPickResult "dir-picked"
  when (= requested false):
    set requested true
    pickDirectoryEvent "dir-picked"
"""))
      runtime.render(ui, parse("""
state "root":
  picked = ""
  requested = false
events:
  when (external "dir-picked"):
    set picked (pickResult "dir-picked")
    clearPickResult "dir-picked"
  when (= requested false):
    set requested true
    pickDirectoryEvent "dir-picked"
"""))

      let picked = runtime.get("picked")
      check picked.kind == Text
      check picked.text == "/tmp/event-dir"
    finally:
      pickDirectoryDialog = originalPickDirectoryDialog

  test "editor text can be read and replaced from owl":
    var runtime = NestOwlRuntime.init()
    var ui = UI.init()
    ui.initContext(240, 120)
    ui.loadFont("font", "", 18)

    runtime.render(ui, parse("""
state "root":
  editorID = (id "test" "editor")
  captured = ""
  cursorBefore = 0
  cursorAfter = 0
events:
  when (= captured ""):
    setEditorText editorID "first\nsecond"
    setEditorCursor editorID 3
    set cursorBefore (editorCursor editorID)
    setEditorText editorID "first\nsecond"
    set cursorAfter (editorCursor editorID)
    set captured (editorText editorID)
panel (id "root"):
  width = fill
  height = fill
  editor editorID:
    width = fill
    height = fill
    syntax = "nim"
"""))

    let captured = runtime.get("captured")
    check captured.kind == Text
    check captured.text == "first\nsecond"
    check runtime.get("cursorBefore").number == 3
    check runtime.get("cursorAfter").number == 3

  test "owl menubar renders top menus and arbitrary menu item bodies":
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
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      let runtime = NestOwlRuntime.init()
      var ui = UI.init()
      ui.initContext(360, 160)
      ui.loadFont("font", "", 18)

      runtime.renderLayoutOnly(ui, parse(
          """
menuBar (id "main"):
  width = fill
  height = fixed 28
  menu "file" "File":
    menuItem "saveas" "Save As":
      row (id "saveas-row"):
        width = fill
        height = fit
        label (id "saveas-label") "Save As":
          width = fill
          height = fit
    menuDivider
    menuItem "quit" "Quit"
  menu "edit" "Edit":
    menuItem "copy" "Copy"
"""), 360, 160)

      check not runtime.hasError
      check ui.widget(ui.id("main")).frame.width == 360
      check ui.widget(ui.id("main", "file")).frame.width > 0
      check ui.widget(ui.id("main", "edit")).frame.x > ui.widget(ui.id("main",
          "file")).frame.x
    finally:
      fontRelays = originalFontRelays

  test "open menu popover does not move menubar items":
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
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      let source = parse("""
column (id "root"):
  width = fill
  height = fill
  menuBar (id "main"):
    width = fill
    height = fixed 28
    menu "file" "File":
      menuItem "open" "Open"
    menu "build" "Build":
      menuItem "compile" "Compile"
    menu "breakpoints" "Breakpoints":
      menuItem "add" "Add"
  label (id "below") "below":
    width = fill
    height = fixed 24
""")
      var runtime = NestOwlRuntime.init()
      var ui = UI.init()
      ui.initContext(420, 180)
      ui.loadFont("font", "", 18)

      runtime.renderLayoutOnly(ui, source, 420, 180)
      let closedBuild = ui.widget(ui.id("main", "build")).frame
      let closedBreakpoints = ui.widget(ui.id("main", "breakpoints")).frame
      let closedBelow = ui.widget(ui.id("below")).frame

      runtime.openMenus["main"] = "breakpoints"
      ui = UI.init()
      ui.initContext(420, 180)
      ui.loadFont("font", "", 18)
      runtime.renderLayoutOnly(ui, source, 420, 180)

      check ui.widget(ui.id("main", "build")).frame.x == closedBuild.x
      check ui.widget(ui.id("main", "breakpoints")).frame.x ==
          closedBreakpoints.x
      check ui.widget(ui.id("below")).frame.y == closedBelow.y
      check ui.widgetFrame(ui.id("main", "item", "0")).ok
    finally:
      fontRelays = originalFontRelays

  test "owl menubar emits clicked item full path":
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
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      var runtime = NestOwlRuntime.init()
      var ui = UI.init()
      ui.initContext(360, 160)
      ui.loadFont("font", "", 18)
      let source = parse("""
state "root":
  menuID = (id "duck" "menubar")
menuBar menuID:
  width = fill
  height = fixed 28
  menu "file" "File":
    menuItem "open" "Open"
    menuItem "saveas" "Save As"
""")

      runtime.openMenus["duck:menubar"] = "file"
      runtime.render(ui, source)
      let located = ui.widgetFrame(ui.id("duck:menubar", "item", "0"))
      check located.ok
      let itemFrame = located.frame
      ui.mouseMove(itemFrame.x.toInt + 2, itemFrame.y.toInt + 2)
      ui.mouseDown()
      runtime.render(ui, source)
      runtime.render(ui, source)

      check runtime.dialogResults.getOrDefault("menu:duck:menubar") == "file.open"
    finally:
      fontRelays = originalFontRelays

  test "menu popovers consume clicks before widgets beneath them":
    let runtime = NestOwlRuntime.init()
    var ui = UI.init()
    ui.initContext(360, 160)
    ui.loadFont("font", "", 18)
    let source = parse("""
state "root":
  presses = 0
  buttonID = (id "behind-menu")
events:
  when (clicked buttonID):
    += presses 1
column (id "root"):
  width = fill
  height = fill
  menuBar (id "blocking-menu"):
    width = fill
    height = fixed 28
    menu "file" "File":
      menuItem "open" "Open"
  button buttonID "Behind menu":
    width = fill
    height = fixed 40
""")

    runtime.openMenus["blocking-menu"] = "file"
    runtime.render(ui, source)
    runtime.render(ui, source)
    let located = ui.widgetFrame(ui.id("blocking-menu", "item", "0"))
    check located.ok
    let itemFrame = located.frame
    ui.mouseMove(itemFrame.x.toInt + 2, itemFrame.y.toInt + 2)
    ui.mouseDown()
    runtime.render(ui, source)
    ui.mouseUp()
    runtime.render(ui, source)

    check runtime.get("presses").number == 0
    check runtime.dialogResults.getOrDefault("menu:blocking-menu") == "file.open"

  test "duck file open menu action is handled":
    let originalFontRelays = fontRelays
    let originalPickFileDialog = pickFileDialog
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
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    let duckFile = getTempDir() / "duck-open-editor.txt"
    let duckContent = "alpha\nbeta"
    writeFile(duckFile, duckContent)
    pickFileDialog = proc(callback: PathSelectedProc) {.closure, raises: [].} =
      if not callback.isNil:
        callback(duckFile)
    try:
      var runtime = NestOwlRuntime.init()
      var ui = UI.init()
      ui.initContext(360, 180)
      ui.loadFont("font", "", 18)
      let source = parse(readFile("apps/duck/main.owl"), "apps/duck/main.owl")

      runtime.openMenus["duck:menubar"] = "file"
      runtime.render(ui, source)
      let located = ui.widgetFrame(ui.id("duck:menubar", "item", "1"))
      check located.ok
      let itemFrame = located.frame
      ui.mouseMove(itemFrame.x.toInt + 2, itemFrame.y.toInt + 2)
      ui.mouseDown()
      runtime.render(ui, source)
      ui.mouseUp()
      runtime.render(ui, source)
      runtime.render(ui, source)
      runtime.render(ui, source)

      let action = runtime.get("menuAction")
      check action.kind == Text
      check action.text == duckFile
      let picked = runtime.get("pickedFile")
      check picked.kind == Text
      check picked.text == duckFile
      check runtime.get("activeBuffer").number == 1
      let editorText = runtime.evaluator.exec(parse("editorText \"duck:buffer:2\"\n"))
      check editorText.kind == Text
      check editorText.text == duckContent
    finally:
      pickFileDialog = originalPickFileDialog
      fontRelays = originalFontRelays

  test "menu popover item pattern closes with full item path":
    let runtime = NestOwlRuntime.init()
    let itemID = UI.init().id("menu", "item", "0")
    var ui = UI.init()
    ui.initContext(260, 80)
    ui.loadFont("font", "", 18)

    runtime.evaluator.native "clicked":
      discard layout
      discard bodyNodes
      if arguments.len == 0:
        return boolean(false)
      let value = env.eval(arguments[0])
      boolean(value.kind == Native and value.native of WidgetIDValue and
        WidgetIDValue(value.native).value == itemID)

    runtime.render(ui, parse("""
events:
  when (clicked (id "menu" "item" "0")):
    closeDialog "file.saveas"
card (id "menu" "panel"):
  width = fill
  height = fill
  menuItem (id "menu" "item" "0"):
    width = fill
    height = fit
    label (id "menu" "label" "0") "Save As":
      width = fill
      height = fit
"""))

    check runtime.requestQuit
    check runtime.dialogCloseValue == "file.saveas"

  test "owl events can test pressed keys":
    let runtime = NestOwlRuntime.init()
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
    var runtime = NestOwlRuntime.init()

    expect EvaluatorError:
      discard runtime.evaluator.exec(parse("openDialog \"missing\" \"./does-not-exist\"\n"))

  test "owl render errors do not add inline error dialogs":
    let runtime = NestOwlRuntime.init()
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
    let primary = diagnosticLocation("/tmp/app/main.owl:12:7: error: missing field")
    check primary.ok
    check primary.path == "/tmp/app/main.owl"
    check primary.line == 12
    check primary.column == 7

    let frame = diagnosticLocation("  at /tmp/app/main.owl:20:3 in render")
    check frame.ok
    check frame.path == "/tmp/app/main.owl"
    check frame.line == 20
    check frame.column == 3

  test "date intrinsics expose minimal calendar math":
    var runtime = NestOwlRuntime.init()

    check runtime.evaluator.exec(parse("date 2026 7 18\n")).text == "2026-07-18"
    check runtime.evaluator.exec(parse("date-year \"2026-07-18\"\n")).number == 2026
    check runtime.evaluator.exec(parse("date-month \"2026-07-18\"\n")).number == 7
    check runtime.evaluator.exec(parse("date-day \"2026-07-18\"\n")).number == 18
    check runtime.evaluator.exec(parse("date-days-in-month 2024 2\n")).number == 29
    check runtime.evaluator.exec(parse("date-first-weekday 2026 7\n")).number == 3
    check runtime.evaluator.exec(parse("date-month-title 2026 7\n")).text == "July 2026"
    check runtime.evaluator.exec(parse("date-add-months \"2026-03-31\" -1\n")).text == "2026-02-28"

  test "sway workspace intrinsics parse state and quote activation commands":
    var runtime = NestOwlRuntime.init()

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

  test "owl calendar widget renders and selects previous month":
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
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      let runtime = NestOwlRuntime.init()
      var ui = UI.init()
      ui.initContext(320, 320)
      ui.loadFont("font", "", 18)

      runtime.renderLayoutOnly(ui, parse(
          """
state "root":
  selectedDate = "2026-07-18"
import "apps/layerShellBar/components/calendar.owl"
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
state "root":
  selectedDate = "2026-07-18"
import "apps/layerShellBar/components/calendar.owl"
dateSelector "cal" selectedDate
"""))

      check runtime.get("selectedDate").text == "2026-06-18"
    finally:
      fontRelays = originalFontRelays

  test "owl calendar widget signals selected day clicks":
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
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      let runtime = NestOwlRuntime.init()
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
state "root":
  selectedDate = "2026-07-18"
  clickedDate = nothing
import "apps/layerShellBar/components/calendar.owl"
dateSelectorWithSignal "cal" selectedDate clickedDate
"""))

      check runtime.get("selectedDate").text == "2026-07-18"
      check runtime.get("clickedDate").text == "2026-07-18"
    finally:
      fontRelays = originalFontRelays

  test "nim can render an owl-defined widget":
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
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      let runtime = NestOwlRuntime.init()
      runtime.evaluator.env.define("selectedDate", text("2026-07-18"))
      var ui = UI.init()
      ui.initContext(320, 320)
      ui.loadFont("font", "", 18)

      ui.beginLayout(320, 320)
      runtime.renderWidget(
        ui,
        "apps/layerShellBar/components/calendar.owl",
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

  test "owl animation block attaches to custom widget subtree":
    let runtime = NestOwlRuntime.init()
    var ui = UI.init()
    ui.initContext(240, 120)
    ui.loadFont("font", "", 18)
    ui.setDrawTicks(2000)

    runtime.render(ui, parse("""
animation (id "panel"):
  duration = 120
  curve = "easeOut"
  fromOpacity = 0
  maxOpacity = 0.8
  fromScale = 0.9
  card (id "panel"):
    width = fixed 120
    height = fixed 48
    label (id "text") "Animated":
      width = fit
      height = fit
"""))

    let value = ui.animationValue(ui.id("panel"))
    let panel = ui.widgetFrame(ui.id("panel"))
    check not runtime.hasError
    check panel.ok
    check panel.frame.width == 120
    check value.progress == 0.0
    check value.opacity < 0.000001

    ui.setDrawTicks(2200)
    runtime.render(ui, parse("""
animation (id "panel"):
  duration = 120
  curve = "easeOut"
  fromOpacity = 0
  maxOpacity = 0.8
  fromScale = 0.9
  card (id "panel"):
    width = fixed 120
    height = fixed 48
    label (id "text") "Animated":
      width = fit
      height = fit
"""))
    check ui.animationValue(ui.id("panel")).opacity == 0.8
