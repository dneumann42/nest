import nest/[ui, resources]
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
      resources: Resources.new(), windowWidth: cfg.width, windowHeight: cfg.height
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
      of WindowResizeEvent:
        updateContext.windowWidth = e.x
        updateContext.windowHeight = e.y
        drawContext.windowWidth = e.x
        drawContext.windowHeight = e.y
      else:
        discard
    blk
    refresh()
    sleep(16)
  shutdown()

proc start() =
  application AppConfig.init(width = 1100, height = 720, title = "Nest Layout Lab"):
    var ui = UI.init()
    ui.layout(updateContext, drawContext):
      ui.columnAligned(nextWidgetID(), w = fill(), h = fill(), alignItems = AlignCenter):
        ui.button(nextWidgetID(), "Nest", width = fixed(84), height = fixed(32))
        ui.button(nextWidgetID(), "Projects", width = fixed(104), height = fixed(28))
        ui.button(
          nextWidgetID(),
          "Tall",
          width = fixed(62),
          height = fixed(32),
          alignSelf = AlignEnd,
        )
        ui.spacer(nextWidgetID(), width = fill(), height = fixed(1))
        ui.button(
          nextWidgetID(), "Search", width = prefer(180, min = 120), height = fixed(28)
        )
        ui.button(
          nextWidgetID(),
          "Profile",
          width = fixed(96),
          height = fixed(24),
          alignSelf = AlignStart,
        )

when isMainModule:
  start()
