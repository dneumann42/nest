import std/[os, sets, strutils]

import ../nest

type
  PathEntry = object
    id: uint64
    path: string

  PathEditor* = object
    paths: seq[PathEntry]
    nextPathID: uint64
    newPath: LineInputState
    newPathID: WidgetID
    search: LineInputState
    searchID: WidgetID
    pathListBoxID: WidgetID
    pathLineEdit: EditLineState

proc getPathVariables(): seq[string] =
  let path = getEnv("PATH")
  result = path.split({':'})

proc addPath(editor: var PathEditor, path: string) =
  editor.paths.add PathEntry(id: editor.nextPathID, path: path)
  inc editor.nextPathID

proc init*(T: typedesc[PathEditor]): T =
  result = T(
    nextPathID: 1,
    newPath: LineInputState.new(""),
    newPathID: nextWidgetID(),
    search: LineInputState.new(""),
    searchID: nextWidgetID(),
    pathListBoxID: nextWidgetID(),
    pathLineEdit: editLineState(),
  )
  for path in getPathVariables():
    result.addPath(path)

proc pathListBoxItem(ui: var UI, item: string, actions: proc(ui: var UI)) =
  ui.row(
    nextWidgetID(),
    cfg(
      width = fill(),
      height = fit(),
      gap = 12.0,
      alignItems = AlignCenter,
      justifyContent = JustifyCenter,
    ),
  ):
    ui.label(nextWidgetID(), item, fill(), fit())
    ui.actions()

proc pathListBox(
    ui: var UI,
    id: WidgetID,
    paths: var seq[PathEntry],
    pathLineEdit: var EditLineState,
    search: string,
) =
  let rows = listItems[PathEntry](
    paths,
    proc(entry: PathEntry, index: int): string = $entry.id,
    proc(entry: PathEntry, index: int): bool =
      search.len == 0 or entry.path.contains(search),
  )

  ui.events:
    var deleteIndexes: HashSet[int]
    for row in rows:
      ui.scope(row.key):
        if ui.clicked(ui.id("edit")):
          pathLineEdit.beginEdit(row.key, row.value.path)
        if ui.clicked(ui.id("save")) and pathLineEdit.editing(row.key):
          paths[row.index].path = pathLineEdit.saveEdit()
        if ui.clicked(ui.id("cancel")) and pathLineEdit.editing(row.key):
          pathLineEdit.cancelEdit()
        if ui.clicked(ui.id("delete")):
          deleteIndexes.incl row.index
    if deleteIndexes.len > 0:
      if pathLineEdit.editing:
        for row in rows:
          if row.index in deleteIndexes and pathLineEdit.editing(row.key):
            pathLineEdit.cancelEdit()
      var kept: seq[PathEntry]
      for index, path in paths.pairs:
        if index notin deleteIndexes:
          kept.add path
      paths = kept

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
    for row in rows:
      ui.scope(row.key):
        if pathLineEdit.editing(row.key):
          ui.row(
            ui.id("edit-row"),
            cfg(width = fill(), height = fit(), gap = 12.0, alignItems = AlignCenter),
          ):
            ui.lineInput(pathLineEdit.inputID, pathLineEdit.input, fill(), fixed(28))
            ui.button(ui.id("cancel"), "Cancel", fit(), fit())
            ui.button(ui.id("save"), "Save", fit(), fit())
        else:
          ui.pathListBoxItem(row.value.path) do(ui: var UI):
            ui.button(ui.id("edit"), "Edit", fit(), fit())
            ui.button(ui.id("delete"), "Delete", fit(), fit())
        discard

proc start() =
  var ui = UI.init()
  var app = PathEditor.init()

  let
    newButton = nextWidgetID()
    browseButton = nextWidgetID()
    saveButton = nextWidgetID()

  application AppConfig.init(width = 640, height = 480, title = "Path Editor"):
    ui.layout(updateContext, drawContext):
      ui.events:
        if ui.clicked(newButton):
          let newPath = app.newPath.text
          app.addPath(newPath)
        if ui.clicked(browseButton):
          browseFolder proc(path: string) =
            app.newPath.text = path
            app.newPath.cursor = path.len
        if ui.clicked(saveButton):
          discard

      ui.column(
        nextWidgetID(),
        cfg(
          width = fill(),
          height = fill(),
          gap = 8.0,
          padding = 16.0,
          alignItems = AlignCenter,
        ),
      ):
        ui.row(
          nextWidgetID(),
          cfg(width = fill(), height = fit(), gap = 8.0, alignItems = AlignCenter),
        ):
          ui.label(nextWidgetID(), "Paths", fill(), fit())
          ui.button(saveButton, "Save", fit(), fit())

        ui.row(
          nextWidgetID(),
          cfg(
            width = prefer(800, min = 400),
            height = fit(),
            gap = 8.0,
            alignItems = AlignCenter,
          ),
        ):
          ui.label(nextWidgetID(), "Search", fit(), fit())
          ui.lineInput(app.searchID, app.search, fill(), fit())
        ui.pathListBox(
          app.pathListBoxID, app.paths, app.pathLineEdit, app.search.text
        )
        ui.row(
          nextWidgetID(), cfg(width = prefer(800, min = 400), height = fit(), gap = 8.0)
        ):
          ui.lineInput(app.newPathID, app.newPath, fill(), fit())
          ui.button(browseButton, "Browse", fit(), fit())
          ui.button(newButton, "New", fit(), fit())

when isMainModule:
  start()
