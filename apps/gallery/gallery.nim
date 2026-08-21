## Component gallery: every widget Nest ships, in one Nim application.
##
## Run it with `nimble gallery` from the repository root. Each tab is a widget
## with its own state and its own event type; the root holds those states as
## fields and turns what the tabs report into the status line. See docs/ui.org.

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

type TextEvent* = enum
  DiagnosticClicked

type
  Buttons* = object
    clicks*: int

  ButtonsEventKind* = enum
    ButtonBumped
    ButtonNoted

  ButtonsEvent* = object
    case kind*: ButtonsEventKind
    of ButtonNoted:
      what*: string
    of ButtonBumped:
      discard

proc update*(model: var Buttons, event: ButtonsEvent) =
  case event.kind
  of ButtonBumped: inc model.clicks
  of ButtonNoted: discard

type
  Inputs* = object
    subscribed*: bool
    volume*: float64
    balance*: float64
    accent*: Color
    option*: int
    name*: LineInputState

  InputsEventKind* = enum
    SubscriptionToggled
    VolumeMoved
    BalanceMoved
    AccentPicked
    OptionPicked
    NameSubmitted

  InputsEvent* = object
    case kind*: InputsEventKind
    of VolumeMoved, BalanceMoved:
      value*: float64
    of AccentPicked:
      color*: Color
    of OptionPicked:
      index*: int
    of NameSubmitted:
      text*: string
    of SubscriptionToggled:
      discard

proc initInputs*(): Inputs =
  Inputs(
    volume: 0.65,
    balance: 0.5,
    accent: color(79, 185, 154),
    option: 1,
    name: LineInputState.new("nest"),
  )

proc update*(model: var Inputs, event: InputsEvent) =
  case event.kind
  of SubscriptionToggled: model.subscribed = not model.subscribed
  of VolumeMoved: model.volume = event.value
  of BalanceMoved: model.balance = event.value
  of AccentPicked: model.accent = event.color
  of OptionPicked: model.option = event.index
  of NameSubmitted: discard

type
  Editors* = object
    source*: EditorState
    lineNumbers*: bool
    scrollbars*: bool
    highlight*: bool
    marker*: bool
    activeLine*: bool

  EditorsEvent* = enum
    LineNumbersToggled
    ScrollbarsToggled
    HighlightToggled
    MarkerToggled
    ActiveLineToggled

proc initEditors*(): Editors =
  Editors(
    source: EditorState.new(
      "proc main() =\n  var ui = UI.init()\n  echo ui.windowWidth\n"
    ),
    lineNumbers: true,
    scrollbars: true,
    highlight: true,
    marker: true,
    activeLine: true,
  )

proc update*(model: var Editors, event: EditorsEvent) =
  case event
  of LineNumbersToggled:
    model.lineNumbers = not model.lineNumbers
  of ScrollbarsToggled:
    model.scrollbars = not model.scrollbars
  of HighlightToggled:
    model.highlight = not model.highlight
  of MarkerToggled:
    model.marker = not model.marker
  of ActiveLineToggled:
    model.activeLine = not model.activeLine

proc describe*(model: Editors, event: EditorsEvent): string =
  ## Name the feature the event toggled, and the state it is now in.
  let feature =
    case event
    of LineNumbersToggled: ("line numbers", model.lineNumbers)
    of ScrollbarsToggled: ("scrollbars", model.scrollbars)
    of HighlightToggled: ("syntax highlighting", model.highlight)
    of MarkerToggled: ("gutter marker", model.marker)
    of ActiveLineToggled: ("active line", model.activeLine)
  feature[0] & (if feature[1]: " on" else: " off")

type
  Mesh* = object
    state*: Mesh2DState

  MeshEvent* = enum
    MeshEdited

proc initMesh*(): Mesh =
  Mesh(state: Mesh2DState(
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
  ))

type
  Overlays* = object
    openMenu*: string
    modalOpen*: bool

  OverlaysEventKind* = enum
    MenuToggled
    MenuCommand
    ModalOpened
    ModalClosed

  OverlaysEvent* = object
    case kind*: OverlaysEventKind
    of MenuToggled, MenuCommand:
      name*: string
    else:
      discard

proc update*(model: var Overlays, event: OverlaysEvent) =
  case event.kind
  of MenuToggled:
    model.openMenu = if model.openMenu == event.name: "" else: event.name
  of MenuCommand:
    model.openMenu = ""
  of ModalOpened:
    model.modalOpen = true
  of ModalClosed:
    model.modalOpen = false

type
  Gallery* = object
    tab*: int
    status*: string
    buttons*: Buttons
    inputs*: Inputs
    editors*: Editors
    mesh*: Mesh
    overlays*: Overlays

  GalleryEvent* = object
    status*: string

