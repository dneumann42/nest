import nest/[layout, widgets]
export widgets, layout
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
  var running = true
  while running:
    var e = Event()
    while pollEvent(e):
      case e.kind
      of QuitEvent, WindowCloseEvent:
        running = false
      else:
        discard
    blk
    refresh()
    sleep(16)
  shutdown()

when isMainModule:
  application AppConfig.init(title = "Nest Demo"):
    view wid("container"):
      panel wid("window"), Column:
        panel wid("toolbar"), Row, fixed(48):
          theme = theme.borderColor(color(255, 0, 0)).borderThickness(2)
        panel wid("body"), Row:
          theme = theme.borderColor(color(255, 255, 0)).borderThickness(2)
        panel wid("status"), Row, fixed(24):
          theme = theme.borderColor(color(255, 0, 255)).borderThickness(2)

    # fillRect(rect(0, 0, 100, 100), color(120, 150, 68))
