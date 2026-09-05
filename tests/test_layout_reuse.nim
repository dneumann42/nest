## Reusing the previous frame's solver must lay the window out identically.
##
## A frame whose widget tree, size policies and measured content are the same
## as the last one produces exactly the same constraints, so Nest keeps the
## solver rather than rebuilding a tableau that costs more per constraint the
## larger it gets. The whole optimisation rests on "exactly the same", so
## every test here runs a scenario twice -- once with reuse on and once with
## it off -- and fails on any widget that lands somewhere different.

import std/[strformat, strutils, unittest]

import nest/[coords, palette, resources, screen, ui]

proc stubFonts() =
  fontRelays = FontRelays(
    openFont: proc(path: string, size: int, metrics: var FontMetrics): Font =
    discard path
    metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
    Font(max(size, 1)),
    closeFont: proc(f: Font) =
    discard f,
    getFontMetrics: proc(f: Font): FontMetrics =
    discard f
    FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
    measureText: proc(f: Font, text: string): TextExtent =
    discard f
    TextExtent(w: max(text.len, 1) * 9, h: 18),
    drawText: proc(f: Font, x, y: int, text: string, fg, bg: Color): TextExtent =
    discard (f, x, y, fg, bg)
    TextExtent(w: max(text.len, 1) * 9, h: 18),
  )

proc stubDrawRelays() =
  drawRelays = DrawRelays(
    fillRect: proc(r: Rect, color: Color) =
    discard (r, color),
    lineRect: proc(r: Rect, color: Color) =
    discard (r, color),
    drawLine: proc(x1, y1, x2, y2: int, color: Color) =
    discard (x1, y1, x2, y2, color),
    drawPoint: proc(x, y: int, color: Color) =
    discard (x, y, color),
    loadImage: proc(path: string): Image =
    discard path
    Image(1),
    freeImage: proc(img: Image) =
    discard img,
    drawImage: proc(img: Image, src, dst: Rect) =
    discard (img, src, dst),
    drawImageOpacity: proc(img: Image, src, dst: Rect, opacity: float64) =
    discard (img, src, dst, opacity),
    imageSize: proc(img: Image): TextExtent =
    discard img
    TextExtent(w: 32, h: 32),
  )

type Scene = object
  ## Everything a frame can vary that the signature has to notice.
  rows: int
  label: string
  wide: bool
  dialogOpen: bool
  sidebarWidth: float64

proc scene(rows = 5, label = "item", wide = false, dialogOpen = false,
    sidebarWidth = 180.0): Scene =
  Scene(rows: rows, label: label, wide: wide, dialogOpen: dialogOpen,
      sidebarWidth: sidebarWidth)

proc appTree(ui: var UI, s: Scene) =
  ui.column(ui.id("root"), cfg(width = fill(), height = fill(), gap = 4,
      padding = 6)):
    ui.row(ui.id("toolbar"), cfg(width = fill(), height = fit(), gap = 4)):
      for i in 0 ..< 4:
        discard ui.button(ui.id("tool", $i), &"tool {i}")
      ui.spacer(ui.id("toolSpacer"), width = fill(), height = fixed(1))
      ui.label(ui.id("toolRight"), s.label, width = fit(), height = fit())
    ui.row(ui.id("body"), cfg(width = fill(), height = fill(), gap = 6)):
      ui.column(ui.id("sidebar"), cfg(width = fixed(s.sidebarWidth),
          height = fill(), gap = 2, padding = 4, scrollY = true)):
        for i in 0 ..< s.rows:
          ui.label(ui.id("side", $i), &"{s.label} {i}", width = fill(),
              height = fit())
      ui.column(ui.id("cards"), cfg(width = fill(), height = fill(), gap = 4)):
        for rowIndex in 0 ..< s.rows:
          ui.row(ui.id("cardRow", $rowIndex), cfg(
              width = (if s.wide: fill() else: fit()), height = fit(),
              gap = 4)):
            for columnIndex in 0 ..< 3:
              ui.card(ui.id("card", $rowIndex, $columnIndex),
                  cfg(width = fill(), height = fit(), padding = 6, gap = 2)):
                ui.label(ui.id("cardLabel", $rowIndex, $columnIndex),
                    &"card {rowIndex}.{columnIndex}", width = fill(),
                    height = fit())
    ui.row(ui.id("status"), cfg(width = fill(), height = fit(), gap = 8)):
      ui.label(ui.id("statusText"), s.label, width = fit(), height = fit())
  if s.dialogOpen:
    ui.modalDialog(ui.id("dialog"), true, cfg(width = fixed(320),
        height = fit(), padding = 12, gap = 6)):
      ui.label(ui.id("dialogTitle"), "Confirm", width = fill(), height = fit())
      discard ui.button(ui.id("dialogOk"), "OK")