proc initGallery*(): Gallery =
  Gallery(
    status: "ready",
    inputs: initInputs(),
    editors: initEditors(),
    mesh: initMesh(),
  )

proc update*(model: var Gallery, event: GalleryEvent) =
  model.status = event.status

widget heading(key, text: string):
  ui.scope(key):
    ui.label(ui.id("text"), text)

widget textTab() emits TextEvent:
  ui.column(ui.id("root"), cfg(gap = 10, padding = 12, height = fill(),
      scrollY = true)):
    ui.heading("labelHeading", "label")
    ui.label(ui.id("plain"), "Plain label")

    ui.heading("coloredHeading", "coloredLabel")
    ui.coloredLabel(ui.id("colored"), "Colored label", ui.palette.primary)

    ui.heading("diagnosticHeading", "diagnosticLabel")
    if ui.diagnosticLabel(ui.id("diagnostic"),
        "main.nim(12, 5) Error: clickable diagnostic", ui.palette.rose,
        width = fill(), clickable = true):
      emit DiagnosticClicked

    ui.heading("scrollHeading", "label with textScroll")
    ui.label(ui.id("scrolling"),
        "A label wider than its box scrolls instead of being clipped.",
        width = fixed(220), textScroll = true)

widget buttonsTab(model: Buttons, accent: Color) emits ButtonsEvent:
  ui.column(ui.id("root"), cfg(gap = 10, padding = 12, height = fill(),
      scrollY = true)):
    ui.heading("buttonHeading", "button")
    ui.row(ui.id("row"), cfg(gap = 8, width = fit(), height = fit())):
      if ui.button(ui.id("bump"), "Click me"):
        emit ButtonsEvent(kind: ButtonBumped)
      if ui.button(ui.id("padded"), "Extra padding", buttonPadding = 14.0):
        emit ButtonsEvent(kind: ButtonNoted, what: "padded button")
      if ui.button(ui.id("styled"), "Styled",
          style = ComponentStyle(hasBackground: true, background: accent)):
        emit ButtonsEvent(kind: ButtonNoted, what: "styled button")

    ui.label(ui.id("count"), "clicks: " & $model.clicks)

    ui.heading("spacerHeading", "spacer")
    ui.row(ui.id("spaced"), cfg(gap = 0, width = fill(), height = fit())):
      ui.label(ui.id("left"), "left")
      ui.spacer(ui.id("gap"), width = fill(), height = fixed(1))
      ui.label(ui.id("right"), "right")

    ui.heading("imageHeading", "image and imageButton")
    ui.row(ui.id("images"), cfg(gap = 8, width = fit(), height = fit())):
      ui.image(ui.id("logo"), AssetPath, width = fixed(48), height = fixed(48))
      ui.image(ui.id("sprite"), AssetPath, rect(0, 0, 24, 24),
          width = fixed(48), height = fixed(48))
      if ui.imageButton(ui.id("imagebutton"), AssetPath, width = fixed(48),
          height = fixed(48)):
        emit ButtonsEvent(kind: ButtonNoted, what: "image button clicked")

widget inputsTab(model: Inputs) emits InputsEvent:
  ui.column(ui.id("root"), cfg(gap = 10, padding = 12, height = fill(),
      scrollY = true)):
    ui.heading("checkboxHeading", "checkbox")
    ui.checkbox(ui.id("subscribe"), "Subscribed", model.subscribed)
    if ui.clicked(ui.id("subscribe")):
      emit InputsEvent(kind: SubscriptionToggled)

    ui.heading("sliderHeading", "slider")
    let volume = ui.slider(ui.id("volume"), model.volume, 0.0, 1.0)
    if volume.active:
      emit InputsEvent(kind: VolumeMoved, value: volume.value)

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
        emit InputsEvent(kind: BalanceMoved, value: balance.value)
      ui.label(ui.id("balanceValue"),
          "balance " & formatFloat(model.balance, ffDecimal, 2))

    ui.heading("swatchHeading", "colorSwatch and colorInput")
    ui.colorSwatch(ui.id("swatch"), model.accent, width = fixed(32),
        height = fixed(32))
    var accent = model.accent
    if ui.colorInput(ui.id("accent"), "Accent", accent):
      emit InputsEvent(kind: AccentPicked, color: accent)

    ui.heading("comboHeading", "combobox")
    let picked = ui.combobox(ui.id("style"), model.option, ComboOptions,
        width = fixed(180))
    if picked.changed:
      emit InputsEvent(kind: OptionPicked, index: picked.index)

    ui.heading("lineInputHeading", "lineInput")
    ui.lineInput(ui.id("name"), model.name, width = fixed(220))
    if ui.submitted(ui.id("name")):
      emit InputsEvent(kind: NameSubmitted, text: model.name.text)

