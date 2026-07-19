import std/[cmdline, json, os, osproc, sets, strutils]

import nest/[ui, resources, palette, dialogs]
export ui
export dialogs

import fungus
export fungus

import uirelays/[backend, input, screen]
export input, screen

import nest/layerShellSdl3Driver
export LayerShellConfig, LayerShellLayer, LayerShellEdge, LayerShellKeyboardMode
export dockTop, dockBottom, dockLeft, dockRight

import crow/[parser, syntax]
import nest/crowdsl

type AppConfig* = object
  title: string
  width, height: int
  layerShell*: bool
  layerShellConfig*: LayerShellConfig

type FramePacer = object
  firstFrame: bool

type ProjectConfig = object
  main: string
  title: string
  width, height: int
  layerShell: string
  namespace: string
  exclusiveZone: int
  marginTop, marginRight, marginBottom, marginLeft: int

type DialogAnchor = object
  ok: bool
  x, y, width, height: float64
  windowWidth, windowHeight: int

proc init*(T: typedesc[AppConfig], width = 800, height = 600, title = "Nest"): T =
  T(
    title: title,
    width: width,
    height: height,
    layerShellConfig: layerShellSdl3Driver.dockTop(height.Positive),
  )

proc layerShell*(cfg: AppConfig, config: LayerShellConfig): AppConfig =
  result = cfg
  result.layerShell = true
  result.layerShellConfig = config

proc dockTop*(
    T: typedesc[AppConfig], height: Positive, title = "Nest", namespace = "nest"
): T =
  AppConfig.init(width = 1, height = height, title = title).layerShell(
    layerShellSdl3Driver.dockTop(height, namespace)
  )

proc dockBottom*(
    T: typedesc[AppConfig], height: Positive, title = "Nest", namespace = "nest"
): T =
  AppConfig.init(width = 1, height = height, title = title).layerShell(
    layerShellSdl3Driver.dockBottom(height, namespace)
  )

proc dockLeft*(
    T: typedesc[AppConfig], width: Positive, title = "Nest", namespace = "nest"
): T =
  AppConfig.init(width = width, height = 1, title = title).layerShell(
    layerShellSdl3Driver.dockLeft(width, namespace)
  )

proc dockRight*(
    T: typedesc[AppConfig], width: Positive, title = "Nest", namespace = "nest"
): T =
  AppConfig.init(width = width, height = 1, title = title).layerShell(
    layerShellSdl3Driver.dockRight(width, namespace)
  )

proc overlayDialog*(
    T: typedesc[AppConfig],
    width: Positive,
    height: Positive,
    title = "Nest Dialog",
    namespace = "nest-dialog",
): T =
  AppConfig.init(width = width, height = height, title = title).layerShell(
    LayerShellConfig(
      namespace: namespace,
      layer: LayerOverlay,
      anchors: {},
      exclusiveZone: -1,
      keyboard: KeyboardOnDemand,
    )
  )

proc init(T: typedesc[FramePacer]): T =
  T(firstFrame: true)

proc takeFirstFrame(pacer: var FramePacer): bool =
  if pacer.firstFrame:
    pacer.firstFrame = false
    result = true

proc initWindow*(cfg: AppConfig): ScreenLayout =
  if cfg.layerShell:
    layerShellSdl3Driver.layerShellConfig = cfg.layerShellConfig
    initLayerShellSdl3Driver()
  else:
    initBackend()
  crowdsl.runtimeWake = layerShellSdl3Driver.wakeEventLoop
  result = createWindow(cfg.width, cfg.height)
  setWindowTitle(cfg.title)

proc defaultProjectConfig(): ProjectConfig =
  ProjectConfig(
    main: "main.nest",
    title: "Nest",
    width: 800,
    height: 600,
    layerShell: "none",
    namespace: "nest",
    exclusiveZone: low(int),
    marginTop: 0,
    marginRight: 0,
    marginBottom: 0,
    marginLeft: 0,
  )

proc parseProjectInt(value: string, fallback: int): int =
  try:
    parseInt(value.strip)
  except ValueError:
    fallback

