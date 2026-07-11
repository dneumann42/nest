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
        updateContext.mouseX = e.x
        updateContext.mouseY = e.y
        drawContext.windowWidth = e.x
        drawContext.windowHeight = e.y
      else:
        discard
    blk
    refresh()
    sleep(16)
  shutdown()

let
  Toolbar = nextWidgetID()
  Body = nextWidgetID()
  Sidebar = nextWidgetID()
  Content = nextWidgetID()
  Button1 = nextWidgetID()
  Button2 = nextWidgetID()
  Button3 = nextWidgetID()
  Button4 = nextWidgetID()
  Button5 = nextWidgetID()

proc start() =
  application AppConfig.init(title = "Nest Demo"):
    var ui = UI.init()

    ui.beginLayout(drawContext.windowWidth, drawContext.windowHeight)

    ui.column(16.0, 25.0):
      ui.row(nextWidgetID(), fill(), fixed(32), 12.0, 0.0):
        ui.button(nextWidgetID(), "Click ME", width = fixed(100), height = fixed(24))
        ui.button(nextWidgetID(), "Click AGAIN", width = fixed(120), height = fixed(24))

      ui.row(nextWidgetID(), fill(), fill(), 16.0, 0.0):
        ui.column(nextWidgetID(), fixed(260), fill(), 8.0, 0.0):
          ui.button(nextWidgetID(), "One", width = fill(), height = fixed(24))
          ui.button(nextWidgetID(), "Two", width = fill(), height = fixed(24))
        ui.spacer(nextWidgetID(), width = fill(), height = hug(24.0))
        ui.column(nextWidgetID(), prefer(100.0), fill(), 8.0, 0.0):
          ui.button(nextWidgetID(), "Content", width = fixed(140), height = fixed(24))

    ui.endLayout()
    ui.update(updateContext)
    ui.draw(drawContext)

when isMainModule:
  start()