widget editorFeatures(model: Editors) emits EditorsEvent:
  ## A stack of checkboxes, one per editor feature. Each reports the toggle it
  ## stands for and nothing else; the tab above decides what it means.
  ui.column(ui.id("root"), cfg(width = fit(), height = fit(), gap = 2)):
    template toggle(key, text: string, value: bool, toggled: EditorsEvent) =
      ui.checkbox(ui.id(key), text, value)
      if ui.clicked(ui.id(key)):
        emit toggled

    toggle("lineNumbers", "Line numbers", model.lineNumbers,
        LineNumbersToggled)
    toggle("scrollbars", "Scrollbars", model.scrollbars, ScrollbarsToggled)
    toggle("highlight", "Syntax highlighting", model.highlight,
        HighlightToggled)
    toggle("marker", "Gutter marker on line 2", model.marker, MarkerToggled)
    toggle("activeLine", "Highlight line 1", model.activeLine,
        ActiveLineToggled)

widget editorsTab(model: Editors) emits EditorsEvent:
  ui.column(ui.id("root"), cfg(gap = 10, padding = 12)):
    ui.heading("editorHeading", "textEditor")
    for event in ui.editorFeatures(model):
      emit event
    ui.textEditor(ui.id("source"), model.source, fontName = "editor",
        lineNumbers = model.lineNumbers, scrollbars = model.scrollbars,
        syntax = if model.highlight: "nim" else: "",
        gutterMarkers =
          if model.marker: toHashSet([2]) else: initHashSet[int](),
        activeLine = if model.activeLine: 1 else: 0)
    ui.label(ui.id("position"),
        "line " & $model.source.lineColumn.line & ", column " &
          $model.source.lineColumn.column)

widget tablesTab(clicks: int, subscribed: bool):
  ui.column(ui.id("root"), cfg(gap = 10, padding = 12, height = fill(),
      scrollY = true)):
    ui.heading("tableHeading", "table, tableHeader, tableRow, tableCell")
    ui.table(ui.id("table"), cfg(width = fill(), height = fit())):
      ui.tableHeader(ui.id("head"), cfg(width = fill(), height = fit())):
        for column, title in ["Widget", "Kind", "State"]:
          ui.tableCell(ui.id("headCell", column), cfg(width = fill(),
              height = fit())):
            ui.label(ui.id("headText", column), title)
      for rowIndex, entry in [
        ["button", "interactive", "clicks " & $clicks],
        ["checkbox", "interactive", $subscribed],
        ["label", "static", "-"],
      ]:
        ui.tableRow(ui.id("row", rowIndex), cfg(width = fill(),
            height = fit())):
          for column, cell in entry:
            ui.tableCell(ui.id("cell", rowIndex, column), cfg(width = fill(),
                height = fit())):
              ui.label(ui.id("cellText", rowIndex, column), cell)

widget meshTab(model: var Mesh) emits MeshEvent:
  ui.column(ui.id("root"), cfg(gap = 10, padding = 12)):
    ui.heading("meshHeading", "mesh2d")
    ui.label(ui.id("hint"),
        "Drag points and edges. Hold Alt for fine, snapped dragging.",
        width = fill())
    if ui.mesh2d(ui.id("editor"), model.state, AssetPath, width = fill(),
        height = fill(min = 200)):
      emit MeshEdited

widget menuBarRow(openMenu: string) emits OverlaysEvent:
  ## The bar and its popover share one scope, so the popover can anchor itself
  ## to the entry that opened it.
  ui.menuBar(ui.id("bar"), cfg(width = fill(), height = fit(), gap = 4)):
    if ui.menu(ui.id("file"), "File"):
      emit OverlaysEvent(kind: MenuToggled, name: "File")
    if ui.menu(ui.id("help"), "Help"):
      emit OverlaysEvent(kind: MenuToggled, name: "Help")

  if openMenu == "File":
    ui.floatingCardBelow(ui.id("popover"), ui.id("file"),
        cfg(width = fixed(180), height = fit(), padding = 4, gap = 2)):
      for item in ["New", "Open"]:
        ui.menuItem(ui.id("item", item), cfg(width = fill(), height = fit())):
          ui.label(ui.id("itemText", item), item)
        if ui.clicked(ui.id("item", item)):
          emit OverlaysEvent(kind: MenuCommand, name: "File / " & item)
      ui.menuDivider(ui.id("divider"), width = fill(), height = fixed(9))
      ui.menuItem(ui.id("quit"), cfg(width = fill(), height = fit())):
        ui.label(ui.id("quitText"), "Quit")
      if ui.clicked(ui.id("quit")):
        emit OverlaysEvent(kind: MenuCommand, name: "File / Quit")

