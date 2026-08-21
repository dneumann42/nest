## Component gallery: every widget Nest ships, in one Nim application.
##
## Run it with `nimble gallery` from the repository root. Every portion of the
## interface is a `widget` declaration and the state follows
## Model/Msg/update/view, so the application doubles as a worked example: see
## docs/ui.org.

import std/[os, sets, strutils]

import nest
import nest/coords

const
  AssetPath = (currentSourcePath().parentDir /
    ".." / "layerShellBar" / "assets" / "nomicon-small.png").normalizedPath
  TabLabels = [
    "Text", "Buttons", "Inputs", "Editors", "Tables", "Mesh", "Overlays"
  ]
  ComboOptions = ["Solid", "Dashed", "Dotted"]

type
  MsgKind* = enum
    SelectTab
    ToggleCheckbox
    SetVolume
    SetBalance
    SetAccent
    SelectOption
    OpenMenu
    CloseMenu
    OpenModal
    CloseModal
    Bump
    Note

  Msg* = object
    case kind*: MsgKind
    of SelectTab, SelectOption:
      index*: int
    of SetVolume, SetBalance:
      value*: float64
    of SetAccent:
      color*: Color
    of OpenMenu, Note:
      text*: string
    else:
      discard

  Model* = object
    tab*: int
    subscribed: bool
    volume: float64
    balance: float64
    accent: Color
    option: int
    clicks: int
    openMenu*: string
    modalOpen*: bool
    lastEvent*: string
    name: LineInputState
    source: EditorState
    mesh: Mesh2DState

proc initModel*(): Model =
  result = Model(
    volume: 0.65,
    balance: 0.5,
    accent: color(79, 185, 154),
    option: 1,
    lastEvent: "ready",
    name: LineInputState.new("nest"),
    source: EditorState.new(
      "proc main() =\n  var ui = UI.init()\n  echo ui.windowWidth\n"
    ),
  )
  result.mesh = Mesh2DState(
    points:
      @[
        Mesh2DPoint(x: 0.25, y: 0.25),
        Mesh2DPoint(x: 0.75, y: 0.25),
        Mesh2DPoint(x: 0.75, y: 0.75),
        Mesh2DPoint(x: 0.25, y: 0.75),
      ],
    triangles: @[[0, 1, 2], [0, 2, 3]],
    viewZoom: 1.0,
    viewCenterX: 0.5,
    viewCenterY: 0.5,
    altDragSensitivity: 0.25,
    altDragSnapStep: 0.05,
  )

proc update*(model: var Model, msg: Msg) =
  case msg.kind
  of SelectTab:
    model.tab = msg.index
    model.lastEvent = "tab " & TabLabels[msg.index]
  of ToggleCheckbox:
    model.subscribed = not model.subscribed
    model.lastEvent = "subscribed " & $model.subscribed
  of SetVolume:
    model.volume = msg.value
    model.lastEvent = "volume " & formatFloat(msg.value, ffDecimal, 2)
  of SetBalance:
    model.balance = msg.value
    model.lastEvent = "balance " & formatFloat(msg.value, ffDecimal, 2)
  of SetAccent:
    model.accent = msg.color
    model.lastEvent = "accent changed"
  of SelectOption:
    model.option = msg.index
    model.lastEvent = "option " & ComboOptions[msg.index]
  of OpenMenu:
    model.openMenu = msg.text
    model.lastEvent = "menu " & msg.text
  of CloseMenu:
    model.openMenu = ""
  of OpenModal:
    model.modalOpen = true
    model.lastEvent = "modal opened"
  of CloseModal:
    model.modalOpen = false
    model.lastEvent = "modal closed"
  of Bump:
    inc model.clicks
    model.lastEvent = "clicks " & $model.clicks
  of Note:
    model.lastEvent = msg.text

widget heading(key, text: string):
  ui.scope(key):
    ui.label(ui.id("text"), text, width = fit(), height = fit())

