## The resize fast path must be indistinguishable from a full frame.
##
## `resolveRetainedFrame` re-solves the constraint system the last full frame
## built instead of rebuilding it. That is only a safe thing to do if it lands
## every widget in exactly the same place a rebuild would have, so these tests
## solve the same tree both ways and compare the frames widget by widget.

import std/[strformat, unittest]

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

proc newUI(width, height: int): UI =
  result = UI.init()
  result.initContext(width, height)
  result.loadFont("font", "", 18)
  result.loadFont("editor", "", 18)
  result.loadFont("icon", "", 18)

proc appTree(ui: var UI) =
  ## A tree with one of everything the fast path has to get right: fills that
  ## share leftover space, a fixed sidebar, `fit` leaves whose size comes from
  ## measured text, a scroll container, and a centred floating dialog that the
  ## solver does not place.
  ui.column(ui.id("root"), cfg(width = fill(), height = fill(), gap = 4,
      padding = 6)):
    ui.row(ui.id("toolbar"), cfg(width = fill(), height = fit(), gap = 4)):
      for i in 0 ..< 5:
        discard ui.button(ui.id("tool", $i), &"tool {i}")
      ui.spacer(ui.id("toolSpacer"), width = fill(), height = fixed(1))
      ui.label(ui.id("toolRight"), "right", width = fit(), height = fit())
    ui.row(ui.id("body"), cfg(width = fill(), height = fill(), gap = 6)):
      ui.column(ui.id("sidebar"), cfg(width = fixed(180), height = fill(),
          gap = 2, padding = 4, scrollY = true)):
        for i in 0 ..< 12:
          ui.label(ui.id("side", $i), &"sidebar entry {i}", width = fill(),
              height = fit())
      ui.column(ui.id("cards"), cfg(width = fill(), height = fill(), gap = 4)):
        for rowIndex in 0 ..< 6:
          ui.row(ui.id("cardRow", $rowIndex), cfg(width = fill(),
              height = fit(), gap = 4)):
            for columnIndex in 0 ..< 3:
              ui.card(ui.id("card", $rowIndex, $columnIndex),
                  cfg(width = fill(), height = fit(), padding = 6, gap = 2)):
                ui.label(ui.id("cardLabel", $rowIndex, $columnIndex),
                    &"card {rowIndex}.{columnIndex}", width = fill(),
                    height = fit())
    ui.row(ui.id("status"), cfg(width = fill(), height = fit(), gap = 8)):
      ui.label(ui.id("statusText"), "ready", width = fit(), height = fit())
      ui.spacer(ui.id("statusSpacer"), width = fill(), height = fixed(1))
      ui.label(ui.id("statusRight"), "ln 1, col 1", width = fit(),
          height = fit())
  ui.modalDialog(ui.id("dialog"), true, cfg(width = fixed(320),
      height = fit(), padding = 12, gap = 6)):
    ui.label(ui.id("dialogTitle"), "Confirm", width = fill(), height = fit())
    discard ui.button(ui.id("dialogOk"), "OK")

proc fullFrame(ui: var UI, width, height: int) =
  ui.beginInputFrame()
  ui.resizeWindow(width, height)
  ui.layout:
    ui.appTree()
  ui.finishInputFrame()

iterator trackedIDs(ui: UI): (string, WidgetID) =
  yield ("root", ui.id("root"))
  yield ("toolbar", ui.id("toolbar"))
  yield ("toolSpacer", ui.id("toolSpacer"))
  yield ("toolRight", ui.id("toolRight"))
  yield ("body", ui.id("body"))
  yield ("sidebar", ui.id("sidebar"))
  yield ("cards", ui.id("cards"))
  yield ("status", ui.id("status"))
  yield ("statusText", ui.id("statusText"))
  yield ("statusRight", ui.id("statusRight"))
  yield ("dialog", ui.id("dialog"))
  yield ("dialogTitle", ui.id("dialogTitle"))
  for i in 0 ..< 5:
    yield (&"tool{i}", ui.id("tool", $i))
  for i in 0 ..< 12:
    yield (&"side{i}", ui.id("side", $i))
  for rowIndex in 0 ..< 6:
    yield (&"cardRow{rowIndex}", ui.id("cardRow", $rowIndex))
    for columnIndex in 0 ..< 3:
      yield (&"card{rowIndex}.{columnIndex}", ui.id("card", $rowIndex,
          $columnIndex))
      yield (&"cardLabel{rowIndex}.{columnIndex}", ui.id("cardLabel",
          $rowIndex, $columnIndex))

proc frames(ui: UI): seq[(string, Frame)] =
  for (name, id) in ui.trackedIDs:
    let found = ui.widgetFrame(id)
    doAssert found.ok, "widget " & name & " is missing from the solved layout"
    result.add (name, found.frame)