proc loadProjectConfig(projectDir: string): ProjectConfig =
  result = defaultProjectConfig()
  let configPath = projectDir / "project.nest"
  if not fileExists(configPath):
    return

  var program: SyntaxNode
  try:
    program = parse(readFile(configPath), configPath)
  except CatchableError:
    return

  proc valueString(node: SyntaxNode): tuple[ok: bool, value: string] =
    case node.kind
    of String:
      (true, node.stringValue)
    of Symbol:
      (true, node.symbol)
    of Command:
      if node.arguments.len == 0 and node.layout == NoLayout and
          node.callee.kind == Symbol:
        (true, node.callee.symbol)
      else:
        (false, "")
    else:
      (false, "")

  for node in program.statements:
    if node.kind != Binding:
      continue
    let key = node.bindingSymbol.normalize
    let parsed = node.value.valueString
    if not parsed.ok:
      continue
    let valueStr = parsed.value

    case key
    of "main":
      result.main = valueStr
    of "title":
      result.title = valueStr
    of "width":
      result.width = parseProjectInt(valueStr, result.width)
    of "height":
      result.height = parseProjectInt(valueStr, result.height)
    of "layershell", "layer":
      result.layerShell = valueStr.normalize
    of "namespace":
      result.namespace = valueStr
    of "exclusivezone":
      result.exclusiveZone = parseProjectInt(valueStr, result.exclusiveZone)
    of "margintop":
      result.marginTop = parseProjectInt(valueStr, result.marginTop)
    of "marginright":
      result.marginRight = parseProjectInt(valueStr, result.marginRight)
    of "marginbottom":
      result.marginBottom = parseProjectInt(valueStr, result.marginBottom)
    of "marginleft":
      result.marginLeft = parseProjectInt(valueStr, result.marginLeft)
    else:
      discard

proc positive(value: int): Positive =
  max(value, 1).Positive

proc numberField(node: JsonNode; name: string): float64 =
  if node.kind == JObject and node.hasKey(name):
    let field = node[name]
    if field.kind == JInt:
      return field.getInt.float64
    if field.kind == JFloat:
      return field.getFloat
  0.0

proc intField(node: JsonNode; name: string): int =
  numberField(node, name).int

proc parseDialogAnchor(value: string): DialogAnchor =
  if value.len == 0:
    return
  try:
    let node = parseJson(value)
    result = DialogAnchor(
      ok: node.kind == JObject,
      x: numberField(node, "x"),
      y: numberField(node, "y"),
      width: numberField(node, "width"),
      height: numberField(node, "height"),
      windowWidth: intField(node, "windowWidth"),
      windowHeight: intField(node, "windowHeight"),
    )
    result.ok = result.ok and result.windowWidth > 0 and result.windowHeight > 0
  except JsonParsingError:
    result = DialogAnchor()
  except KeyError:
    result = DialogAnchor()

proc edgeDistance(value: float64): int32 =
  max(value.int, 0).int32

proc clampDistance(value, size, limit: float64): float64 =
  value.clamp(0.0, max(limit - size, 0.0))

proc applyDialogAnchor(app: AppConfig; anchor: DialogAnchor): AppConfig =
  result = app
  if not anchor.ok:
    return

  let
    centerX = anchor.x + anchor.width / 2.0
    centerY = anchor.y + anchor.height / 2.0
    leftZone = centerX < anchor.windowWidth.float64 / 3.0
    rightZone = centerX > anchor.windowWidth.float64 * 2.0 / 3.0
    topZone = centerY <= anchor.windowHeight.float64 / 2.0
    horizontalParent = anchor.windowWidth >= anchor.windowHeight
    desiredLeft =
      if leftZone:
        anchor.x
      elif rightZone:
        anchor.x + anchor.width - app.width.float64
      else:
        centerX - app.width.float64 / 2.0
    popupLeft = clampDistance(desiredLeft, app.width.float64, anchor.windowWidth.float64)

  result.layerShell = true
  result.layerShellConfig.layer = LayerOverlay
  result.layerShellConfig.exclusiveZone = 0
  result.layerShellConfig.marginTop = 0
  result.layerShellConfig.marginRight = 0
  result.layerShellConfig.marginBottom = 0
  result.layerShellConfig.marginLeft = 0
  result.layerShellConfig.anchors = {}

  if topZone:
    result.layerShellConfig.anchors.incl EdgeTop
    result.layerShellConfig.marginTop =
      if horizontalParent:
        0'i32
      else:
        edgeDistance(anchor.y + anchor.height)
  else:
    result.layerShellConfig.anchors.incl EdgeBottom
    result.layerShellConfig.marginBottom =
      if horizontalParent:
        0'i32
      else:
        edgeDistance(anchor.windowHeight.float64 - anchor.y)

  if leftZone:
    result.layerShellConfig.anchors.incl EdgeLeft
    result.layerShellConfig.marginLeft = edgeDistance(popupLeft)
  elif rightZone:
    result.layerShellConfig.anchors.incl EdgeRight
    result.layerShellConfig.marginRight =
      edgeDistance(anchor.windowWidth.float64 - popupLeft - app.width.float64)
  else:
    result.layerShellConfig.anchors.incl EdgeLeft
    result.layerShellConfig.marginLeft = edgeDistance(popupLeft)