proc newUI(width, height: int, reuse: bool): UI =
  result = UI.init()
  result.initContext(width, height)
  result.loadFont("font", "", 18)
  result.loadFont("editor", "", 18)
  result.loadFont("icon", "", 18)
  result.setLayoutReuse(reuse)

proc frame(ui: var UI, s: Scene, width, height: int) =
  ui.beginInputFrame()
  ui.resizeWindow(width, height)
  ui.layout:
    ui.appTree(s)
  ui.finishInputFrame()

iterator trackedIDs(ui: UI, s: Scene): (string, WidgetID) =
  yield ("root", ui.id("root"))
  yield ("toolbar", ui.id("toolbar"))
  yield ("toolSpacer", ui.id("toolSpacer"))
  yield ("toolRight", ui.id("toolRight"))
  yield ("body", ui.id("body"))
  yield ("sidebar", ui.id("sidebar"))
  yield ("cards", ui.id("cards"))
  yield ("status", ui.id("status"))
  yield ("statusText", ui.id("statusText"))
  for i in 0 ..< 4:
    yield (&"tool{i}", ui.id("tool", $i))
  for i in 0 ..< s.rows:
    yield (&"side{i}", ui.id("side", $i))
  for rowIndex in 0 ..< s.rows:
    yield (&"cardRow{rowIndex}", ui.id("cardRow", $rowIndex))
    for columnIndex in 0 ..< 3:
      yield (&"card{rowIndex}.{columnIndex}", ui.id("card", $rowIndex,
          $columnIndex))
      yield (&"cardLabel{rowIndex}.{columnIndex}", ui.id("cardLabel",
          $rowIndex, $columnIndex))
  if s.dialogOpen:
    yield ("dialog", ui.id("dialog"))
    yield ("dialogTitle", ui.id("dialogTitle"))

proc frames(ui: UI, s: Scene): seq[(string, Frame)] =
  for (name, id) in ui.trackedIDs(s):
    let found = ui.widgetFrame(id)
    doAssert found.ok, "widget " & name & " is missing from the solved layout"
    result.add (name, found.frame)

proc close(a, b: float64): bool =
  abs(a - b) < 0.5

type Step = object
  s: Scene
  width, height: int

proc step(s: Scene, width = 1200, height = 800): Step =
  Step(s: s, width: width, height: height)

proc runSteps(steps: openArray[Step], reuse: bool): seq[(string, Frame)] =
  var ui = newUI(1200, 800, reuse)
  for st in steps:
    ui.frame(st.s, st.width, st.height)
  ui.frames(steps[^1].s)

proc checkSame(name: string, steps: openArray[Step]) =
  let
    rebuilt = runSteps(steps, reuse = false)
    reused = runSteps(steps, reuse = true)
  doAssert rebuilt.len == reused.len
  for i in 0 ..< rebuilt.len:
    let
      (widget, want) = rebuilt[i]
      (_, got) = reused[i]
    if not (close(want.x, got.x) and close(want.y, got.y) and
        close(want.width, got.width) and close(want.height, got.height)):
      checkpoint(&"{name} {widget}: rebuilt {want} reused {got}")
      fail()

