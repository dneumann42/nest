import std/[sets, strutils, unittest]

import nest as nestApp
import nest/[appConfig, coords, dialogAnchors, layerShellSdl3Driver, palette,
    perf, resources, ui]
import nest/screen

const
  Toolbar = WidgetID(101)
  Body = WidgetID(102)
  Sidebar = WidgetID(103)
  Content = WidgetID(104)
  Button1 = WidgetID(105)
  Button2 = WidgetID(106)
  Button3 = WidgetID(107)
  Button4 = WidgetID(108)
  Spacer = WidgetID(109)
  Button5 = WidgetID(110)
  Panel1 = WidgetID(111)
  CenterBox = WidgetID(112)
  Label1 = WidgetID(113)
  Label2 = WidgetID(114)
  HeaderRow = WidgetID(115)
  HeaderLabel = WidgetID(116)
  HeaderNewButton = WidgetID(117)
  Input1 = WidgetID(118)
  NarrowPanel = WidgetID(119)
  NarrowHeader = WidgetID(120)
  NarrowButton = WidgetID(121)
  ScrollPanel = WidgetID(122)
  ScrollItem1 = WidgetID(123)
  ScrollItem2 = WidgetID(124)
  ScrollItem3 = WidgetID(125)
  ScrollRow = WidgetID(126)
  OutsideHeader = WidgetID(127)
  OutsideFooter = WidgetID(128)
  Slider1 = WidgetID(129)
  FloatingPanel = WidgetID(130)
  Editor2 = WidgetID(131)

proc widget(ui: UI, id: WidgetID): Widget =
  for box in ui.layout.boxes:
    if box.id == id:
      return box
  raise newException(ValueError, "missing widget: " & $id)

proc checkFrame(box: Widget, x, y, width, height: float64) =
  let frame = box.frame
  check frame.x == x
  check frame.y == y
  check frame.width == width
  check frame.height == height

var realtimeProbeDraws = 0

type RealtimeProbe = ref object of Component

method draw*(self: RealtimeProbe, widget: Widget, ctx: var DrawContext) =
  discard self
  discard widget
  discard ctx
  inc realtimeProbeDraws