proc appConfig(config: ProjectConfig): AppConfig =
  proc withExclusiveZone(app: AppConfig): AppConfig =
    result = app
    if config.exclusiveZone != low(int):
      result.layerShellConfig.exclusiveZone = config.exclusiveZone.int32
    result.layerShellConfig.marginTop = config.marginTop.int32
    result.layerShellConfig.marginRight = config.marginRight.int32
    result.layerShellConfig.marginBottom = config.marginBottom.int32
    result.layerShellConfig.marginLeft = config.marginLeft.int32

  case config.layerShell.normalize
  of "top":
    AppConfig.dockTop(positive(config.height), config.title, config.namespace).withExclusiveZone
  of "bottom":
    AppConfig.dockBottom(positive(config.height), config.title, config.namespace).withExclusiveZone
  of "left":
    AppConfig.dockLeft(positive(config.width), config.title, config.namespace).withExclusiveZone
  of "right":
    AppConfig.dockRight(positive(config.width), config.title, config.namespace).withExclusiveZone
  of "top-left", "topleft":
    AppConfig
      .init(
        width = positive(config.width),
        height = positive(config.height),
        title = config.title,
      )
      .layerShell(
        LayerShellConfig(
          namespace: config.namespace,
          layer: LayerTop,
          anchors: {EdgeTop, EdgeLeft},
          exclusiveZone: config.exclusiveZone.int32,
          marginTop: config.marginTop.int32,
          marginRight: config.marginRight.int32,
          marginBottom: config.marginBottom.int32,
          marginLeft: config.marginLeft.int32,
          keyboard: KeyboardOnDemand,
        )
      )
  of "top-right", "topright":
    AppConfig
      .init(
        width = positive(config.width),
        height = positive(config.height),
        title = config.title,
      )
      .layerShell(
        LayerShellConfig(
          namespace: config.namespace,
          layer: LayerTop,
          anchors: {EdgeTop, EdgeRight},
          exclusiveZone: config.exclusiveZone.int32,
          marginTop: config.marginTop.int32,
          marginRight: config.marginRight.int32,
          marginBottom: config.marginBottom.int32,
          marginLeft: config.marginLeft.int32,
          keyboard: KeyboardOnDemand,
        )
      )
  of "top-center", "top-middle", "topcenter", "topmiddle":
    AppConfig
      .init(
        width = positive(config.width),
        height = positive(config.height),
        title = config.title,
      )
      .layerShell(
        LayerShellConfig(
          namespace: config.namespace,
          layer: LayerTop,
          anchors: {EdgeTop},
          exclusiveZone: config.exclusiveZone.int32,
          marginTop: config.marginTop.int32,
          marginRight: config.marginRight.int32,
          marginBottom: config.marginBottom.int32,
          marginLeft: config.marginLeft.int32,
          keyboard: KeyboardOnDemand,
        )
      )
  else:
    AppConfig.init(
      width = max(config.width, 1), height = max(config.height, 1), title = config.title
    )

proc projectMainPath(projectDir: string, config: ProjectConfig): string =
  if config.main.isAbsolute:
    config.main.normalizedPath
  else:
    (projectDir / config.main).normalizedPath

proc writeProjectFile(path, content: string) =
  if fileExists(path):
    quit("Refusing to overwrite existing file: " & path)
  writeFile(path, content)

