import nest/[ui, resources, palette]
export ui

import fungus
export fungus

import uirelays

type AppConfig* = object
  title: string
  width, height: int

proc init*(T: typedesc[AppConfig], width = 800, height = 600, title = "Nest"): T =
  T(title: title, width: width, height: height)

proc initWindow*(cfg: AppConfig): ScreenLayout =
  result = createWindow(cfg.width, cfg.height)
  setWindowTitle(cfg.title)

template application*(cfg: AppConfig, blk: untyped) =
  let window {.inject.} = cfg.initWindow()
  var
    running {.inject.} = true
    updateContext {.inject.} =
      UpdateContext(windowWidth: cfg.width, windowHeight: cfg.height)
    drawContext {.inject.} = DrawContext(
      resources: Resources.new(),
      palette: Palette.init(),
      windowWidth: cfg.width,
      windowHeight: cfg.height,
    )
  drawContext.resources.loadFont("font", "", 18)
  while running:
    var e = Event()
    while pollEvent(e):
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
        updateContext.windowWidth = e.x
        updateContext.windowHeight = e.y
        drawContext.windowWidth = e.x
        drawContext.windowHeight = e.y
      else:
        discard
    blk
    updateContext.mouseLeftPressed = false
    refresh()
    sleep(16)
  shutdown()

const
  CenterStage = WidgetID(101)
  CounterPanel = WidgetID(102)
  TitleLabel = WidgetID(103)
  ValueLabel = WidgetID(104)
  ControlsRow = WidgetID(105)
  DecrementButton = WidgetID(106)
  ResetButton = WidgetID(107)
  IncrementButton = WidgetID(108)

type
  AppModel = object
    title = "Nest Counter"
    counter: CounterModel

  CounterModel = object
    count = 0
    changed = 0
    timesReset = 0

proc layoutCounter(ui: var UI, drawContext: DrawContext, counter: var CounterModel) =
  ui.events:
    if drawContext.active(DecrementButton):
      dec counter.count
    if drawContext.active(ResetButton):
      counter.count = 0
    if drawContext.active(IncrementButton):
      inc counter.count

  ui.panelJustified(
    CounterPanel, fixed(360), fixed(220), 18.0, 24.0, AlignCenter, JustifyCenter
  ):
    ui.label(TitleLabel, "Counter", width = fixed(120), height = fixed(28))
    ui.label(ValueLabel, $counter.count, width = fixed(120), height = fixed(44))
    ui.rowAlignedJustified(
      ControlsRow, fill(), fixed(40), 12.0, 0.0, AlignCenter, JustifyCenter
    ):
      ui.button(DecrementButton, "-", width = fixed(72), height = fixed(32))
      ui.button(ResetButton, "Reset", width = fixed(96), height = fixed(32))
      ui.button(IncrementButton, "+", width = fixed(72), height = fixed(32))

proc start() =
  var ui = UI.init()
  var app = AppModel()

  application AppConfig.init(width = 720, height = 480, title = app.title):
    ui.layout(updateContext, drawContext):
      ui.center(CenterStage, fill(), fill()):
        ui.layoutCounter(drawContext, app.counter)

when isMainModule:
  start()
