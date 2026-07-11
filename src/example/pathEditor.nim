import std/[os, strutils, sequtils]

import ../nest

type PathEditor* = object
  paths: seq[string]
  newPath: LineInputState
  newPathID: WidgetID
  search: LineInputState
  searchID: WidgetID
  pathListBoxID: WidgetID

proc getPathVariables(): seq[string] =
  let path = getEnv("PATH")
  result = path.split({':'})

proc init*(T: typedesc[PathEditor]): T =
  T(
    paths: getPathVariables(),
    newPath: LineInputState.new(""),
    newPathID: nextWidgetID(),
    search: LineInputState.new(""),
    searchID: nextWidgetID(),
    pathListBoxID: nextWidgetID(),
  )

proc pathListBoxItem(ui: var UI, item: string) =
  ui.row(nextWidgetID(), cfg(width = fill(), height = fit(), gap = 12.0)):
    ui.label(nextWidgetID(), item, fill(), fit())
    ui.button(nextWidgetID(), "Edit", fixed(120), fixed(24))
    ui.button(nextWidgetID(), "Delete", fixed(120), fixed(24))

proc pathListBox(ui: var UI, id: WidgetID, paths: var seq[string], search: string) =
  ui.panel(
    id,
    cfg(
      width = prefer(800, min = 400),
      height = fill(),
      gap = 12.0,
      alignItems = AlignStretch,
      justifyContent = JustifyStart,
      scrollX = true,
      scrollY = true,
    ),
  ):
    for path in paths.filterIt(search.len == 0 or it.contains(search)):
      ui.pathListBoxItem(path)

proc start() =
  var ui = UI.init()
  var app = PathEditor.init()

  let
    newButton = nextWidgetID()
    browseButton = nextWidgetID()

  application AppConfig.init(width = 640, height = 480, title = "Path Editor"):
    ui.layout(updateContext, drawContext):
      ui.events:
        if drawContext.active(newButton):
          let newPath = app.newPath.text
          app.paths.add(newPath)
        if drawContext.active(browseButton):
          discard

      ui.column(
        nextWidgetID(),
        cfg(width = fill(), height = fill(), gap = 12.0, alignItems = AlignCenter),
      ):
        ui.label(nextWidgetID(), "Paths", fit(), fit())
        ui.row(nextWidgetID(), cfg(width = prefer(800, min = 400), height = fit())):
          ui.label(nextWidgetID(), "Search", fit(), fit())
          ui.lineInput(app.searchID, app.search, fill(), fit())
        ui.pathListBox(app.pathListBoxID, app.paths, app.search.text)
        ui.row(nextWidgetID(), cfg(width = prefer(800, min = 400), height = fit())):
          ui.lineInput(app.newPathID, app.newPath, fill(), fit())
          ui.button(newButton, "Browse", fit(), fit())
          ui.button(newButton, "New", fit(), fit())

when isMainModule:
  start()