proc generateProject(projectDir: string) =
  let dir = projectDir.normalizedPath
  if not dirExists(dir):
    createDir(dir)

  writeProjectFile(
    dir / "project.nest",
    """main = "main.nest"
title = "Nest App"
width = 800
height = 600
layerShell = "none"
namespace = "nest-app"
exclusiveZone = -1
marginTop = 0
marginRight = 0
marginBottom = 0
marginLeft = 0
""",
  )
  writeProjectFile(
    dir / "main.nest",
    """define:
  count = 0
  rootID = id
  titleID = id
  decrementID = (id "decrement")
  incrementID = (id "increment")
events:
  when (clicked decrementID):
    -= count 1
  when (clicked incrementID):
    += count 1
panel rootID:
  width = fill
  height = fill
  gap = 12.0
  padding = 16.0
  alignItems = AlignCenter
  justifyContent = JustifyCenter
  label titleID "Counter":
    width = fit
    height = fit
  row (id "controls"):
    width = fit
    height = fit
    gap = 8
    button decrementID "-":
      width = (fixed 32)
      height = fit
    label (id "count") count:
      width = (fixed 80)
      height = fit
    button incrementID "+":
      width = (fixed 32)
      height = fit
""",
  )
  echo "Created Nest project in " & dir

proc usage(): string =
  """Usage:
  nest --project DIR
  nest run DIR
  nest dialog DIR [DATA] [RESULT_PATH] [ANCHOR_JSON]
  nest error-dialog MESSAGE
  nest generate [DIR]

Project files:
  DIR/project.nest  optional project config
  DIR/main.nest     default UI entrypoint
"""

proc textFromEvent(chars: array[4, char]): string =
  for ch in chars:
    if ch == '\0':
      break
    result.add(ch)

proc handleEvent(
    e: Event,
    running: var bool,
    updateContext: var UpdateContext,
    drawContext: var DrawContext,
) =
  case e.kind
  of QuitEvent, WindowCloseEvent:
    running = false
  of MouseMoveEvent:
    updateContext.mouseX = e.x
    updateContext.mouseY = e.y
    drawContext.mouseX = e.x
    drawContext.mouseY = e.y
  of MouseDownEvent:
    let last = updateContext.mouseLeftDown
    updateContext.mouseLeftDown = true
    updateContext.mouseLeftPressed = not last
  of MouseUpEvent:
    updateContext.mouseLeftDown = false
    updateContext.mouseLeftPressed = false
  of WindowResizeEvent:
    updateContext.windowWidth = max(e.x, 0)
    updateContext.windowHeight = max(e.y, 0)
    drawContext.windowWidth = updateContext.windowWidth
    drawContext.windowHeight = updateContext.windowHeight
  of KeyDownEvent:
    updateContext.keyInputs.add KeyInput(key: e.key, mods: e.mods)
  of TextInputEvent:
    let text = textFromEvent(e.text)
    if text.len > 0:
      updateContext.textInputs.add text
  of MouseWheelEvent:
    updateContext.mouseWheelX += e.x.toFloat
    updateContext.mouseWheelY += e.y.toFloat
  else:
    discard

proc handleEvent(e: Event, running: var bool, ui: var UI) =
  case e.kind
  of QuitEvent, WindowCloseEvent:
    running = false
  of MouseMoveEvent:
    ui.mouseMove(e.x, e.y)
  of MouseDownEvent:
    ui.mouseDown()
    ui.requestRedrawAfter(0)
  of MouseUpEvent:
    ui.mouseUp()
    ui.requestRedrawAfter(0)
  of WindowResizeEvent:
    ui.resizeWindow(e.x, e.y)
    ui.markAllDirty()
  of KeyDownEvent:
    ui.keyDown(e.key, e.mods)
    ui.requestRedrawAfter(0)
  of TextInputEvent:
    ui.textInput(textFromEvent(e.text))
    ui.requestRedrawAfter(0)
  of MouseWheelEvent:
    ui.mouseWheel(e.x.toFloat, e.y.toFloat)
    ui.requestRedrawAfter(0)
  else:
    discard

proc closeCrowErrorDialog(app: NestCrowApp) =
  if app.errorDialogProcess != nil:
    if app.errorDialogProcess.running:
      app.errorDialogProcess.terminate
    app.errorDialogProcess.close
    app.errorDialogProcess = nil

