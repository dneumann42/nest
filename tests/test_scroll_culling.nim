## Scroll containers must cost what is on screen, and show what is on screen.
##
## Two separate claims, and both are only worth anything if the picture is
## unchanged. Culling skips widgets the backend would have clipped away, so a
## culled frame has to draw exactly what an unculled one drew inside the
## viewport. `virtualColumn` goes further and never declares them, so a
## virtual list has to put its rows where a full one would and scroll over the
## same extent.

import std/[algorithm, strformat, strutils, unittest]

import nest/[coords, palette, resources, screen, ui]

const
  ViewportHeight = 400
  RowHeight = 25.0
  Rows = 400

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

proc rowLabel(index: int): string =
  &"row-{index:04}"

proc plainList(ui: var UI) =
  ui.column(ui.id("panel"), cfg(width = fill(), height = fill(), gap = 0)):
    ui.column(ui.id("list"), cfg(width = fill(), height = fill(), gap = 0,
        scrollY = true, scrollWheel = true, alignItems = Stretch)):
      for i in 0 ..< Rows:
        discard ui.button(ui.id("row", $i), rowLabel(i), width = fill(),
            height = fixed(RowHeight))

proc virtualList(ui: var UI) =
  ui.column(ui.id("panel"), cfg(width = fill(), height = fill(), gap = 0)):
    ui.virtualColumn(ui.id("list"), cfg(width = fill(), height = fill(),
        gap = 0, scrollWheel = true, alignItems = Stretch), Rows, RowHeight):
      discard ui.button(ui.id("row", $index), rowLabel(index), width = fill(),
          height = fixed(RowHeight))

proc newUI(culling = true): UI =
  result = UI.init()
  result.setScrollCulling(culling)
  result.initContext(300, ViewportHeight)
  result.loadFont("font", "", 18)
  result.loadFont("editor", "", 18)
  result.loadFont("icon", "", 18)

proc frame(ui: var UI, virtual: bool, commands: ptr seq[DrawCommand] = nil) =
  ui.beginInputFrame()
  if commands != nil:
    ui.setDrawCommands(commands)
    commands[].setLen(0)
  ui.markAllDirty()
  ui.layout:
    if virtual:
      ui.virtualList()
    else:
      ui.plainList()
  if commands != nil:
    ui.setDrawCommands(nil)
  ui.finishInputFrame()

proc scrollTo(ui: var UI, virtual: bool, target: float64) =
  ## Wheel the list down until it stops moving or reaches `target`.
  for _ in 0 ..< 400:
    if ui.scrollOffset(ui.id("list")).y >= target - 0.5:
      break
    ui.beginInputFrame()
    ui.mouseMove(150, 200)
    ui.mouseWheel(0.0, -4.0)
    ui.layout:
      if virtual:
        ui.virtualList()
      else:
        ui.plainList()
    ui.finishInputFrame()

proc drawnLabels(commands: seq[DrawCommand]): seq[string] =
  for command in commands:
    if command.kind == DrawText and command.text.startsWith("row-"):
      result.add command.text
  result.sort()

proc visibleLabels(ui: UI): seq[string] =
  ## Every row the solver placed inside the list's viewport.
  let list = ui.widgetFrame(ui.id("list"))
  doAssert list.ok
  for i in 0 ..< Rows:
    let row = ui.widgetFrame(ui.id("row", $i))
    if not row.ok:
      continue
    if row.frame.y + row.frame.height > list.frame.y and
        row.frame.y < list.frame.y + list.frame.height:
      result.add rowLabel(i)
  result.sort()

proc close(a, b: float64): bool =
  abs(a - b) < 0.5