widget textTab(msgs: var seq[Msg]):
  ui.column(ui.id("root"), cfg(gap = 10, padding = 12, height = fit())):
    ui.heading("labelHeading", "label")
    ui.label(ui.id("plain"), "Plain label", width = fit(), height = fit())

    ui.heading("coloredHeading", "coloredLabel")
    ui.coloredLabel(ui.id("colored"), "Colored label", ui.palette.primary,
        width = fit(), height = fit())

    ui.heading("diagnosticHeading", "diagnosticLabel")
    if ui.diagnosticLabel(
      ui.id("diagnostic"),
      "main.nim(12, 5) Error: clickable diagnostic",
      ui.palette.rose,
      width = fill(),
      height = fit(),
      clickable = true,
    ):
      msgs.add Msg(kind: Note, text: "diagnostic clicked")

    ui.heading("scrollHeading", "label with textScroll")
    ui.label(
      ui.id("scrolling"),
      "A label wider than its box scrolls instead of being clipped.",
      width = fixed(220),
      height = fit(),
      textScroll = true,
    )

widget buttonsTab(model: Model, msgs: var seq[Msg]):
  ui.column(ui.id("root"), cfg(gap = 10, padding = 12, height = fit())):
    ui.heading("buttonHeading", "button")
    ui.row(ui.id("row"), cfg(gap = 8, width = fit(), height = fit())):
      if ui.button(ui.id("bump"), "Click me", width = fit(), height = fit()):
        msgs.add Msg(kind: Bump)
      if ui.button(ui.id("padded"), "Extra padding", width = fit(),
          height = fit(), buttonPadding = 14.0):
        msgs.add Msg(kind: Note, text: "padded button")
      if ui.button(
        ui.id("styled"),
        "Styled",
        width = fit(),
        height = fit(),
        style = ComponentStyle(hasBackground: true, background: model.accent),
      ):
        msgs.add Msg(kind: Note, text: "styled button")

    ui.label(ui.id("count"), "clicks: " & $model.clicks, width = fit(),
        height = fit())

    ui.heading("spacerHeading", "spacer")
    ui.row(ui.id("spaced"), cfg(gap = 0, width = fill(), height = fit())):
      ui.label(ui.id("left"), "left", width = fit(), height = fit())
      ui.spacer(ui.id("gap"), width = fill(), height = fixed(1))
      ui.label(ui.id("right"), "right", width = fit(), height = fit())

    ui.heading("imageHeading", "image and imageButton")
    ui.row(ui.id("images"), cfg(gap = 8, width = fit(), height = fit())):
      ui.image(ui.id("logo"), AssetPath, width = fixed(48), height = fixed(48))
      ui.image(ui.id("sprite"), AssetPath, rect(0, 0, 24, 24),
          width = fixed(48), height = fixed(48))
      if ui.imageButton(ui.id("imagebutton"), AssetPath, width = fixed(48),
          height = fixed(48)):
        msgs.add Msg(kind: Note, text: "image button clicked")

widget inputsTab(model: Model, msgs: var seq[Msg]):
  ui.column(ui.id("root"), cfg(gap = 10, padding = 12, height = fit())):
    ui.heading("checkboxHeading", "checkbox")
    ui.checkbox(ui.id("subscribe"), "Subscribed", model.subscribed,
        width = fit(), height = fit())
    if ui.clicked(ui.id("subscribe")):
      msgs.add Msg(kind: ToggleCheckbox)

    ui.heading("sliderHeading", "slider")
    let volume = ui.slider(ui.id("volume"), model.volume, 0.0, 1.0,
        width = fill(), height = fixed(24))
    if volume.active:
      msgs.add Msg(kind: SetVolume, value: volume.value)

    ui.row(ui.id("vertical"), cfg(gap = 8, width = fit(), height = fit())):
      let balance = ui.slider(
        ui.id("balance"),
        model.balance,
        0.0,
        1.0,
        width = fixed(24),
        height = fixed(90),
        orientation = SliderVertical,
      )
      if balance.active:
        msgs.add Msg(kind: SetBalance, value: balance.value)
      ui.label(
        ui.id("balanceValue"),
        "balance " & formatFloat(model.balance, ffDecimal, 2),
        width = fit(),
        height = fit(),
      )

    ui.heading("swatchHeading", "colorSwatch and colorInput")
    ui.colorSwatch(ui.id("swatch"), model.accent, width = fixed(32),
        height = fixed(32))
    var accent = model.accent
    if ui.colorInput(ui.id("accent"), "Accent", accent):
      msgs.add Msg(kind: SetAccent, color: accent)

    ui.heading("comboHeading", "combobox")
    let picked = ui.combobox(ui.id("style"), model.option, ComboOptions,
        width = fixed(180), height = fixed(28))
    if picked.changed:
      msgs.add Msg(kind: SelectOption, index: picked.index)

    ui.heading("lineInputHeading", "lineInput")
    ui.lineInput(ui.id("name"), model.name, width = fixed(220),
        height = fixed(30))
    if ui.submitted(ui.id("name")):
      msgs.add Msg(kind: Note, text: "name submitted: " & model.name.text)