suite "layout solver reuse":
  setup:
    stubFonts()
    stubDrawRelays()

  test "an unchanged tree reuses the solver":
    var ui = newUI(1200, 800, reuse = true)
    ui.frame(scene(), 1200, 800)
    check not ui.reusedLayout()
    ui.frame(scene(), 1200, 800)
    check ui.reusedLayout()

  test "reuse is not attempted when it is turned off":
    var ui = newUI(1200, 800, reuse = false)
    ui.frame(scene(), 1200, 800)
    ui.frame(scene(), 1200, 800)
    check not ui.reusedLayout()

  test "an unchanged tree lays out as a rebuild would":
    checkSame("steady", [step(scene()), step(scene()), step(scene())])

  test "a resize reuses the solver and still matches a rebuild":
    var ui = newUI(1200, 800, reuse = true)
    ui.frame(scene(), 1200, 800)
    ui.frame(scene(), 640, 480)
    check ui.reusedLayout()
    checkSame("resize", [
      step(scene(), 1200, 800),
      step(scene(), 640, 480),
      step(scene(), 1600, 1000),
      step(scene(), 900, 300),
    ])

  test "adding and removing widgets rebuilds and still matches":
    var ui = newUI(1200, 800, reuse = true)
    ui.frame(scene(rows = 5), 1200, 800)
    ui.frame(scene(rows = 5), 1200, 800)
    check ui.reusedLayout()
    ui.frame(scene(rows = 9), 1200, 800)
    check not ui.reusedLayout()
    checkSame("grow", [
      step(scene(rows = 5)), step(scene(rows = 5)), step(scene(rows = 9)),
      step(scene(rows = 2)), step(scene(rows = 9)),
    ])

  test "changing measured text rebuilds and still matches":
    # A `fit` widget is constrained to what it measured, so text that got
    # longer is a different constraint system even though the tree is the
    # same shape.
    var ui = newUI(1200, 800, reuse = true)
    ui.frame(scene(label = "item"), 1200, 800)
    ui.frame(scene(label = "item"), 1200, 800)
    check ui.reusedLayout()
    ui.frame(scene(label = "a much longer item label"), 1200, 800)
    check not ui.reusedLayout()
    checkSame("text", [
      step(scene(label = "item")),
      step(scene(label = "a much longer item label")),
      step(scene(label = "x")),
    ])

  test "changing a size policy rebuilds and still matches":
    var ui = newUI(1200, 800, reuse = true)
    ui.frame(scene(wide = false), 1200, 800)
    ui.frame(scene(wide = false), 1200, 800)
    check ui.reusedLayout()
    ui.frame(scene(wide = true), 1200, 800)
    check not ui.reusedLayout()
    checkSame("policy", [
      step(scene(wide = false)), step(scene(wide = true)),
      step(scene(wide = false)),
    ])

  test "changing a fixed size rebuilds and still matches":
    var ui = newUI(1200, 800, reuse = true)
    ui.frame(scene(sidebarWidth = 180.0), 1200, 800)
    ui.frame(scene(sidebarWidth = 180.0), 1200, 800)
    check ui.reusedLayout()
    ui.frame(scene(sidebarWidth = 260.0), 1200, 800)
    check not ui.reusedLayout()
    checkSame("fixed", [
      step(scene(sidebarWidth = 180.0)), step(scene(sidebarWidth = 260.0)),
      step(scene(sidebarWidth = 90.0)),
    ])

  test "opening a floating dialog rebuilds and still matches":
    var ui = newUI(1200, 800, reuse = true)
    ui.frame(scene(), 1200, 800)
    ui.frame(scene(), 1200, 800)
    check ui.reusedLayout()
    ui.frame(scene(dialogOpen = true), 1200, 800)
    check not ui.reusedLayout()
    checkSame("dialog", [
      step(scene()), step(scene(dialogOpen = true)),
      step(scene(dialogOpen = true)), step(scene()),
    ])

  test "a long interleaved session never drifts from a rebuild":
    var steps: seq[Step]
    for i in 0 ..< 60:
      steps.add step(
        scene(
          rows = 3 + i mod 5,
          label = repeat("x", 1 + i mod 7),
          wide = (i mod 3 == 0),
          dialogOpen = (i mod 4 == 0),
          sidebarWidth = 140.0 + (i mod 3).float64 * 40.0,
        ),
        800 + i * 7,
        500 + i * 4,
      )
    checkSame("interleaved", steps)