suite "scroll culling":
  setup:
    stubFonts()
    stubDrawRelays()

  test "culling draws exactly the rows inside the viewport":
    var ui = newUI()
    var commands: seq[DrawCommand]
    ui.frame(virtual = false)
    ui.frame(virtual = false, commands = addr commands)

    let drawn = drawnLabels(commands)
    let visible = ui.visibleLabels()
    check visible.len > 0
    check visible.len < Rows
    # Every visible row is drawn.
    for label in visible:
      check label in drawn
    # And nothing far outside is: the margin allows a few rows either side,
    # never the other three hundred and fifty.
    check drawn.len <= visible.len + 8

  test "culling draws the same rows an unculled frame does":
    var culled: seq[DrawCommand]
    var whole: seq[DrawCommand]

    block:
      var ui = newUI()
      ui.frame(virtual = false)
      ui.scrollTo(virtual = false, target = 1000.0)
      ui.frame(virtual = false, commands = addr culled)

    block:
      var ui = newUI(culling = false)
      ui.frame(virtual = false)
      ui.scrollTo(virtual = false, target = 1000.0)
      ui.frame(virtual = false, commands = addr whole)

    let
      culledLabels = drawnLabels(culled)
      wholeLabels = drawnLabels(whole)
    check wholeLabels.len == Rows
    check culledLabels.len < wholeLabels.len
    # Everything the culled frame drew, the whole frame drew too, and every
    # row the whole frame put inside the viewport survived the cull.
    for label in culledLabels:
      check label in wholeLabels

  test "a culled row still updates once it is scrolled back into view":
    var ui = newUI()
    ui.frame(virtual = false)
    ui.scrollTo(virtual = false, target = 2000.0)

    # A row near the current offset is placed inside the viewport, and hover
    # has to reach it even though it was culled a moment ago.
    let list = ui.widgetFrame(ui.id("list"))
    check list.ok
    var hovered = ""
    for i in 0 ..< Rows:
      let row = ui.widgetFrame(ui.id("row", $i))
      if row.ok and row.frame.y > list.frame.y + 10 and
          row.frame.y + row.frame.height < list.frame.y + list.frame.height:
        hovered = $i
        break
    check hovered.len > 0

    let row = ui.widgetFrame(ui.id("row", hovered))
    ui.beginInputFrame()
    ui.mouseMove(row.frame.x.toInt + 10, row.frame.y.toInt + 5)
    ui.layout:
      ui.plainList()
    ui.finishInputFrame()
    check ui.pointerOverInteractive(row.frame.x.toInt + 10,
        row.frame.y.toInt + 5)

suite "virtual scroll columns":
  setup:
    stubFonts()
    stubDrawRelays()

  test "a virtual list declares far fewer rows than it has":
    var ui = newUI()
    ui.frame(virtual = true)
    ui.frame(virtual = true)
    var declared = 0
    for i in 0 ..< Rows:
      if ui.widgetFrame(ui.id("row", $i)).ok:
        inc declared
    check declared > 0
    check declared < Rows div 4

  test "a virtual list puts its rows where a full one would":
    for target in [0.0, 500.0, 2500.0, 5000.0]:
      var plain = newUI()
      plain.frame(virtual = false)
      plain.scrollTo(virtual = false, target = target)
      plain.frame(virtual = false)

      var virt = newUI()
      virt.frame(virtual = true)
      virt.scrollTo(virtual = true, target = target)
      virt.frame(virtual = true)

      check close(plain.scrollOffset(plain.id("list")).y,
          virt.scrollOffset(virt.id("list")).y)

      var compared = 0
      for i in 0 ..< Rows:
        let
          a = plain.widgetFrame(plain.id("row", $i))
          b = virt.widgetFrame(virt.id("row", $i))
        if not (a.ok and b.ok):
          continue
        inc compared
        if not (close(a.frame.y, b.frame.y) and
            close(a.frame.height, b.frame.height) and
            close(a.frame.x, b.frame.x) and
            close(a.frame.width, b.frame.width)):
          checkpoint(&"at offset {target} row {i}: full {a.frame} virtual {b.frame}")
          fail()
      check compared > 0

  test "a virtual list scrolls over the whole list":
    # The rows that are not declared are still accounted for, so the last row
    # can be reached and the container stops there.
    var virt = newUI()
    virt.frame(virtual = true)
    virt.scrollTo(virtual = true, target = 1_000_000.0)

    var plain = newUI()
    plain.frame(virtual = false)
    plain.scrollTo(virtual = false, target = 1_000_000.0)

    check close(virt.scrollOffset(virt.id("list")).y,
        plain.scrollOffset(plain.id("list")).y)

    # And the last row is on screen at the bottom, in both.
    let
      list = virt.widgetFrame(virt.id("list"))
      last = virt.widgetFrame(virt.id("row", $(Rows - 1)))
    check list.ok
    check last.ok
    check last.frame.y + last.frame.height <=
      list.frame.y + list.frame.height + 1.0
    check last.frame.y + last.frame.height > list.frame.y

  test "an empty or tiny virtual list is well behaved":
    var ui = newUI()
    check ui.visibleRows(ui.id("list"), 0, RowHeight).count == 0
    check ui.visibleRows(ui.id("list"), 10, 0.0).count == 0
    let rows = ui.visibleRows(ui.id("list"), 3, RowHeight)
    check rows.first == 0
    check rows.count == 3
    check close(rows.leading, 0.0)
    check close(rows.trailing, 0.0)

  test "the declared window covers the viewport at every offset":
    var ui = newUI()
    ui.frame(virtual = true)
    for offset in countup(0, 9000, 137):
      let rows = ui.visibleRows(ui.id("list"), Rows, RowHeight)
      check rows.first >= 0
      check rows.first + rows.count <= Rows
      check close(rows.leading + rows.count.float64 * RowHeight +
          rows.trailing, Rows.float64 * RowHeight)
      ui.scrollTo(virtual = true, target = offset.float64)