widget editorsTab(model: Model):
  ui.column(ui.id("root"), cfg(gap = 10, padding = 12)):
    ui.heading("editorHeading", "textEditor")
    ui.textEditor(
      ui.id("source"),
      model.source,
      width = fill(),
      height = fill(min = 160),
      fontName = "editor",
      lineNumbers = true,
      syntax = "nim",
      gutterMarkers = toHashSet([2]),
      activeLine = 1,
    )
    ui.label(
      ui.id("position"),
      "line " & $model.source.lineColumn.line & ", column " &
        $model.source.lineColumn.column,
      width = fit(),
      height = fit(),
    )

widget tablesTab(model: Model):
  ui.column(ui.id("root"), cfg(gap = 10, padding = 12, height = fit())):
    ui.heading("tableHeading", "table, tableHeader, tableRow, tableCell")
    ui.table(ui.id("table"), cfg(width = fill(), height = fit())):
      ui.tableHeader(ui.id("head"), cfg(width = fill(), height = fit())):
        for column, title in ["Widget", "Kind", "State"]:
          ui.tableCell(ui.id("headCell", column), cfg(width = fill(),
              height = fit())):
            ui.label(ui.id("headText", column), title, width = fit(),
                height = fit())
      for row, entry in [
        ["button", "interactive", "clicks " & $model.clicks],
        ["checkbox", "interactive", $model.subscribed],
        ["label", "static", "-"],
      ]:
        ui.tableRow(ui.id("row", row), cfg(width = fill(), height = fit())):
          for column, cell in entry:
            ui.tableCell(ui.id("cell", row, column), cfg(width = fill(),
                height = fit())):
              ui.label(ui.id("cellText", row, column), cell, width = fit(),
                  height = fit())

widget meshTab(model: var Model, msgs: var seq[Msg]):
  ui.column(ui.id("root"), cfg(gap = 10, padding = 12)):
    ui.heading("meshHeading", "mesh2d")
    ui.label(
      ui.id("hint"),
      "Drag points and edges. Hold Alt for fine, snapped dragging.",
      width = fill(),
      height = fit(),
    )
    if ui.mesh2d(ui.id("editor"), model.mesh, AssetPath, width = fill(),
        height = fill(min = 200)):
      msgs.add Msg(kind: Note, text: "mesh edited")

widget menuBarRow(openMenu: string, msgs: var seq[Msg]):
  ## The bar and its popover share one scope, so the popover can anchor itself
  ## to the entry that opened it.
  ui.menuBar(ui.id("bar"), cfg(width = fill(), height = fit(), gap = 4)):
    if ui.menu(ui.id("file"), "File", width = fit(), height = fit()):
      if openMenu == "File":
        msgs.add Msg(kind: CloseMenu)
      else:
        msgs.add Msg(kind: OpenMenu, text: "File")
    if ui.menu(ui.id("help"), "Help", width = fit(), height = fit()):
      if openMenu == "Help":
        msgs.add Msg(kind: CloseMenu)
      else:
        msgs.add Msg(kind: OpenMenu, text: "Help")

  if openMenu == "File":
    ui.floatingCardBelow(ui.id("popover"), ui.id("file"),
        cfg(width = fixed(180), height = fit(), padding = 4, gap = 2)):
      for item in ["New", "Open"]:
        ui.menuItem(ui.id("item", item), cfg(width = fill(), height = fit())):
          ui.label(ui.id("itemText", item), item, width = fit(), height = fit())
        if ui.clicked(ui.id("item", item)):
          msgs.add Msg(kind: Note, text: "File / " & item)
      ui.menuDivider(ui.id("divider"), width = fill(), height = fixed(9))
      ui.menuItem(ui.id("quit"), cfg(width = fill(), height = fit())):
        ui.label(ui.id("quitText"), "Quit", width = fit(), height = fit())
      if ui.clicked(ui.id("quit")):
        msgs.add Msg(kind: Note, text: "File / Quit")

