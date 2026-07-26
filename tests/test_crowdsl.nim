import std/[os, strutils, tables, unittest]

import crow
import nest/[crowdsl, input, projectConfig, resources, ui]
import nest/[coords, screen]

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

  test "imports are loaded once per runtime":
    let dir = getTempDir() / "nest-crow-import-once-test"
    createDir(dir)
    writeFile(dir / "module.nest", """
fun importedLabel:
  label (id "imported") "Imported":
    width = fit
    height = fit
""")

    let runtime = NestCrowRuntime.init()
    var ui = UI.init()
    ui.initContext(300, 120)
    ui.loadFont("font", "", 18)

    let source = """
import "module.nest"
importedLabel
"""
    let before = registeredSourceCount()
    runtime.render(ui, parse(source, dir / "main.nest"))
    let afterFirst = registeredSourceCount()
    runtime.render(ui, parse(source, dir / "main.nest"))

    check afterFirst == before + 2
    check registeredSourceCount() == afterFirst

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

  test "shellQuote and copyText expose shell-safe clipboard actions":
    let runtime = NestCrowRuntime.init()
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
        check ui.widget(ui.id("bar-media", "art")).frame.width == 32
        check ui.widget(ui.id("bar", "cpu")).frame.width > 0
        check ui.widget(ui.id("bar", "memory")).frame.width > 0
        check ui.widget(ui.id("bar", "storage")).frame.width > 0
        check ui.widget(ui.id("bar", "notifications")).frame.width > 0
        check ui.widget(ui.id("bar", "network")).frame.width > 0

      let mediaApp = NestCrowApp.init("apps/layerShellBar/media/main.nest")
      var mediaUi = UI.init()
      mediaUi.initContext(760, 400)
      mediaUi.loadFont("font", "", 18)

      mediaApp.runtime.renderLayoutOnly(mediaUi, mediaApp.program, 760, 400)

      check mediaApp.runtime.lastError == ""
      if mediaApp.runtime.lastError == "":
        let artworkFrame = mediaUi.widget(mediaUi.id("media", "artwork")).frame
        let tableFrame = mediaUi.widget(mediaUi.id("media", "metadata-table")).frame
        let detailsFrame = mediaUi.widget(mediaUi.id("media", "details")).frame
        check artworkFrame.height == 240
        check tableFrame.width > 0
        check detailsFrame.x > artworkFrame.x + artworkFrame.width
        check tableFrame.x >= detailsFrame.x

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

  test "menu result commands track completed child paths":
    var runtime = NestCrowRuntime.init()
    runtime.dialogResults["menu:main"] = "file.saveas"

    let result = runtime.evaluator.exec(parse("menuResult \"main\"\n"))
    check result.kind == Text
    check result.text == "file.saveas"

    discard runtime.evaluator.exec(parse("clearMenuResult \"main\"\n"))
    let cleared = runtime.evaluator.exec(parse("menuResult \"main\"\n"))
    check cleared.kind == Nothing

  test "menu result can drive event branches":
    var runtime = NestCrowRuntime.init()
    var ui = UI.init()
    ui.initContext(240, 80)
    ui.loadFont("font", "", 18)
    runtime.dialogResults["menu:duck:menubar"] = "file.open"

    runtime.render(ui, parse("""
define:
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
      var runtime = NestCrowRuntime.init()
      var ui = UI.init()
      ui.initContext(240, 80)
      ui.loadFont("font", "", 18)

      runtime.render(ui, parse("""
define:
  picked = ""
fun pickedFile path:
  set picked path
events:
  when (= picked ""):
    pickFile pickedFile
"""))
      runtime.render(ui, parse("""
define:
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
      var runtime = NestCrowRuntime.init()
      var ui = UI.init()
      ui.initContext(240, 80)
      ui.loadFont("font", "", 18)

      runtime.render(ui, parse("""
define:
  picked = ""
fun pickedDirectory path:
  set picked path
events:
  when (= picked ""):
    pickDirectory pickedDirectory
"""))
      runtime.render(ui, parse("""
define:
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
      var runtime = NestCrowRuntime.init()
      var ui = UI.init()
      ui.initContext(240, 80)
      ui.loadFont("font", "", 18)

      runtime.render(ui, parse("""
define:
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
define:
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
      var runtime = NestCrowRuntime.init()
      var ui = UI.init()
      ui.initContext(240, 80)
      ui.loadFont("font", "", 18)

      runtime.render(ui, parse("""
define:
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
define:
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

  test "editor text can be read and replaced from crow":
    var runtime = NestCrowRuntime.init()
    var ui = UI.init()
    ui.initContext(240, 120)
    ui.loadFont("font", "", 18)

    runtime.render(ui, parse("""
define:
  editorID = (id "test" "editor")
  captured = ""
events:
  when (= captured ""):
    setEditorText editorID "first\nsecond"
    set captured (editorText editorID)
panel (id "root"):
  width = fill
  height = fill
  editor editorID:
    width = fill
    height = fill
"""))

    let captured = runtime.get("captured")
    check captured.kind == Text
    check captured.text == "first\nsecond"

  test "crow menubar renders top menus and arbitrary menu item bodies":
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
      ui.initContext(360, 160)
      ui.loadFont("font", "", 18)

      runtime.renderLayoutOnly(ui, parse("""
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
      check ui.widget(ui.id("main", "edit")).frame.x > ui.widget(ui.id("main", "file")).frame.x
    finally:
      fontRelays = originalFontRelays

  test "crow menubar emits clicked item full path":
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
      var runtime = NestCrowRuntime.init()
      var ui = UI.init()
      ui.initContext(360, 160)
      ui.loadFont("font", "", 18)
      let source = parse("""
define:
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
      drawText: proc(f: Font; x, y: int; text: string; fg, bg: Color): TextExtent =
        TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    let duckFile = getTempDir() / "duck-open-editor.txt"
    let duckContent = "alpha\nbeta"
    writeFile(duckFile, duckContent)
    pickFileDialog = proc(callback: PathSelectedProc) {.closure, raises: [].} =
      if not callback.isNil:
        callback(duckFile)
    try:
      var runtime = NestCrowRuntime.init()
      var ui = UI.init()
      ui.initContext(360, 180)
      ui.loadFont("font", "", 18)
      let source = parse(readFile("apps/duck/main.nest"), "apps/duck/main.nest")

      runtime.openMenus["duck:menubar"] = "file"
      runtime.render(ui, source)
      let located = ui.widgetFrame(ui.id("duck:menubar", "item", "1"))
      check located.ok
      let itemFrame = located.frame
      ui.mouseMove(itemFrame.x.toInt + 2, itemFrame.y.toInt + 2)
      ui.mouseDown()
      runtime.render(ui, source)
      runtime.render(ui, source)
      runtime.render(ui, source)
      runtime.render(ui, source)

      let action = runtime.get("menuAction")
      check action.kind == Text
      check action.text == duckFile
      let picked = runtime.get("pickedFile")
      check picked.kind == Text
      check picked.text == duckFile
      let editorText = runtime.evaluator.exec(parse("editorText \"duck:editor\"\n"))
      check editorText.kind == Text
      check editorText.text == duckContent
    finally:
      pickFileDialog = originalPickFileDialog
      fontRelays = originalFontRelays

  test "menu popover item pattern closes with full item path":
    let runtime = NestCrowRuntime.init()
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