suite "ui layout nesting":
  test "perf stats track bounded rolling fps":
    var stats = PerfStats.init(historySize = 3)
    stats.recordFrame(1000)
    stats.recordFrame(1016)
    stats.recordFrame(1032)
    stats.recordFrame(1064)
    stats.recordFrame(1080)

    check stats.frameCount == 4
    check abs(stats.latestFps - 62.5) < 0.01
    check abs(stats.averageFps(3) - 46.875) < 0.01
    check stats.summary.contains("frames=4")

  test "lerp interpolates toward a target":
    check lerp(0.0, 10.0, 0.25) == 2.5

  test "box config carries local background and opacity overrides":
    let styled = cfg(width = fit(), height = fit())
      .withBackground(color(12'u8, 24'u8, 36'u8))
      .withOpacity(0.42)

    check styled.style.hasBackground
    check styled.style.background == color(12'u8, 24'u8, 36'u8)
    check styled.style.hasOpacity
    check styled.style.opacity == 0.42

  test "dialog anchors do not double-offset top layer-shell popovers":
    let app = AppConfig.init(width = 260, height = 120)
    let anchored = app.applyDialogAnchor(DialogAnchor(
      ok: true,
      x: 8,
      y: 0,
      width: 42,
      height: 24,
      windowWidth: 800,
      windowHeight: 600,
    ))

    check anchored.layerShell
    check EdgeTop in anchored.layerShellConfig.anchors
    check EdgeLeft in anchored.layerShellConfig.anchors
    check anchored.layerShellConfig.marginTop == 0
    check anchored.layerShellConfig.marginLeft == 8

  test "draggable overlay dialogs use movable top-left anchors":
    let app = AppConfig.overlayDialog(
      width = 260.Positive,
      height = 120.Positive,
      draggable = true,
    )
    check EdgeTop in app.layerShellConfig.anchors
    check EdgeLeft in app.layerShellConfig.anchors
    check app.layerShellConfig.marginTop == 96
    check app.layerShellConfig.marginLeft == 96

  test "palette provides clean dark and light themes":
    let
      dark = Palette.dark()
      light = Palette.light()

    check dark.panelBackground != light.panelBackground
    check dark.textColor != light.textColor
    check dark.colorByName("panel-background", color(0, 0, 0)) ==
        dark.panelBackground
    check light.colorByName("card-accent", color(0, 0, 0)) == light.cardAccent

  test "fit button remains visible after a fill label in a row":
    let originalFontRelays = fontRelays
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
      metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
      Font(size),
      closeFont: proc(f: Font) =
      discard,
      getFontMetrics: proc(f: Font): FontMetrics =
      FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
      TextExtent(w: text.len * f.int, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: text.len * f.int, h: 18),
    )
    try:
      var resources = Resources.new()
      resources.loadFont("font", "", 8)
      var ui = UI.init()
      ui.beginLayout(800, 100)

      ui.row(HeaderRow, cfg(width = fixed(500), height = fit())):
        ui.label(HeaderLabel, "LINE: ", width = fill(), height = fit())
        ui.button(HeaderNewButton, "New", width = fit(), height = fit())

      ui.applyIntrinsicSizes(resources)
      ui.endLayout()

      checkFrame(ui.widget(HeaderRow), 0, 0, 500, 24)
      checkFrame(ui.widget(HeaderLabel), 0, 0, 460, 18)
      checkFrame(ui.widget(HeaderNewButton), 460, 0, 40, 24)
    finally:
      fontRelays = originalFontRelays

  test "floating card below anchor does not affect parent column flow":
    let originalFontRelays = fontRelays
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
      metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
      Font(size),
      closeFont: proc(f: Font) =
      discard,
      getFontMetrics: proc(f: Font): FontMetrics =
      FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      var resources = Resources.new()
      resources.loadFont("font", "", 18)
      var ui = UI.init()
      ui.beginLayout(300, 180)

      ui.column(Body, cfg(width = fill(), height = fill(),
          alignItems = AlignStretch)):
        ui.button(Button1, "File", fixed(60), fixed(24))
        ui.label(Label1, "Duck", fit(), fit(), alignSelf = AlignCenter)
        ui.floatingCardBelow(FloatingPanel, Button1,
            cfg(width = fixed(120), height = fit(), padding = 4,
                alignItems = AlignStretch)):
          ui.label(Label2, "Save As", fill(), fit())

      ui.applyIntrinsicSizes(resources)
      ui.endLayout()

      let
        buttonFrame = ui.widget(Button1).frame
        labelFrame = ui.widget(Label1).frame
        floatingFrame = ui.widget(FloatingPanel).frame
      check labelFrame.y == buttonFrame.y + buttonFrame.height
      check floatingFrame.x == buttonFrame.x
      check floatingFrame.y == buttonFrame.y + buttonFrame.height
    finally:
      fontRelays = originalFontRelays

  test "text measurement and labels support fit sizing":
    let originalFontRelays = fontRelays
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
      metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
      Font(size),
      closeFont: proc(f: Font) =
      discard,
      getFontMetrics: proc(f: Font): FontMetrics =
      FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
      TextExtent(w: text.len * f.int, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: text.len * f.int, h: 18),
    )
    try:
      var resources = Resources.new()
      resources.loadFont("body", "", 9)

      let measured = resources.measureText("body", "Paths")
      check measured.width == 45
      check measured.height == 18
      check measured.lineHeight == 22
      check printableText("A\tB\nC") == "A    B C"
      check resources.measureText("body", "A\tB").width == 54

      let label = Label.new("Paths", "body")
      let intrinsic = Component(label).measure(resources)
      check intrinsic.hasWidth
      check intrinsic.hasHeight
      check intrinsic.width == 45
      check intrinsic.height == 18
    finally:
      fontRelays = originalFontRelays

  test "line input focuses edits and submits":
    var ui = UI.init()
    var state = LineInputState.new("abc")
    ui.beginLayout(300, 80)

    ui.lineInput(Input1, state, width = fixed(200), height = fixed(30))
    ui.endLayout()

    var ctx = UpdateContext(mouseX: 10, mouseY: 10, mouseLeftPressed: true)
    ui.update(ctx)
    check ctx.focused(Input1)

    ctx.mouseLeftPressed = false
    ctx.keyInputs = @[KeyInput(key: KeyA, mods: {CtrlPressed})]
    ctx.textInputs = @["X"]
    ui.update(ctx)
    check state.text == "Xabc"
    check state.cursor == 1

    ctx.keyInputs = @[KeyInput(key: KeyE, mods: {CtrlPressed})]
    ctx.textInputs = @[]
    ui.update(ctx)
    check state.cursor == state.text.len

    ctx.keyInputs = @[KeyInput(key: KeyBackspace)]
    ui.update(ctx)
    check state.text == "Xab"
    check state.cursor == 3

    ctx.keyInputs = @[KeyInput(key: KeyEnter)]
    ui.update(ctx)
    check ctx.submitted(Input1)
    check ctx.focusedWidget == InvalidWidgetID

  test "editor supports multiline editing and cursor movement":
    var ui = UI.init()
    var state = EditorState.new("one\ntwo")
    ui.beginLayout(300, 160)

    ui.textEditor(Input1, state, width = fixed(220), height = fixed(120))
    ui.endLayout()

    var ctx = UpdateContext(mouseX: 10, mouseY: 10, mouseLeftPressed: true)
    ui.update(ctx)
    check ctx.focused(Input1)

    ctx.mouseLeftPressed = false
    ctx.keyInputs = @[KeyInput(key: KeyEnter)]
    ctx.textInputs = @[]
    ui.update(ctx)
    check state.text == "one\ntwo\n"

    ctx.keyInputs = @[KeyInput(key: KeyA, mods: {CtrlPressed})]
    ui.update(ctx)
    check state.cursor == state.text.len

    ctx.keyInputs = @[KeyInput(key: KeyUp)]
    ui.update(ctx)
    check state.cursor == 4

  test "editor line numbers add an optional gutter":
    let originalFontRelays = fontRelays
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
      metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
      Font(size),
      closeFont: proc(f: Font) =
      discard,
      getFontMetrics: proc(f: Font): FontMetrics =
      FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      var resources = Resources.new()
      resources.loadFont("font", "", 18)
      var ui = UI.init()
      var plain = EditorState.new("abcdefghij\nb")
      var numbered = EditorState.new("abcdefghij\nb")

      ui.beginLayout(400, 120)
      ui.row(Body, cfg(width = fit(), height = fit())):
        ui.textEditor(Input1, plain, width = fit(), height = fit())
        ui.textEditor(
          Editor2,
          numbered,
          width = fit(),
          height = fit(),
          lineNumbers = true,
        )
      ui.applyIntrinsicSizes(resources)
      ui.endLayout()

      check ui.widget(Editor2).frame.width > ui.widget(Input1).frame.width
    finally:
      fontRelays = originalFontRelays

  test "editor horizontal scroll clips text outside line number gutter":
    type TextDraw = object
      x: int
      clip: Rect

    let
      originalFontRelays = fontRelays
      originalWindowRelays = windowRelays
    var
      currentClip = rect(0, 0, 0, 0)
      textDraws: seq[TextDraw]
    windowRelays = WindowRelays(
      createWindow: proc(layout: var ScreenLayout) =
      discard,
      refresh: proc() =
      discard,
      saveState: proc() =
      discard,
      restoreState: proc() =
      discard,
      setClipRect: proc(r: Rect) =
      currentClip = r,
      setCursor: proc(c: CursorKind) =
      discard,
      setWindowTitle: proc(title: string) =
      discard,
    )
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
      metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
      Font(size),
      closeFont: proc(f: Font) =
      discard,
      getFontMetrics: proc(f: Font): FontMetrics =
      FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      if text == "abcdefghijklmnopqrstuvwxyz":
        textDraws.add TextDraw(x: x, clip: currentClip)
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      var resources = Resources.new()
      resources.loadFont("font", "", 18)
      var ui = UI.init()
      var state = EditorState.new("abcdefghijklmnopqrstuvwxyz")
      state.scrollX = 30
      state.targetX = 30

      ui.beginLayout(160, 80)
      ui.textEditor(
        Input1,
        state,
        width = fixed(120),
        height = fixed(60),
        lineNumbers = true,
      )
      ui.applyIntrinsicSizes(resources)
      ui.endLayout()

      var drawContext = DrawContext(
        resources: resources, palette: Palette.init(), windowWidth: 160,
            windowHeight: 80, dirtyAll: true
      )
      discard ui.draw(drawContext)

      check textDraws.len == 1
      check textDraws[0].x < textDraws[0].clip.x
      check textDraws[0].clip.x > ui.widget(Input1).frame.x.toInt
    finally:
      fontRelays = originalFontRelays
      windowRelays = originalWindowRelays

  test "editor mouse wheel scrolls content with easing":
    let originalFontRelays = fontRelays
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
      metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
      Font(size),
      closeFont: proc(f: Font) =
      discard,
      getFontMetrics: proc(f: Font): FontMetrics =
      FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      var ui = UI.init()
      ui.initContext(220, 80)
      ui.loadFont("font", "", 18)
      var state = EditorState.new("one\ntwo\nthree\nfour\nfive\nsix")

      ui.layout:
        ui.textEditor(Input1, state, width = fixed(200), height = fixed(60))

      check state.maxY > 0
      ui.mouseMove(10, 10)
      ui.mouseWheel(0, -1)
      ui.layout:
        ui.textEditor(Input1, state, width = fixed(200), height = fixed(60))

      check state.targetY > 0
      check state.scrollY > 0
      check state.scrollY < state.targetY
    finally:
      fontRelays = originalFontRelays

  test "editor scroll target overshoots and snaps back with easing":
    let originalFontRelays = fontRelays
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
      metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
      Font(size),
      closeFont: proc(f: Font) =
      discard,
      getFontMetrics: proc(f: Font): FontMetrics =
      FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      var ui = UI.init()
      ui.initContext(220, 80)
      ui.loadFont("font", "", 18)
      var state = EditorState.new("one\ntwo\nthree\nfour\nfive\nsix")

      ui.layout:
        ui.textEditor(Input1, state, width = fixed(200), height = fixed(60))

      ui.mouseMove(10, 10)
      ui.mouseWheel(0, 1)
      ui.layout:
        ui.textEditor(Input1, state, width = fixed(200), height = fixed(60))

      let
        overshotTargetY = state.targetY
        overshotScrollY = state.scrollY
      check overshotTargetY < 0
      check overshotScrollY < 0

      ui.beginInputFrame()
      for _ in 0 ..< 24:
        ui.layout:
          ui.textEditor(Input1, state, width = fixed(200), height = fixed(60))

      check state.targetY > overshotTargetY
      check state.scrollY > overshotScrollY
      check state.targetY <= 0
      check state.scrollY <= 0
    finally:
      fontRelays = originalFontRelays

  test "focused editor mouse wheel scrolls without hover":
    let originalFontRelays = fontRelays
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
      metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
      Font(size),
      closeFont: proc(f: Font) =
      discard,
      getFontMetrics: proc(f: Font): FontMetrics =
      FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      var ui = UI.init()
      ui.initContext(220, 80)
      ui.loadFont("font", "", 18)
      var state = EditorState.new("one\ntwo\nthree\nfour\nfive\nsix")

      ui.layout:
        ui.textEditor(Input1, state, width = fixed(200), height = fixed(60))

      ui.mouseMove(10, 10)
      ui.mouseDown()
      ui.layout:
        ui.textEditor(Input1, state, width = fixed(200), height = fixed(60))
      ui.mouseUp()

      ui.mouseMove(210, 70)
      ui.mouseWheel(0, -1)
      ui.layout:
        ui.textEditor(Input1, state, width = fixed(200), height = fixed(60))

      check state.targetY > 0
      check state.scrollY > 0
    finally:
      fontRelays = originalFontRelays

  test "active focused editor mouse wheel marks a redraw":
    let originalFontRelays = fontRelays
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
      metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
      Font(size),
      closeFont: proc(f: Font) =
      discard,
      getFontMetrics: proc(f: Font): FontMetrics =
      FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      var ui = UI.init()
      ui.initContext(220, 80)
      ui.loadFont("font", "", 18)
      var state = EditorState.new("one\ntwo\nthree\nfour\nfive\nsix")

      ui.layout:
        ui.textEditor(Input1, state, width = fixed(200), height = fixed(60))
      ui.mouseMove(10, 10)
      ui.mouseDown()
      ui.layout:
        ui.textEditor(Input1, state, width = fixed(200), height = fixed(60))
      ui.mouseUp()
      ui.layout:
        ui.textEditor(Input1, state, width = fixed(200), height = fixed(60))

      check ui.redrewFrame()
      ui.mouseWheel(0, -1)
      ui.layout:
        ui.textEditor(Input1, state, width = fixed(200), height = fixed(60))

      check ui.redrewFrame()
      check state.targetY > 0
    finally:
      fontRelays = originalFontRelays

  test "unchanged layout reuses previous draw until marked dirty":
    let originalFontRelays = fontRelays
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
      metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
      Font(size),
      closeFont: proc(f: Font) =
      discard,
      getFontMetrics: proc(f: Font): FontMetrics =
      FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      var ui = UI.init()
      ui.initContext(220, 80)
      ui.loadFont("font", "", 18)

      ui.layout:
        ui.label(Label1, "Stable", width = fit(), height = fit())
      check ui.redrewFrame()

      ui.layout:
        ui.label(Label1, "Stable", width = fit(), height = fit())
      check not ui.redrewFrame()

      ui.markAllDirty()
      ui.layout:
        ui.label(Label1, "Stable", width = fit(), height = fit())
      check ui.redrewFrame()
    finally:
      fontRelays = originalFontRelays

  test "realtime widgets can redraw without a full layout redraw":
    realtimeProbeDraws = 0
    var ui = UI.init()
    ui.initContext(220, 80)

    ui.layout:
      discard ui.component(Label1, Component(RealtimeProbe()), fixed(40), fixed(20))
      ui.markRealtime(Label1)
    check ui.redrewFrame()
    check realtimeProbeDraws == 0
    check ui.hasRealtimeWidgets()

    discard ui.drawRealtime()
    check realtimeProbeDraws == 1

    ui.layout:
      discard ui.component(Label1, Component(RealtimeProbe()), fixed(40), fixed(20))
      ui.markRealtime(Label1)
    check not ui.redrewFrame()
    check realtimeProbeDraws == 1

    discard ui.drawRealtime()
    check realtimeProbeDraws == 2

    ui.layout:
      discard ui.component(Label1, Component(RealtimeProbe()), fixed(40), fixed(20))
    check not ui.hasRealtimeWidgets()
    discard ui.drawRealtime()
    check realtimeProbeDraws == 2

  test "passive backgrounds block input without acting interactive":
    var ui = UI.init()
    ui.initContext(220, 80)

    ui.layout:
      ui.panel(Panel1, cfg(width = fixed(80), height = fixed(40),
          style = ComponentStyle(hasBackground: true))):
        discard
      discard ui.component(Button1, Component(RealtimeProbe()), fixed(20), fixed(20))

    check ui.pointerOverUi(10, 10)
    check not ui.pointerOverInteractive(10, 10)

  test "editor wheel uses measured bounds before first draw":
    let originalFontRelays = fontRelays
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
      metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
      Font(size),
      closeFont: proc(f: Font) =
      discard,
      getFontMetrics: proc(f: Font): FontMetrics =
      FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      var ui = UI.init()
      ui.initContext(220, 80)
      ui.loadFont("font", "", 18)
      var state = EditorState.new("one")

      ui.layout:
        ui.textEditor(Input1, state, width = fixed(200), height = fixed(60))

      state.text = "one\ntwo\nthree\nfour\nfive\nsix"
      ui.mouseMove(10, 10)
      ui.mouseWheel(0, -1)
      ui.layout:
        ui.textEditor(Input1, state, width = fixed(200), height = fixed(60))

      check state.maxY > 0
      check state.targetY > 0
    finally:
      fontRelays = originalFontRelays

  test "focused editor wheel can scroll away from cursor":
    let originalFontRelays = fontRelays
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
      metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
      Font(size),
      closeFont: proc(f: Font) =
      discard,
      getFontMetrics: proc(f: Font): FontMetrics =
      FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      var ui = UI.init()
      ui.initContext(220, 80)
      ui.loadFont("font", "", 18)
      var state = EditorState.new("one\ntwo\nthree\nfour\nfive\nsix")
      state.cursor = 0

      ui.layout:
        ui.textEditor(Input1, state, width = fixed(200), height = fixed(60))
      ui.mouseMove(10, 10)
      ui.mouseDown()
      ui.layout:
        ui.textEditor(Input1, state, width = fixed(200), height = fixed(60))
      ui.mouseUp()

      ui.mouseWheel(0, -1)
      ui.layout:
        ui.textEditor(Input1, state, width = fixed(200), height = fixed(60))

      check state.targetY > 0
      check state.scrollY > 0
    finally:
      fontRelays = originalFontRelays

  test "focused editor horizontal wheel can scroll away from cursor":
    let originalFontRelays = fontRelays
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
      metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
      Font(size),
      closeFont: proc(f: Font) =
      discard,
      getFontMetrics: proc(f: Font): FontMetrics =
      FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      var ui = UI.init()
      ui.initContext(160, 80)
      ui.loadFont("font", "", 18)
      var state = EditorState.new("abcdefghijklmnopqrstuvwxyz")
      state.cursor = 0

      ui.layout:
        ui.textEditor(Input1, state, width = fixed(120), height = fixed(60))
      ui.mouseMove(10, 10)
      ui.mouseDown()
      ui.layout:
        ui.textEditor(Input1, state, width = fixed(120), height = fixed(60))
      ui.mouseUp()

      ui.mouseWheel(-1, 0)
      ui.layout:
        ui.textEditor(Input1, state, width = fixed(120), height = fixed(60))

      check state.targetX > 0
      check state.scrollX > 0
    finally:
      fontRelays = originalFontRelays

  test "editor click maps through scroll offset to move cursor":
    let originalFontRelays = fontRelays
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
      metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
      Font(size),
      closeFont: proc(f: Font) =
      discard,
      getFontMetrics: proc(f: Font): FontMetrics =
      FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      var ui = UI.init()
      ui.initContext(160, 80)
      ui.loadFont("font", "", 18)
      var state = EditorState.new(
        "abcdefghijklmnopqrstuvwxyz\nsecond line\nthird line\nfourth line"
      )
      state.cursor = 0
      state.scrollX = 54
      state.targetX = 54
      state.scrollY = 22
      state.targetY = 22

      ui.layout:
        ui.textEditor(Input1, state, width = fixed(120), height = fixed(60))

      ui.mouseMove(20, 15)
      ui.mouseDown()
      ui.layout:
        ui.textEditor(Input1, state, width = fixed(120), height = fixed(60))

      check state.cursor == 34
      check state.targetX == 54
      check state.targetY == 22
      ui.mouseUp()
    finally:
      fontRelays = originalFontRelays

  test "editor scrollbar drag scrolls content":
    let originalFontRelays = fontRelays
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
      metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
      Font(size),
      closeFont: proc(f: Font) =
      discard,
      getFontMetrics: proc(f: Font): FontMetrics =
      FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      var ui = UI.init()
      ui.initContext(220, 80)
      ui.loadFont("font", "", 18)
      var state = EditorState.new("one\ntwo\nthree\nfour\nfive\nsix")

      ui.layout:
        ui.textEditor(Input1, state, width = fixed(200), height = fixed(60))

      ui.mouseMove(195, 5)
      ui.mouseDown()
      ui.layout:
        ui.textEditor(Input1, state, width = fixed(200), height = fixed(60))

      ui.mouseMove(195, 35)
      ui.layout:
        ui.textEditor(Input1, state, width = fixed(200), height = fixed(60))

      check state.targetY > 0
      check state.scrollY > 0
      ui.mouseUp()
    finally:
      fontRelays = originalFontRelays

  test "line input escape and outside click clear focus without submit":
    var ui = UI.init()
    var state = LineInputState.new("abc")
    ui.beginLayout(300, 80)

    ui.lineInput(Input1, state, width = fixed(200), height = fixed(30))
    ui.endLayout()

    var ctx = UpdateContext(focusedWidget: Input1)
    ctx.keyInputs = @[KeyInput(key: KeyEsc)]
    ui.update(ctx)
    check ctx.focusedWidget == InvalidWidgetID
    check not ctx.submitted(Input1)

    ctx = UpdateContext(focusedWidget: Input1, mouseX: 250, mouseY: 40,
        mouseLeftPressed: true)
    ui.update(ctx)
    check ctx.focusedWidget == InvalidWidgetID
    check not ctx.submitted(Input1)

  test "path editor style input row survives narrow windows":
    let originalFontRelays = fontRelays
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
      metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
      Font(size),
      closeFont: proc(f: Font) =
      discard,
      getFontMetrics: proc(f: Font): FontMetrics =
      FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
      TextExtent(w: text.len * f.int, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: text.len * f.int, h: 18),
    )
    try:
      var resources = Resources.new()
      resources.loadFont("font", "", 8)
      var ui = UI.init()
      var state = LineInputState.new("")

      ui.beginLayout(80, 40)
      ui.column(
        Body,
        cfg(width = fill(), height = fill(), alignItems = AlignCenter,
            justifyContent = JustifyCenter),
      ):
        ui.panel(
          NarrowPanel,
          cfg(width = prefer(800, min = 400), height = fit(),
              alignItems = AlignCenter),
        ):
          ui.row(NarrowHeader, cfg(width = fill(), height = fit())):
            ui.lineInput(Input1, state, width = fill(), height = fit())
            ui.button(NarrowButton, "New", width = fit(), height = fit())

      ui.applyIntrinsicSizes(resources)
      ui.endLayout()

      check ui.widget(NarrowHeader).frame.height >= 28
      check ui.widget(Input1).frame.width >= 0
      check ui.widget(NarrowButton).frame.width > 0
      check ui.widget(NarrowButton).frame.x > ui.widget(Input1).frame.x + 200
    finally:
      fontRelays = originalFontRelays

  test "vertical scrollbar drag offsets scroll container children":
    var ui = UI.init()

    ui.beginLayout(120, 80)
    ui.panel(ScrollPanel, cfg(width = fixed(100), height = fixed(60),
        scrollY = true)):
      ui.button(ScrollItem1, "One", width = fixed(90), height = fixed(30))
      ui.button(ScrollItem2, "Two", width = fixed(90), height = fixed(30))
      ui.button(ScrollItem3, "Three", width = fixed(90), height = fixed(30))
    ui.endLayout()

    checkFrame(ui.widget(ScrollItem1), 0, 0, 90, 30)

    var ctx = UpdateContext(mouseX: 95, mouseY: 5, mouseLeftPressed: true,
        mouseLeftDown: true)
    ui.update(ctx)
    ctx.mouseLeftPressed = false
    ctx.mouseY = 30
    ui.update(ctx)

    ui.reset()
    ui.beginLayout(120, 80)
    ui.panel(ScrollPanel, cfg(width = fixed(100), height = fixed(60),
        scrollY = true)):
      ui.button(ScrollItem1, "One", width = fixed(90), height = fixed(30))
      ui.button(ScrollItem2, "Two", width = fixed(90), height = fixed(30))
      ui.button(ScrollItem3, "Three", width = fixed(90), height = fixed(30))
    ui.endLayout()

    check ui.widget(ScrollItem1).frame.y < 0

  test "mouse wheel scrolls vertically with easing":
    var ui = UI.init()

    ui.beginLayout(120, 80)
    ui.panel(ScrollPanel, cfg(width = fixed(100), height = fixed(60),
        scrollY = true)):
      ui.button(ScrollItem1, "One", width = fixed(90), height = fixed(30))
      ui.button(ScrollItem2, "Two", width = fixed(90), height = fixed(30))
      ui.button(ScrollItem3, "Three", width = fixed(90), height = fixed(30))
    ui.endLayout()

    var ctx = UpdateContext(mouseX: 10, mouseY: 10, mouseWheelY: -1)
    ui.update(ctx)

    ui.reset()
    ui.beginLayout(120, 80)
    ui.panel(ScrollPanel, cfg(width = fixed(100), height = fixed(60),
        scrollY = true)):
      ui.button(ScrollItem1, "One", width = fixed(90), height = fixed(30))
      ui.button(ScrollItem2, "Two", width = fixed(90), height = fixed(30))
      ui.button(ScrollItem3, "Three", width = fixed(90), height = fixed(30))
    ui.endLayout()

    check ui.widget(ScrollItem1).frame.y < 0
    check ui.widget(ScrollItem1).frame.y > -30

  test "scroll target overshoots and snaps back with easing":
    var ui = UI.init()

    ui.beginLayout(120, 80)
    ui.panel(ScrollPanel, cfg(width = fixed(100), height = fixed(60),
        scrollY = true)):
      ui.button(ScrollItem1, "One", width = fixed(90), height = fixed(30))
      ui.button(ScrollItem2, "Two", width = fixed(90), height = fixed(30))
      ui.button(ScrollItem3, "Three", width = fixed(90), height = fixed(30))
    ui.endLayout()

    var ctx = UpdateContext(mouseX: 10, mouseY: 10, mouseWheelY: 1)
    ui.update(ctx)

    ui.reset()
    ui.beginLayout(120, 80)
    ui.panel(ScrollPanel, cfg(width = fixed(100), height = fixed(60),
        scrollY = true)):
      ui.button(ScrollItem1, "One", width = fixed(90), height = fixed(30))
      ui.button(ScrollItem2, "Two", width = fixed(90), height = fixed(30))
      ui.button(ScrollItem3, "Three", width = fixed(90), height = fixed(30))
    ui.endLayout()

    let overshotY = ui.widget(ScrollItem1).frame.y
    check overshotY > 0

    var settledY = overshotY
    for _ in 0 ..< 24:
      ui.reset()
      ui.beginLayout(120, 80)
      ui.panel(ScrollPanel, cfg(width = fixed(100), height = fixed(60),
          scrollY = true)):
        ui.button(ScrollItem1, "One", width = fixed(90), height = fixed(30))
        ui.button(ScrollItem2, "Two", width = fixed(90), height = fixed(30))
        ui.button(ScrollItem3, "Three", width = fixed(90), height = fixed(30))
      ui.endLayout()
      settledY = ui.widget(ScrollItem1).frame.y

    check settledY < overshotY
    check settledY >= 0

  test "header row can remain outside scroll panel":
    var ui = UI.init()

    ui.beginLayout(160, 120)
    ui.column(Body, cfg(width = fixed(120), height = fixed(100), gap = 8.0)):
      ui.row(OutsideHeader, cfg(width = fill(), height = fixed(30))):
        ui.button(HeaderNewButton, "New", width = fixed(40), height = fixed(24))
      ui.panel(ScrollPanel, cfg(width = fill(), height = fill(),
          scrollY = true)):
        ui.button(ScrollItem1, "One", width = fixed(90), height = fixed(40))
        ui.button(ScrollItem2, "Two", width = fixed(90), height = fixed(40))
        ui.button(ScrollItem3, "Three", width = fixed(90), height = fixed(40))
    ui.endLayout()

    check ui.widget(OutsideHeader).frame.y == 0
    check ui.widget(ScrollPanel).frame.y > ui.widget(OutsideHeader).frame.y

  test "short scroll content does not pull footer row upward":
    var ui = UI.init()

    ui.beginLayout(160, 120)
    ui.column(Body, cfg(width = fixed(120), height = fixed(100), gap = 8.0)):
      ui.row(OutsideHeader, cfg(width = fill(), height = fixed(30))):
        ui.button(HeaderNewButton, "Top", width = fixed(40), height = fixed(24))
      ui.panel(ScrollPanel, cfg(width = fill(), height = fill(),
          scrollY = true)):
        ui.button(ScrollItem1, "One", width = fixed(90), height = fixed(20))
      ui.row(OutsideFooter, cfg(width = fill(), height = fixed(20))):
        ui.button(NarrowButton, "New", width = fixed(40), height = fixed(20))
    ui.endLayout()

    checkFrame(ui.widget(OutsideHeader), 0, 0, 120, 30)
    checkFrame(ui.widget(ScrollPanel), 0, 38, 120, 34)
    checkFrame(ui.widget(OutsideFooter), 0, 80, 120, 20)

  test "horizontal scrollbar drag offsets scroll container children":
    var ui = UI.init()

    ui.beginLayout(120, 80)
    ui.panel(ScrollPanel, cfg(width = fixed(100), height = fixed(60),
        scrollX = true)):
      ui.row(ScrollRow, cfg(width = fit(), height = fit(), scrollX = true)):
        ui.button(ScrollItem1, "One", width = fixed(60), height = fixed(30))
        ui.button(ScrollItem2, "Two", width = fixed(60), height = fixed(30))
        ui.button(ScrollItem3, "Three", width = fixed(60), height = fixed(30))
    ui.endLayout()

    checkFrame(ui.widget(ScrollItem1), 0, 0, 60, 30)

    var ctx = UpdateContext(mouseX: 5, mouseY: 55, mouseLeftPressed: true,
        mouseLeftDown: true)
    ui.update(ctx)
    ctx.mouseLeftPressed = false
    ctx.mouseX = 40
    ui.update(ctx)

    ui.reset()
    ui.beginLayout(120, 80)
    ui.panel(ScrollPanel, cfg(width = fixed(100), height = fixed(60),
        scrollX = true)):
      ui.row(ScrollRow, cfg(width = fit(), height = fit(), scrollX = true)):
        ui.button(ScrollItem1, "One", width = fixed(60), height = fixed(30))
        ui.button(ScrollItem2, "Two", width = fixed(60), height = fixed(30))
        ui.button(ScrollItem3, "Three", width = fixed(60), height = fixed(30))
    ui.endLayout()

    check ui.widget(ScrollItem1).frame.x < 0

  test "block layouts add their parent to the enclosing layout":
    var ui = UI.init()
    ui.beginLayout(400, 200)

    ui.column(cfg(gap = 10.0, padding = 10.0)):
      ui.row(Toolbar, cfg(width = fill(), height = fixed(30), gap = 5.0)):
        ui.button(Button1, "One", width = fixed(50), height = fixed(20))
        ui.button(Button2, "Two", width = fixed(60), height = fixed(20))

      ui.row(Body, cfg(width = fill(), height = fill(), gap = 10.0)):
        ui.column(Sidebar, cfg(width = fixed(80), height = fill(), gap = 4.0,
            padding = 4.0)):
          ui.button(Button3, "Three", width = fill(), height = fixed(20))
        ui.column(Content, cfg(width = fill(), height = fill())):
          ui.button(Button4, "Four", width = fixed(70), height = fixed(20))

    ui.endLayout()

    checkFrame(ui.widget(Toolbar), 10, 10, 380, 30)
    checkFrame(ui.widget(Button1), 10, 10, 50, 20)
    checkFrame(ui.widget(Button2), 65, 10, 60, 20)
    checkFrame(ui.widget(Body), 10, 50, 380, 28)
    checkFrame(ui.widget(Sidebar), 10, 50, 80, 28)
    checkFrame(ui.widget(Button3), 14, 54, 72, 20)
    checkFrame(ui.widget(Content), 100, 50, 290, 28)
    checkFrame(ui.widget(Button4), 100, 50, 70, 20)

  test "spacers participate in row layout":
    var ui = UI.init()
    ui.beginLayout(500, 120)

    ui.row(Body, cfg(width = fill(), height = fixed(30), gap = 10.0)):
      ui.column(Sidebar, cfg(width = fixed(100), height = fill())):
        ui.button(Button1, "Left", width = fill(), height = fixed(20))
      ui.spacer(Spacer, width = fill(), height = fill())
      ui.column(Content, cfg(width = prefer(80), height = fill())):
        ui.button(Button2, "Right", width = fixed(80), height = fixed(20))

    ui.endLayout()

    checkFrame(ui.widget(Sidebar), 0, 0, 100, 30)
    checkFrame(ui.widget(Spacer), 110, 0, 300, 30)
    checkFrame(ui.widget(Content), 420, 0, 80, 30)

  test "aligned row helpers center children and allow align self override":
    var ui = UI.init()
    ui.beginLayout(300, 100)

    ui.row(
      Body,
      cfg(width = fill(), height = fixed(80), gap = 10.0, padding = 10.0,
          alignItems = AlignCenter),
    ):
      ui.button(Button1, "One", width = fixed(40), height = fixed(20))
      ui.button(Button2, "Two", width = fixed(40), height = fixed(20),
          alignSelf = AlignEnd)
      ui.button(Button5, "Three", width = fixed(40), height = fixed(20),
          alignSelf = AlignStart)

    ui.endLayout()

    checkFrame(ui.widget(Button1), 10, 30, 40, 20)
    checkFrame(ui.widget(Button2), 60, 50, 40, 20)
    checkFrame(ui.widget(Button5), 110, 10, 40, 20)

  test "row and column layouts justify children on the main axis":
    var ui = UI.init()
    ui.beginLayout(300, 120)

    ui.column(cfg(gap = 10.0)):
      ui.row(
        Body,
        cfg(
          width = fill(),
          height = fixed(40),
          gap = 10.0,
          alignItems = AlignCenter,
          justifyContent = JustifyCenter,
        ),
      ):
        ui.button(Button1, "One", width = fixed(40), height = fixed(20))
        ui.button(Button2, "Two", width = fixed(50), height = fixed(20))
      ui.row(
        Toolbar,
        cfg(
          width = fill(),
          height = fixed(40),
          gap = 10.0,
          alignItems = AlignCenter,
          justifyContent = JustifyEnd,
        ),
      ):
        ui.button(Button3, "Three", width = fixed(40), height = fixed(20))
        ui.button(Button4, "Four", width = fixed(50), height = fixed(20))

    ui.endLayout()

    checkFrame(ui.widget(Button1), 100, 10, 40, 20)
    checkFrame(ui.widget(Button2), 150, 10, 50, 20)
    checkFrame(ui.widget(Button3), 200, 60, 40, 20)
    checkFrame(ui.widget(Button4), 250, 60, 50, 20)

  test "panel wrapper draws a container parent and lays out labels":
    var ui = UI.init()
    ui.beginLayout(400, 300)

    ui.center(CenterBox, fill(), fill()):
      ui.panel(
        Panel1,
        cfg(
          width = fixed(200),
          height = fixed(100),
          gap = 10.0,
          padding = 10.0,
          alignItems = AlignCenter,
          justifyContent = JustifyCenter,
        ),
      ):
        ui.label(Label1, "Counter", width = fixed(80), height = fixed(20))
        ui.label(Label2, "0", width = fixed(80), height = fixed(20))

    ui.endLayout()

    checkFrame(ui.widget(CenterBox), 0, 0, 400, 300)
    checkFrame(ui.widget(Panel1), 100, 100, 200, 100)
    checkFrame(ui.widget(Label1), 160, 125, 80, 20)
    checkFrame(ui.widget(Label2), 160, 155, 80, 20)

  test "crow error dialog layout renders visible widgets":
    let originalFontRelays = fontRelays
    fontRelays = FontRelays(
      openFont: proc(path: string; size: int; metrics: var FontMetrics): Font =
      metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
      Font(size),
      closeFont: proc(f: Font) =
      discard,
      getFontMetrics: proc(f: Font): FontMetrics =
      FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
      measureText: proc(f: Font; text: string): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
      drawText: proc(f: Font; x, y: int; text: string; fg,
          bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    )
    try:
      var ui = UI.init()
      ui.loadFont("font", "", 18)
      check nestApp.layoutCrowErrorDialogForTest(ui,
          """error: missing field: start-label
Stack trace:
  at /tmp/example/main.nest:12:5 in render
  at /tmp/example/main.nest:4:1 in main""", 620, 300)
      check ui.widget(ui.id("_nest_error_dialog")).frame.width == 620
      check ui.widget(ui.id("_nest_error_dialog")).frame.height == 300
      check ui.widget(ui.id("_nest_error_header")).frame.height > 0
      check ui.widget(ui.id("_nest_error_message", "0")).frame.width > 0
    finally:
      fontRelays = originalFontRelays

  test "slot captures can be placed as a list":
    var ui = UI.init()
    ui.beginLayout(240, 100)

    let actions = ui.slot:
      ui.button(Button1, "One", width = fixed(50), height = fixed(20))
      ui.button(Button2, "Two", width = fixed(60), height = fixed(20))

    ui.row(Body, cfg(width = fill(), height = fixed(30), gap = 8.0)):
      ui.container(Panel1, Panel.new(), width = fixed(40), height = fixed(30))
      ui.place(actions)

    ui.endLayout()

    checkFrame(ui.widget(Panel1), 0, 0, 40, 30)
    checkFrame(ui.widget(Button1), 48, 0, 50, 20)
    checkFrame(ui.widget(Button2), 106, 0, 60, 20)

  test "container state can bind typed slot fields":
    var ui = UI.init()
    var header = DialogHeader.new()
    ui.beginLayout(300, 80)

    let left = ui.singleSlot:
      ui.button(Button1, "Left", width = fixed(50), height = fixed(20))
    let right = ui.slot:
      ui.button(Button2, "Right A", width = fixed(60), height = fixed(20))
      ui.button(Button5, "Right B", width = fixed(70), height = fixed(20))

    header.setSlot(header.left, left)
    header.setSlot(header.right, right)

    ui.row(Body, cfg(width = fill(), height = fixed(30), gap = 10.0)):
      ui.place(left)
      ui.spacer(Spacer, width = fill(), height = fixed(1))
      ui.place(right)

    ui.endLayout()

    check header.left == Button1
    check header.right == @[Button2, Button5]
    checkFrame(ui.widget(Button1), 0, 0, 50, 20)
    checkFrame(ui.widget(Button2), 160, 0, 60, 20)
    checkFrame(ui.widget(Button5), 230, 0, 70, 20)

  test "list slot fields can accept a single child":
    var ui = UI.init()
    var card = Card.new()
    ui.beginLayout(180, 80)

    let content = ui.singleSlot:
      ui.button(Button1, "Only", width = fixed(50), height = fixed(20))

    card.setSlot(card.defaultSlot, content)
    ui.place(content)
    ui.endLayout()

    check card.defaultSlot == @[Button1]
    checkFrame(ui.widget(Button1), 0, 0, 50, 20)

  test "layout template resets reusable ui after draw":
    var ui = UI.init()
    var updateContext = UpdateContext(windowWidth: 200, windowHeight: 80)
    var drawContext = DrawContext(
      resources: Resources.new(), palette: Palette.init(), windowWidth: 200,
          windowHeight: 80
    )
    ui.initContext(200, 80)
    drawContext.resources.loadFont("font", "", 18)

    let rootID = ui.root.id

    ui.layout(updateContext, drawContext):
      ui.button(Button1, "One", width = fixed(50), height = fixed(20))

    check ui.root.id == rootID
    check ui.layout.boxes.len == 1
    check ui.components.len == 0

    ui.layout(updateContext, drawContext):
      ui.button(Button2, "Two", width = fixed(60), height = fixed(20))

    check ui.root.id == rootID
    check ui.layout.boxes.len == 1
    check ui.components.len == 0

  test "widget frames remain available after layout reset":
    var ui = UI.init()
    var updateContext = UpdateContext(windowWidth: 200, windowHeight: 80)
    var drawContext = DrawContext(
      resources: Resources.new(), palette: Palette.init(), windowWidth: 200,
          windowHeight: 80
    )
    ui.initContext(200, 80)
    drawContext.resources.loadFont("font", "", 18)

    ui.layout(updateContext, drawContext):
      ui.button(Button1, "One", width = fixed(50), height = fixed(20))

    check ui.layout.boxes.len == 1
    let located = ui.widgetFrame(Button1)
    check located.ok
    check located.frame.width == 50
    check located.frame.height == 20

  test "slider reports immediate drag value from current mouse position":
    var ui = UI.init()
    ui.initContext(200, 80)
    ui.loadFont("font", "", 18)

    ui.layout:
      discard ui.slider(Slider1, 0, 0, 100, fixed(100), fixed(30))

    var dragged = false
    var draggedValue = 0.0
    ui.mouseMove(75, 15)
    ui.mouseDown()

    ui.layout:
      ui.events:
        let value = ui.slider(Slider1, 0, 0, 100, fixed(100), fixed(30))
        if value.active:
          dragged = true
          draggedValue = value.value
      discard ui.slider(Slider1, 0, 0, 100, fixed(100), fixed(30))

    check dragged
    check draggedValue >= 70
    check draggedValue <= 80

  test "event blocks consume the previous frame hit state before layout":
    var ui = UI.init()
    var count = 0
    var updateContext = UpdateContext(windowWidth: 200, windowHeight: 80)
    var drawContext = DrawContext(
      resources: Resources.new(), palette: Palette.init(), windowWidth: 200,
          windowHeight: 80
    )
    drawContext.resources.loadFont("font", "", 18)

    ui.layout(updateContext, drawContext):
      ui.events:
        if drawContext.active(Button1):
          inc count
      ui.button(Button1, "One", width = fixed(50), height = fixed(20))

    check count == 0

    updateContext.mouseX = 10
    updateContext.mouseY = 10
    updateContext.mouseLeftPressed = true
    updateContext.mouseLeftDown = true

    ui.layout(updateContext, drawContext):
      ui.events:
        if drawContext.active(Button1):
          inc count
      ui.button(Button1, "One", width = fixed(50 + count.toFloat),
          height = fixed(20))

    check count == 0
    check drawContext.active(Button1)

    updateContext.mouseLeftPressed = false

    ui.layout(updateContext, drawContext):
      ui.events:
        if drawContext.active(Button1):
          inc count
      ui.button(Button1, "One", width = fixed(50 + count.toFloat),
          height = fixed(20))

    check count == 1

  test "keyed scopes list helpers and edit line state simplify dynamic rows":
    var ui = UI.init()
    var rows = @["alpha", "beta", "gamma"]
    var edit = editLineState()
    var updateContext = UpdateContext(windowWidth: 320, windowHeight: 120)
    var drawContext = DrawContext(
      resources: Resources.new(), palette: Palette.init(), windowWidth: 320,
          windowHeight: 120
    )
    drawContext.resources.loadFont("font", "", 18)

    let filtered = listItems[string](
      rows,
      proc(item: string, index: int): string = listKey(index, item),
      proc(item: string, index: int): bool = item.contains("a"),
    )
    check filtered.len == 3
    check filtered[1].index == 1

    let duplicates = listItems[string](
      @["same", "same"],
      proc(item: string, index: int): string = listKey(index, item),
    )
    check duplicates.len == 2
    check duplicates[0].key != duplicates[1].key

    var scopedID: WidgetID
    ui.scope("row"):
      scopedID = ui.id("edit")
    ui.scope("row"):
      check ui.id("edit") == scopedID

    edit.beginEdit(filtered[1].key, filtered[1].value)
    check edit.editing(filtered[1].key)
    edit.input.text = "changed"
    check edit.saveEdit() == "changed"
    check not edit.editing

    ui.layout(updateContext, drawContext):
      for row in listItems[string](rows, proc(item: string,
          index: int): string = listKey(index, item)):
        ui.scope(row.key):
          discard ui.button("edit", "Edit", fit(), fit())

    var betaEditID: WidgetID
    ui.scope(listKey(1, "beta")):
      betaEditID = ui.id("edit")
    drawContext.activeWidgets.incl betaEditID

    ui.layout(updateContext, drawContext):
      for row in listItems[string](rows, proc(item: string,
          index: int): string = listKey(index, item)):
        ui.scope(row.key):
          if ui.button("edit", "Edit", fit(), fit()):
            edit.beginEdit(row.key, row.value)

    check edit.editing(listKey(1, "beta"))
