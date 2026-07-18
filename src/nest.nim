import std/[cmdline, os, sets, strutils]

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

type ProjectConfig = object
  main: string
  title: string
  width, height: int
  layerShell: string
  namespace: string

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

proc initWindow*(cfg: AppConfig): ScreenLayout =
  if cfg.layerShell:
    layerShellSdl3Driver.layerShellConfig = cfg.layerShellConfig
    initLayerShellSdl3Driver()
  else:
    initBackend()
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
    program = parse(readFile(configPath))
  except CatchableError:
    return

  proc valueString(node: SyntaxNode): tuple[ok: bool, value: string] =
    case node.kind
    of String:
      (true, node.stringValue)
    of Symbol:
      (true, node.symbol)
    of Command:
      if node.arguments.len == 0 and node.layout == NoLayout and node.callee.kind == Symbol:
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
    else:
      discard

proc positive(value: int): Positive =
  max(value, 1).Positive

proc appConfig(config: ProjectConfig): AppConfig =
  case config.layerShell.normalize
  of "top":
    AppConfig.dockTop(positive(config.height), config.title, config.namespace)
  of "bottom":
    AppConfig.dockBottom(positive(config.height), config.title, config.namespace)
  of "left":
    AppConfig.dockLeft(positive(config.width), config.title, config.namespace)
  of "right":
    AppConfig.dockRight(positive(config.width), config.title, config.namespace)
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
    )
  drawContext.resources.loadFont("font", "", 18)
  while running:
    var e = Event()
    updateContext.keyInputs.setLen(0)
    updateContext.textInputs.setLen(0)
    updateContext.mouseWheelX = 0
    updateContext.mouseWheelY = 0
    updateContext.submittedWidgets.clear()
    let inputFlags =
      if drawContext.focusedWidget != InvalidWidgetID:
        {WantTextInput}
      else:
        {}
    while pollEvent(e, inputFlags):
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
    blk
    updateContext.mouseLeftPressed = false
    refresh()
    input.sleep(16)
  shutdown()

template application*(cfg: AppConfig, ui: var UI, blk: untyped) =
  let window {.inject.} = cfg.initWindow()
  var running {.inject.} = true
  ui.initContext(window.width, window.height)
  ui.loadFont("font", "", 18)
  while running:
    var e = Event()
    ui.beginInputFrame()
    let inputFlags =
      if ui.wantsTextInput():
        {WantTextInput}
      else:
        {}
    while pollEvent(e, inputFlags):
      case e.kind
      of QuitEvent, WindowCloseEvent:
        running = false
      of MouseMoveEvent:
        ui.mouseMove(e.x, e.y)
      of MouseDownEvent:
        ui.mouseDown()
      of MouseUpEvent:
        ui.mouseUp()
      of WindowResizeEvent:
        ui.resizeWindow(e.x, e.y)
      of KeyDownEvent:
        ui.keyDown(e.key, e.mods)
      of TextInputEvent:
        ui.textInput(textFromEvent(e.text))
      of MouseWheelEvent:
        ui.mouseWheel(e.x.toFloat, e.y.toFloat)
      else:
        discard
    blk
    ui.finishInputFrame()
    refresh()
    input.sleep(16)
  shutdown()

proc runProject(projectDir: string) =
  let dir = projectDir.normalizedPath
  if not dirExists(dir):
    quit("Nest project directory does not exist: " & projectDir)

  let config = loadProjectConfig(dir)
  let mainPath = projectMainPath(dir, config)
  if not fileExists(mainPath):
    quit("Nest project main file does not exist: " & mainPath)

  var ui = UI.init()
  let app = NestCrowApp.init(mainPath)
  application appConfig(config), ui:
    app.render(ui)

proc main() =
  let args = commandLineParams()
  echo args
  case args[0]
  of "--project", "-p":
    if args.len < 2:
      quit(usage(), 1)
    runProject(args[1])
  of "run":
    if args.len < 2:
      quit(usage(), 1)
    runProject(args[1])
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