proc close(a, b: float64): bool =
  abs(a - b) < 0.5

suite "resize fast path":
  setup:
    stubFonts()
    stubDrawRelays()

  test "a re-solve lands every widget where a rebuild would":
    for (width, height) in [(640, 480), (1600, 1000), (900, 300), (1200, 800)]:
      var rebuilt = newUI(1200, 800)
      rebuilt.fullFrame(1200, 800)
      rebuilt.fullFrame(width, height)

      var resolved = newUI(1200, 800)
      resolved.fullFrame(1200, 800)
      check resolved.resolveRetainedFrame(width, height)

      let
        expected = rebuilt.frames()
        actual = resolved.frames()
      check expected.len == actual.len
      for i in 0 ..< min(expected.len, actual.len):
        let
          (name, want) = expected[i]
          (otherName, got) = actual[i]
        check name == otherName
        if not (close(want.x, got.x) and close(want.y, got.y) and
            close(want.width, got.width) and close(want.height, got.height)):
          checkpoint(&"{width}x{height} {name}: rebuilt {want} re-solved {got}")
          fail()

  test "repeated re-solves do not drift from a rebuild":
    # A resize drag is a stream of sizes against one constraint system, so a
    # re-solve has to be as good on its hundredth suggestion as on its first.
    var resolved = newUI(1200, 800)
    resolved.fullFrame(1200, 800)
    for step in 0 ..< 120:
      check resolved.resolveRetainedFrame(700 + step * 5, 500 + step * 3)

    var rebuilt = newUI(1200, 800)
    rebuilt.fullFrame(1200, 800)
    rebuilt.fullFrame(700 + 119 * 5, 500 + 119 * 3)

    let
      expected = rebuilt.frames()
      actual = resolved.frames()
    for i in 0 ..< min(expected.len, actual.len):
      let
        (name, want) = expected[i]
        (_, got) = actual[i]
      if not (close(want.x, got.x) and close(want.y, got.y) and
          close(want.width, got.width) and close(want.height, got.height)):
        checkpoint(&"after 120 re-solves {name}: rebuilt {want} re-solved {got}")
        fail()

  test "a re-solve is refused before any frame has been solved":
    var ui = newUI(800, 600)
    check not ui.canResolveRetained()
    check not ui.resolveRetainedFrame(640, 480)

  test "a re-solve is refused while a widget is being interacted with":
    var ui = newUI(1200, 800)
    ui.fullFrame(1200, 800)
    check ui.canResolveRetained()

    ui.beginInputFrame()
    ui.mouseMove(60, 30)
    ui.mouseDown()
    ui.layout:
      ui.appTree()
    ui.finishInputFrame()
    check not ui.canResolveRetained()
    check not ui.resolveRetainedFrame(640, 480)

  test "a re-solve after a frame that reused the solver still agrees":
    # A frame whose tree was unchanged keeps the previous frame's constraint
    # system and only its own boxes, so the two are no longer the same object.
    # A resize that arrives next has to solve in the one holding the
    # constraints and copy the answer into the one holding the widgets.
    var resolved = newUI(1200, 800)
    resolved.fullFrame(1200, 800)
    resolved.fullFrame(1200, 800)
    check resolved.reusedLayout()
    check resolved.resolveRetainedFrame(760, 520)

    var rebuilt = newUI(1200, 800)
    rebuilt.setLayoutReuse(false)
    rebuilt.fullFrame(1200, 800)
    rebuilt.fullFrame(760, 520)

    let
      expected = rebuilt.frames()
      actual = resolved.frames()
    check expected.len == actual.len
    for i in 0 ..< min(expected.len, actual.len):
      let
        (name, want) = expected[i]
        (_, got) = actual[i]
      if not (close(want.x, got.x) and close(want.y, got.y) and
          close(want.width, got.width) and close(want.height, got.height)):
        checkpoint(&"after a reused frame {name}: rebuilt {want} re-solved {got}")
        fail()

  test "a full frame after a re-solve still agrees with the re-solve":
    # The settle frame at the end of a resize must not make the window jump.
    var ui = newUI(1200, 800)
    ui.fullFrame(1200, 800)
    check ui.resolveRetainedFrame(820, 540)
    let afterResolve = ui.frames()
    ui.fullFrame(820, 540)
    let afterRebuild = ui.frames()
    for i in 0 ..< min(afterResolve.len, afterRebuild.len):
      let
        (name, want) = afterResolve[i]
        (_, got) = afterRebuild[i]
      if not (close(want.x, got.x) and close(want.y, got.y) and
          close(want.width, got.width) and close(want.height, got.height)):
        checkpoint(&"settle frame moved {name}: {want} then {got}")
        fail()
