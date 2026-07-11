import std/[hashes, os, sets, strutils]

import ../nest

type
  PathWidget* =
    tuple[
      index: int,
      path: string,
      editButton, deleteButton, saveButton, cancelButton: WidgetID,
    ]
  PathEditor* = object
    paths: seq[string]
    newPath: LineInputState
    newPathID: WidgetID
    search: LineInputState
    searchID: WidgetID
    pathListBoxID: WidgetID
    pathLineEdit: LineInputState
    pathLineEditID: WidgetID
    pathLineEditing: int

const PathLineEditNone = -1

proc pathActionID(path: string, index: int, action: string): WidgetID =
  let hashed = uint64(!$hash(path & "\0" & $index & "\0" & action))
  WidgetID(0x8000_0000_0000_0000'u64 or hashed)

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
    pathLineEdit: LineInputState.new(""),
    pathLineEditID: nextWidgetID(),
    pathLineEditing: PathLineEditNone,
  )

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
    paths: var seq[string],
    pathLineEdit: LineInputState,
    pathLineEditID: WidgetID,
    pathLineEditing: var int,
    search: string,
    drawContext: DrawContext,
) =
  var pathWidgets = newSeq[PathWidget]()
  for idx, path in paths.pairs:
    if search.len > 0 and not path.contains(search):
      continue
    pathWidgets.add(
      (
        index: idx,
        path: path,
        editButton: pathActionID(path, idx, "edit"),
        deleteButton: pathActionID(path, idx, "delete"),
        saveButton: pathActionID(path, idx, "save"),
        cancelButton: pathActionID(path, idx, "cancel"),
      )
    )

  ui.events:
    var deleteIndexes: HashSet[int]
    for idx, widget in pathWidgets.pairs:
      if drawContext.active(widget.editButton):
        pathLineEditing = widget.index
        pathLineEdit.text = widget.path
        pathLineEdit.cursor = widget.path.len
      if drawContext.active(widget.saveButton) and pathLineEditing == widget.index:
        paths[widget.index] = pathLineEdit.text
        pathLineEditing = PathLineEditNone
      if drawContext.active(widget.cancelButton) and pathLineEditing == widget.index:
        pathLineEditing = PathLineEditNone
      if drawContext.active(widget.deleteButton):
        deleteIndexes.incl widget.index
    if deleteIndexes.len > 0:
      var kept: seq[string]
      for idx, path in paths.pairs:
        if idx notin deleteIndexes:
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
    for widget in pathWidgets:
      let
        index = widget.index
        path = widget.path
        editButton = widget.editButton
        deleteButton = widget.deleteButton
        saveButton = widget.saveButton
        cancelButton = widget.cancelButton
      if pathLineEditing == index:
        ui.row(
          nextWidgetID(),
          cfg(width = fill(), height = fit(), gap = 12.0, alignItems = AlignCenter),
        ):
          ui.lineInput(pathLineEditID, pathLineEdit, fill(), fixed(28))
          ui.button(cancelButton, "Cancel", fixed(80), fixed(24))
          ui.button(saveButton, "Save", fixed(64), fixed(24))
      else:
        ui.pathListBoxItem(path) do(ui: var UI):
          ui.button(editButton, "Edit", fit(), fit())
          ui.button(deleteButton, "Delete", fit(), fit())

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
        if drawContext.active(newButton):
          let newPath = app.newPath.text
          app.paths.add(newPath)
        if drawContext.active(browseButton):
          browseFolder proc(path: string) =
            app.newPath.text = path
            app.newPath.cursor = path.len
        if drawContext.active(saveButton):
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
          app.pathListBoxID, app.paths, app.pathLineEdit, app.pathLineEditID,
          app.pathLineEditing, app.search.text, drawContext,
        )
        ui.row(
          nextWidgetID(), cfg(width = prefer(800, min = 400), height = fit(), gap = 8.0)
        ):
          ui.lineInput(app.newPathID, app.newPath, fill(), fit())
          ui.button(browseButton, "Browse", fit(), fit())
          ui.button(newButton, "New", fit(), fit())

when isMainModule:
  start()
