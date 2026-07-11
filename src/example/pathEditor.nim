import std/[os, strutils]

import ../nest

type PathEditor* = object
  paths: seq[string]
  newPath: LineInputState
  newPathID: WidgetID

proc getPathVariables(): seq[string] =
  let path = getEnv("PATH")
  result = path.split({':'})

proc init*(T: typedesc[PathEditor]): T =
  T(
    paths: getPathVariables(),
    newPath: LineInputState.new(""),
    newPathID: nextWidgetID(),
  )

proc pathListBoxItem(ui: var UI, item: string) =
  ui.row(nextWidgetID(), cfg(width = fill(), height = fit(), gap = 12.0)):
    ui.label(nextWidgetID(), item, fill(), fit())
    ui.button(nextWidgetID(), "Edit", fixed(120), fixed(24))
    ui.button(nextWidgetID(), "Delete", fixed(120), fixed(24))

proc pathListBox(ui: var UI, paths: var seq[string], header: proc(ui: var UI): void) =
  ui.panel(
    nextWidgetID(),
    cfg(
      width = prefer(800, min = 400),
      height = fit(),
      gap = 12.0,
      alignItems = AlignCenter,
      justifyContent = JustifyCenter,
    ),
  ):
    ui.header()
    for path in paths:
      ui.pathListBoxItem(path)

proc start() =
  var ui = UI.init()
  var app = PathEditor.init()
  application AppConfig.init(width = 1280, height = 720, title = "Path Editor"):
    ui.events:
      if drawContext.submitted(app.newPathID):
        discard

    ui.layout(updateContext, drawContext):
      ui.column(
        nextWidgetID(),
        cfg(
          width = fill(),
          height = fill(),
          gap = 12.0,
          alignItems = AlignCenter,
          justifyContent = JustifyCenter,
        ),
      ):
        ui.label(nextWidgetID(), "Paths", fit(), fit())

        let newPathID = app.newPathID
        ui.pathListBox(
          app.paths,
          header = proc(ui: var UI) =
            ui.row(nextWidgetID(), cfg(width = fill(), height = fit())):
              ui.lineInput(newPathID, app.newPath, fill(), fit())
              ui.button(nextWidgetID(), "New", fit(), fit()),
        )

when isMainModule:
  start()