widget overlaysTab(model: Overlays) emits OverlaysEvent:
  ui.column(ui.id("root"), cfg(gap = 10, padding = 12, height = fill(),
      scrollY = true)):
    ui.heading("menubarHeading", "menuBar, menu, menuItem, menuDivider")
    for event in ui.menuBarRow(model.openMenu):
      emit event

    ui.heading("cardHeading", "card and dialogHeader")
    ui.card(ui.id("card"), cfg(width = fill(), height = fit(), padding = 8,
        gap = 6)):
      ui.dialogHeader(ui.id("cardHead"), cfg(width = fill(), height = fit(),
          padding = 6)):
        ui.label(ui.id("cardTitle"), "Card")
      ui.label(ui.id("cardBody"),
          "Cards are raised surfaces. A floating one owns the pointer.",
          width = fill())

    ui.heading("centerHeading", "center")
    ui.center(ui.id("center"), fill(), fixed(60)):
      ui.label(ui.id("centered"), "centered")

    ui.heading("modalHeading", "modalDialog")
    if ui.button(ui.id("openModal"), "Open modal"):
      emit OverlaysEvent(kind: ModalOpened)

widget modal(open: bool) emits OverlaysEvent:
  ui.modalDialog(ui.id("root"), open, cfg(width = fixed(320), height = fit(),
      padding = 12, gap = 10)):
    ui.label(ui.id("text"), "A modal dialog.", width = fill())
    ui.row(ui.id("actions"), cfg(width = fill(), height = fit(), gap = 8,
        justifyContent = JustifyEnd)):
      if ui.button(ui.id("close"), "Close"):
        emit OverlaysEvent(kind: ModalClosed)

widget statusBar(text: string):
  ui.dialogHeader(ui.id("root"), cfg(width = fill(), height = fit(),
      padding = 6)):
    ui.label(ui.id("text"), "last event: " & text, width = fill())

widget view*(model: var Gallery) emits GalleryEvent:
  ui.panel(ui.id("root"), cfg(width = fill(), height = fill(), padding = 8,
      gap = 8)):
    var tab = model.tab
    ui.tabs(ui.id("tabs"), TabLabels, tab, width = fill(), height = fit(),
        gap = 4)
    if tab != model.tab:
      ui.events:
        model.tab = tab
      emit GalleryEvent(status: "tab " & TabLabels[tab])

    case model.tab
    of 0:
      for event in ui.textTab():
        case event
        of DiagnosticClicked:
          emit GalleryEvent(status: "diagnostic clicked")
    of 1:
      for event in ui.buttonsTab(model.buttons, model.inputs.accent):
        ui.events:
          model.buttons.update(event)
        case event.kind
        of ButtonBumped:
          emit GalleryEvent(status: "clicks " & $model.buttons.clicks)
        of ButtonNoted:
          emit GalleryEvent(status: event.what)
    of 2:
      for event in ui.inputsTab(model.inputs):
        ui.events:
          model.inputs.update(event)
        case event.kind
        of SubscriptionToggled:
          emit GalleryEvent(status: "subscribed " & $model.inputs.subscribed)
        of VolumeMoved:
          emit GalleryEvent(
            status: "volume " & formatFloat(event.value, ffDecimal, 2))
        of BalanceMoved:
          emit GalleryEvent(
            status: "balance " & formatFloat(event.value, ffDecimal, 2))
        of AccentPicked:
          emit GalleryEvent(status: "accent changed")
        of OptionPicked:
          emit GalleryEvent(status: "option " & ComboOptions[event.index])
        of NameSubmitted:
          emit GalleryEvent(status: "name submitted: " & event.text)
    of 3:
      for event in ui.editorsTab(model.editors):
        ui.events:
          model.editors.update(event)
        emit GalleryEvent(status: model.editors.describe(event))
    of 4:
      ui.tablesTab(model.buttons.clicks, model.inputs.subscribed)
    of 5:
      for event in ui.meshTab(model.mesh):
        case event
        of MeshEdited:
          emit GalleryEvent(status: "mesh edited")
    else:
      for event in ui.overlaysTab(model.overlays):
        ui.events:
          model.overlays.update(event)
        case event.kind
        of MenuToggled:
          emit GalleryEvent(status: "menu " & event.name)
        of MenuCommand:
          emit GalleryEvent(status: event.name)
        of ModalOpened:
          emit GalleryEvent(status: "modal opened")
        of ModalClosed:
          emit GalleryEvent(status: "modal closed")

    ui.statusBar(model.status)

  for event in ui.modal(model.overlays.modalOpen):
    model.overlays.update(event)
    emit GalleryEvent(status: "modal closed")

when isMainModule:
  runApp(AppConfig.init(width = 900, height = 640, title = "Nest Gallery"),
      initGallery(), update, view)