widget overlaysTab(model: Model, msgs: var seq[Msg]):
  ui.column(ui.id("root"), cfg(gap = 10, padding = 12, height = fit())):
    ui.heading("menubarHeading", "menuBar, menu, menuItem, menuDivider")
    ui.menuBarRow(model.openMenu, msgs)

    ui.heading("cardHeading", "card and dialogHeader")
    ui.card(ui.id("card"), cfg(width = fill(), height = fit(), padding = 8,
        gap = 6)):
      ui.dialogHeader(ui.id("cardHead"), cfg(width = fill(), height = fit(),
          padding = 6)):
        ui.label(ui.id("cardTitle"), "Card", width = fit(), height = fit())
      ui.label(
        ui.id("cardBody"),
        "Cards are raised surfaces that swallow pointer presses.",
        width = fill(),
        height = fit(),
      )

    ui.heading("centerHeading", "center")
    ui.center(ui.id("center"), fill(), fixed(60)):
      ui.label(ui.id("centered"), "centered", width = fit(), height = fit())

    ui.heading("modalHeading", "modalDialog")
    if ui.button(ui.id("openModal"), "Open modal", width = fit(),
        height = fit()):
      msgs.add Msg(kind: OpenModal)

widget modal(open: bool, msgs: var seq[Msg]):
  ui.modalDialog(ui.id("root"), open, cfg(width = fixed(320), height = fit(),
      padding = 12, gap = 10)):
    ui.label(ui.id("text"), "A modal dialog.", width = fill(), height = fit())
    ui.row(ui.id("actions"), cfg(width = fill(), height = fit(), gap = 8,
        justifyContent = JustifyEnd)):
      if ui.button(ui.id("close"), "Close", width = fit(), height = fit()):
        msgs.add Msg(kind: CloseModal)

widget statusBar(text: string):
  ui.dialogHeader(ui.id("root"), cfg(width = fill(), height = fit(),
      padding = 6)):
    ui.label(ui.id("text"), "last event: " & text, width = fill(),
        height = fit())

widget view*(model: var Model, msgs: var seq[Msg]):
  ui.panel(ui.id("root"), cfg(width = fill(), height = fill(), padding = 8,
      gap = 8)):
    var tab = model.tab
    ui.tabs(ui.id("tabs"), TabLabels, tab, width = fill(), height = fit(),
        gap = 4)
    if tab != model.tab:
      msgs.add Msg(kind: SelectTab, index: tab)

    case model.tab
    of 0: ui.textTab(msgs)
    of 1: ui.buttonsTab(model, msgs)
    of 2: ui.inputsTab(model, msgs)
    of 3: ui.editorsTab(model)
    of 4: ui.tablesTab(model)
    of 5: ui.meshTab(model, msgs)
    else: ui.overlaysTab(model, msgs)

    ui.statusBar(model.lastEvent)

  ui.modal(model.modalOpen, msgs)

when isMainModule:
  var
    ui = UI.init()
    model = initModel()
    msgs: seq[Msg]

  let appCfg = AppConfig.init(width = 900, height = 640, title = "Nest Gallery")

  application appCfg, ui:
    ui.layout:
      ui.events:
        msgs.setLen(0)

      ui.view(model, msgs)

      ui.events:
        for msg in msgs:
          model.update(msg)
        if msgs.len > 0:
          ui.markAllDirty()
