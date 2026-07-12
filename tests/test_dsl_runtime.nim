import std/[os, sets, streams, tables, unittest]

import nest/[layouts, palette, resources, ui]
import nest_dsl/[nodes, reader, runtime]

proc parseDsl(source: string): Program =
  let stream = newStringStream(source)
  defer: stream.close()
  let read = readProgram(stream)
  doAssert read.ok, $read.error
  Program(read.node)

proc parseDslFile(path: string): Program =
  let stream = newFileStream(path)
  require stream != nil
  defer: stream.close()
  let read = readProgram(stream)
  require read.ok
  Program(read.node)

suite "DSL runtime":
  test "define binds once":
    let program = parseDsl("define:\n  buttonID (id)\n")
    var ui = UI.init()
    let runtime = DslRuntime.init()
    let defines = Block(lines: @[program.body.lines[0]])

    runtime.renderBlock(ui, defines)
    let first = runtime.widgetID("buttonID")
    runtime.renderBlock(ui, defines)

    check first != InvalidWidgetID
    check runtime.widgetID("buttonID") == first

  test "call keyword assignments evaluate":
    let program = parseDsl("define:\n  width (prefer 800: min = 400)\n")
    var ui = UI.init()
    let runtime = DslRuntime.init()

    runtime.renderBlock(ui, Block(lines: @[program.body.lines[0]]))

    let width = runtime.get("width")
    check width.kind == Size
    check width.sizePolicyValue.kind == Prefer
    check width.sizePolicyValue.value == 800
    check width.sizePolicyValue.min == 400

  test "command defines a script command with scoped arguments":
    let program = parseDsl(
      "command addPath input:\n" &
        "  capture input\n" &
        "addPath \"from-dsl\"\n",
    )
    var ui = UI.init()
    let runtime = DslRuntime.init()
    var captured = ""
    runtime.registerCommand(
      "capture",
      proc(
          runtime: DslRuntime,
          ui: var UI,
          command: Command,
          args: seq[DslValue],
          body: Block,
      ): DslValue =
        discard command
        discard body
        if args.len > 0:
          captured = $args[0]
        nilValue(),
    )

    runtime.renderBlock(ui, program.body)

    check captured == "from-dsl"
    check runtime.get("input").kind == None

  test "list and file utilities mutate and persist lines":
    let output = "/tmp/nest-dsl-runtime-lines.txt"
    removeFile(output)
    let program = parseDsl(
      "define:\n" &
        "  output \"" & output & "\"\n" &
        "  paths (split \"alpha:gamma\" \":\")\n" &
      "appendLine paths \"delta\"\n" &
      "insertLine paths 1 \"beta\"\n" &
      "writeLines output paths\n" &
      "define:\n" &
        "  loaded (loadLines output)\n",
    )
    var ui = UI.init()
    let runtime = DslRuntime.init()

    runtime.renderBlock(ui, program.body)

    check runtime.get("paths").kind == List
    check runtime.get("paths").listValue.items == @["alpha", "beta", "gamma", "delta"]
    check runtime.get("loaded").kind == List
    check runtime.get("loaded").listValue.items == @["alpha", "beta", "gamma", "delta"]
    check readFile(output) == "alpha\nbeta\ngamma\ndelta"
    removeFile(output)

  test "imports modules and exposes exported commands":
    let modulePath = "/tmp/nest-dsl-module-actions.nest"
    writeFile(modulePath, "command greet value:\n  capture value\nexport greet\n")
    let program = parseDsl("import \"" & modulePath & "\"\ngreet \"hello\"\n")
    var ui = UI.init()
    let runtime = DslRuntime.init()
    var captured = ""
    runtime.registerCommand(
      "capture",
      proc(
          runtime: DslRuntime,
          ui: var UI,
          command: Command,
          args: seq[DslValue],
          body: Block,
      ): DslValue =
        discard command
        discard body
        if args.len > 0:
          captured = $args[0]
        nilValue(),
    )

    runtime.renderBlock(ui, program.body)

    check captured == "hello"
    check "greet" in runtime.exported
    removeFile(modulePath)

  test "DslApp tracks imported files for hot reload":
    let rootPath = "/tmp/nest-dsl-hot-root.nest"
    let modulePath = "/tmp/nest-dsl-hot-module.nest"
    writeFile(rootPath, "import \"nest-dsl-hot-module.nest\"\n")
    writeFile(modulePath, "export ready\n")
    var ui = UI.init()
    let app = DslApp.init(rootPath)

    app.render(ui)
    check app.runtime.loadedFiles.hasKey(rootPath.normalizedPath)
    check app.runtime.loadedFiles.hasKey(modulePath.normalizedPath)
    check not app.runtime.dependenciesChanged()

    os.sleep(1100)
    writeFile(modulePath, "export ready changed\n")

    check app.runtime.dependenciesChanged()
    removeFile(rootPath)
    removeFile(modulePath)

  test "exec runs asynchronously and captures stdout":
    let program = parseDsl("exec \"printf dsl-runtime\"\n")
    var ui = UI.init()
    let runtime = DslRuntime.init()

    runtime.renderBlock(ui, program.body)
    for _ in 0 ..< 50:
      runtime.pollExec()
      if runtime.exec.isNil or not runtime.exec.running:
        break
      os.sleep(20)

    check not runtime.exec.isNil
    check not runtime.exec.running
    check runtime.exec.output == "dsl-runtime"

  test "path editor DSL files parse":
    check parseDslFile("docs/dsl").body.lines.len > 0
    check parseDslFile("example/pathEditor/pathEditor.nest").body.lines.len > 0
    check parseDslFile("example/layerShellBar/layerShellBar.nest").body.lines.len > 0

  test "path editor renders through Nest modules":
    var ui = UI.init()
    ui.initContext(640, 480)
    ui.loadFont("font", "", 18)
    let app = DslApp.init("example/pathEditor/pathEditor.nest")

    app.render(ui)

    check app.lastError == ""
    check not app.runtime.hasError
    check "pathListBox" in app.runtime.exported
    check app.runtime.get("paths").kind == List

  test "path editor row enters edit mode on click":
    let program = parseDsl(
      "define:\n" &
        "  paths (split \"alpha:beta:gamma\" \":\")\n" &
        "  search (LineInputState \"\")\n" &
        "  pathLineEdit (EditLineState)\n" &
        "events:\n" &
        "  forLines paths item index key search:\n" &
        "    scope key:\n" &
        "      when (clicked (id \"edit\")):\n" &
        "        beginEdit pathLineEdit key item\n" &
        "column (id):\n" &
        "  panel (id \"list\"):\n" &
        "    width = (prefer 800: min = 400)\n" &
        "    height = (fill)\n" &
        "    forLines paths item index key search:\n" &
        "      scope key:\n" &
        "        when (editing pathLineEdit key):\n" &
        "          row (id \"edit-row\"):\n" &
        "            lineInput (editInputID pathLineEdit) (editInput pathLineEdit):\n" &
        "              width = (fill)\n" &
        "              height = (fixed 28)\n" &
        "            button (id \"cancel\") \"Cancel\":\n" &
        "              width = (fit)\n" &
        "              height = (fit)\n" &
        "            button (id \"save\") \"Save\":\n" &
        "              width = (fit)\n" &
        "              height = (fit)\n" &
        "        when (not (editing pathLineEdit key)):\n" &
        "          row (id \"row\"):\n" &
        "            label (id \"label\") item:\n" &
        "              width = (fill)\n" &
        "              height = (fit)\n" &
        "            button (id \"edit\") \"Edit\":\n" &
        "              width = (fit)\n" &
        "              height = (fit)\n",
    )

    var ui = UI.init()
    var updateContext = UpdateContext(windowWidth: 640, windowHeight: 480)
    var drawContext = DrawContext(
      resources: Resources.new(), palette: Palette.init(), windowWidth: 640, windowHeight: 480
    )
    drawContext.resources.loadFont("font", "", 18)
    let runtime = DslRuntime.init()

    ui.layout(updateContext, drawContext):
      runtime.renderBlock(ui, program.body)

    var betaEditID: WidgetID
    ui.scope(listKey(1, "beta")):
      betaEditID = ui.id("edit")
    drawContext.activeWidgets.incl betaEditID

    ui.layout(updateContext, drawContext):
      runtime.renderBlock(ui, program.body)

    check runtime.get("pathLineEdit").kind == EditInput
    check runtime.get("pathLineEdit").editLineValue.editing(listKey(1, "beta"))

  test "layer shell bar renders through Nest modules":
    var ui = UI.init()
    ui.initContext(1280, 34)
    ui.loadFont("font", "", 18)
    let app = DslApp.init("example/layerShellBar/layerShellBar.nest")

    app.render(ui)

    check app.lastError == ""
    check not app.runtime.hasError
    check app.runtime.widgetID("openButton") != InvalidWidgetID
    check app.runtime.widgetID("quitButton") != InvalidWidgetID