proc pollCrowErrorDialog(app: NestCrowApp) =
  if app.errorDialogProcess != nil and not app.errorDialogProcess.running:
    app.errorDialogProcess.close
    app.errorDialogProcess = nil
    if app.errorDialogMessage.len > 0:
      app.runtime.dismissedError = app.errorDialogMessage

proc launchCrowErrorDialog(app: NestCrowApp, message: string) =
  if message.len == 0 or app.runtime.dismissedError == message:
    return
  app.pollCrowErrorDialog()
  if app.errorDialogProcess != nil and app.errorDialogMessage == message:
    return
  app.closeCrowErrorDialog()
  try:
    app.errorDialogProcess = startProcess(
      getAppFilename(), args = @["error-dialog", message], options = {poUsePath}
    )
    app.errorDialogMessage = message
  except OSError:
    discard
  except IOError:
    discard

template crowErrorDialogBody(
    ui: var UI, message: string, copied: var bool, running: var bool
) =
  ui.events:
    if ui.clicked(ui.id("_nest_error_copy")):
      putClipboardText(message)
      copied = true
    if ui.clicked(ui.id("_nest_error_close")):
      running = false
  ui.card(
    ui.id("_nest_error_dialog"),
    cfg(
      width = fixed(ui.windowWidth.toFloat),
      height = fixed(ui.windowHeight.toFloat),
      padding = 12,
      gap = 10,
      alignItems = AlignStretch,
    ),
  ):
    ui.dialogHeader(
      ui.id("_nest_error_header"),
      cfg(
        width = fill(), height = fit(), padding = 8, gap = 8, alignItems = AlignCenter
      ),
    ):
      ui.label(ui.id("_nest_error_title"), "Crow error", fill(), fit())
      discard ui.button(ui.id("_nest_error_close"), "Close", fit(), fit())
    ui.column(
      ui.id("_nest_error_body"),
      cfg(
        width = fill(), height = fill(), padding = 8, gap = 4, alignItems = AlignStretch
      ),
    ):
      for index, line in crowErrorLines(message, maxLines = 8):
        renderCrowErrorLine(ui, index, line, fill(), fit())
      if copied:
        ui.label(ui.id("_nest_error_copied"), "Copied to clipboard", fill(), fit())
    ui.row(
      ui.id("_nest_error_actions"),
      cfg(width = fill(), height = fit(), gap = 8, justifyContent = JustifyEnd),
    ):
      discard ui.button(ui.id("_nest_error_copy"), "Copy", fit(), fit())

proc drawCrowErrorDialog(
    ui: var UI, message: string, copied: var bool, running: var bool
) =
  ui.layout:
    crowErrorDialogBody(ui, message, copied, running)

proc layoutCrowErrorDialogForTest*(
    ui: var UI, message: string, width, height: int
): bool =
  var
    copied = false
    running = true
  ui.initContext(width, height)
  ui.beginLayout(width, height)
  crowErrorDialogBody(ui, message, copied, running)
  ui.applyIntrinsicSizes(ui.resources)
  ui.endLayout()

template application*(cfg: AppConfig, blk: untyped) =
  let window {.inject.} = cfg.initWindow()
  var
    running {.inject.} = true
    updateContext {.inject.} =
      UpdateContext(windowWidth: window.width, windowHeight: window.height)
    drawContext {.inject.} = DrawContext(
      resources: Resources.new(),
      palette: Palette.init(),
      windowWidth: window.width,
      windowHeight: window.height,
      dirtyAll: true,
    )
  drawContext.resources.loadFont("font", "", 18)
  var framePacer = FramePacer.init()
  while running:
    var e = Event()
    let inputFlags =
      if drawContext.focusedWidget != InvalidWidgetID:
        {WantTextInput}
      else:
        {}
    var shouldRender = framePacer.takeFirstFrame()
    let frameEvent =
      if shouldRender:
        false
      else:
        input.waitEvent(e, -1, inputFlags)
    if frameEvent:
      shouldRender = true
    elif not shouldRender:
      continue
    updateContext.keyInputs.setLen(0)
    updateContext.textInputs.setLen(0)
    updateContext.mouseWheelX = 0
    updateContext.mouseWheelY = 0
    updateContext.submittedWidgets.clear()
    if frameEvent:
      handleEvent(e, running, updateContext, drawContext)
    while pollEvent(e, inputFlags):
      handleEvent(e, running, updateContext, drawContext)
    drawContext.ticks = input.getTicks()
    blk
    updateContext.mouseLeftPressed = false
    refresh()
  shutdown()

template application*(cfg: AppConfig, ui: var UI, blk: untyped) =
  let window {.inject.} = cfg.initWindow()
  var running {.inject.} = true
  ui.initContext(window.width, window.height)
  ui.loadFont("font", "", 18)
  var framePacer = FramePacer.init()
  while running:
    var e = Event()
    let inputFlags =
      if ui.wantsTextInput():
        {WantTextInput}
      else:
        {}
    var shouldRender = framePacer.takeFirstFrame()
    let waitMs = ui.redrawDelayMs()
    let frameEvent =
      if shouldRender:
        false
      else:
        input.waitEvent(e, waitMs, inputFlags)
    if frameEvent:
      shouldRender = true
    elif waitMs >= 0:
      shouldRender = true
      ui.clearRedrawRequest()
    if not shouldRender:
      continue
    ui.beginInputFrame()
    if frameEvent:
      handleEvent(e, running, ui)
    while pollEvent(e, inputFlags):
      handleEvent(e, running, ui)
    ui.setDrawTicks(input.getTicks())
    blk
    ui.finishInputFrame()
    if ui.redrewFrame():
      refresh()
  shutdown()

proc runCrowErrorDialog(message: string) =
  var ui = UI.init()
  var copied = false
  application AppConfig.overlayDialog(
    width = 800.Positive,
    height = 600.Positive,
    title = "Crow Error",
    namespace = "nest-crow-error-dialog",
  ), ui:
    drawCrowErrorDialog(ui, message, copied, running)

proc runProject(
    projectDir: string,
    dialogData = "",
    dialogMode = false,
    dialogResultPath = "",
    dialogAnchor = "",
): string =
  discard dialogMode
  let dir = projectDir.normalizedPath
  if not dirExists(dir):
    quit("Nest project directory does not exist: " & projectDir)

  let config = loadProjectConfig(dir)
  let mainPath = projectMainPath(dir, config)
  if not fileExists(mainPath):
    quit("Nest project main file does not exist: " & mainPath)

  var ui = UI.init()
  let app = NestCrowApp.init(mainPath)
  app.runtime.dialogData = dialogData
  application appConfig(config).applyDialogAnchor(parseDialogAnchor(dialogAnchor)), ui:
    app.render(ui)
    if app.lastError.len > 0:
      app.launchCrowErrorDialog(app.lastError)
    else:
      app.pollCrowErrorDialog()
      app.closeCrowErrorDialog()
    if app.runtime.requestQuit:
      running = false
  result = app.runtime.dialogCloseValue
  app.runtime.closeDialogProcesses()
  app.closeCrowErrorDialog()

proc main() =
  let args = commandLineParams()
  if args.len == 0:
    quit(usage(), 1)
  case args[0]
  of "--project", "-p":
    if args.len < 2:
      quit(usage(), 1)
    discard runProject(args[1])
  of "run":
    if args.len < 2:
      quit(usage(), 1)
    discard runProject(args[1])
  of "dialog":
    if args.len < 2:
      quit(usage(), 1)
    let data =
      if args.len >= 3:
        args[2]
      else:
        ""
    let resultPath =
      if args.len >= 4:
        args[3]
      else:
        ""
    let anchor =
      if args.len >= 5:
        args[4]
      else:
        ""
    let value = runProject(
      args[1],
      dialogData = data,
      dialogMode = true,
      dialogResultPath = resultPath,
      dialogAnchor = anchor,
    )
    if resultPath.len > 0:
      writeFile(resultPath, value)
    elif value.len > 0:
      echo value
  of "error-dialog":
    if args.len < 2:
      quit(usage(), 1)
    runCrowErrorDialog(args[1])
  of "generate", "gen":
    let dir =
      if args.len >= 2:
        args[1]
      else:
        getCurrentDir()
    generateProject(dir)
  of "--help", "-h", "help":
    echo usage()
  else:
    quit(usage(), 1)

when isMainModule:
  main()
