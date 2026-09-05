## Frame cost of a scrolling list, against the number of rows in it.
##
## A file tree or a buffer list is a scroll container with far more rows in it
## than fit on screen, and the ones that do not fit are the whole question:
## whatever a frame spends on them is spent on nothing a user can see. This
## measures a list at several sizes so the cost per off-screen row is visible,
## and reports it per row as well as per frame.
##
##   nim c -r -d:release --path:src tests/bench_scroll.nim [rows] [frames]
##
## Add `-d:nestBench` for the per-phase breakdown, which is what says whether
## the cost is in declaring the rows, measuring them, hit testing them or
## drawing them.

import std/[monotimes, os, strformat, strutils]
from std/times import inNanoseconds

import nest/[bench, coords, palette, resources, screen, ui]

const
  ViewportHeight = 600
  RowHeight = 26.0

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

var drawnRects = 0

proc countRect(r: Rect, color: Color) {.nimcall.} =
  discard (r, color)
  inc drawnRects

proc stubDrawRelays() =
  drawRelays = DrawRelays(
    fillRect: countRect,
    lineRect: countRect,
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

proc fileTree(ui: var UI, rows: int) =
  ## The shape a file explorer has: a search box over a tall scrolling column
  ## of fixed-height rows.
  ui.column(ui.id("panel"), cfg(width = fill(), height = fill(), gap = 4,
      padding = 6)):
    ui.label(ui.id("search"), "filter", width = fill(), height = fit())
    ui.column(ui.id("tree"), cfg(width = fill(), height = fill(), gap = 0,
        scrollY = true, scrollWheel = true, alignItems = Stretch)):
      for i in 0 ..< rows:
        discard ui.button(ui.id("row", $i), &"  file-{i:05}.nim",
          width = fill(), height = fixed(RowHeight), fontName = "editor")

proc virtualFileTree(ui: var UI, rows: int) =
  ## The same list, declaring only the rows in view.
  ui.column(ui.id("panel"), cfg(width = fill(), height = fill(), gap = 4,
      padding = 6)):
    ui.label(ui.id("search"), "filter", width = fill(), height = fit())
    ui.virtualColumn(ui.id("tree"), cfg(width = fill(), height = fill(),
        gap = 0, scrollWheel = true, alignItems = Stretch), rows, RowHeight):
      discard ui.button(ui.id("row", $index), &"  file-{index:05}.nim",
        width = fill(), height = fixed(RowHeight), fontName = "editor")

proc newUI(): UI =
  result = UI.init()
  result.initContext(420, ViewportHeight)
  result.loadFont("font", "", 18)
  result.loadFont("editor", "", 18)
  result.loadFont("icon", "", 18)

proc frame(ui: var UI, rows: int) =
  bench.frame:
    ui.beginInputFrame()
    ui.layout:
      ui.fileTree(rows)
    ui.finishInputFrame()

proc scrollFrame(ui: var UI, rows: int, wheel: float64) =
  bench.frame:
    ui.beginInputFrame()
    ui.mouseMove(200, 300)
    ui.mouseWheel(0.0, wheel)
    ui.layout:
      ui.fileTree(rows)
    ui.finishInputFrame()

proc virtualFrame(ui: var UI, rows: int) =
  bench.frame:
    ui.beginInputFrame()
    ui.layout:
      ui.virtualFileTree(rows)
    ui.finishInputFrame()

proc virtualScrollFrame(ui: var UI, rows: int, wheel: float64) =
  bench.frame:
    ui.beginInputFrame()
    ui.mouseMove(200, 300)
    ui.mouseWheel(0.0, wheel)
    ui.layout:
      ui.virtualFileTree(rows)
    ui.finishInputFrame()

type Sample = object
  label: string
  rows: int
  msPerFrame: float64
  usPerRow: float64
  rectsPerFrame: int

proc report(samples: seq[Sample]) =
  echo ""
  echo "  ", "scenario".alignLeft(22), "rows".align(8), "ms/frame".align(11),
    "us/row".align(9), "rects/frame".align(13), "fps".align(8)
  echo "  ", repeat('-', 72)
  for s in samples:
    echo "  ", s.label.alignLeft(22), ($s.rows).align(8),
      (&"{s.msPerFrame:.3f}").align(11), (&"{s.usPerRow:.2f}").align(9),
      ($s.rectsPerFrame).align(13),
      (&"{1000.0 / max(s.msPerFrame, 0.0001):.0f}").align(8)
  echo ""

proc measure(
    label: string, rows, frames: int, body: proc(index: int)
): Sample =
  body(0)
  bench.reset()
  bench.setLabel(&"{label} {rows} rows")
  drawnRects = 0
  let start = getMonoTime()
  for index in 1 .. frames:
    body(index)
  let elapsed = (getMonoTime() - start).inNanoseconds.float64 / 1_000_000.0
  when bench.enabled():
    echo bench.summary()
  Sample(
    label: label,
    rows: rows,
    msPerFrame: elapsed / frames.float64,
    usPerRow: elapsed * 1000.0 / (frames.float64 * rows.float64),
    rectsPerFrame: drawnRects div frames,
  )

proc main() =
  stubFonts()
  stubDrawRelays()
  let
    rowCounts =
      if paramCount() >= 1:
        try: @[parseInt(paramStr(1))] except ValueError: @[100, 1000, 5000]
      else: @[100, 1000, 5000]
    frames =
      if paramCount() >= 2:
        try: parseInt(paramStr(2)) except ValueError: 120
      else: 120

  echo &"  viewport {ViewportHeight}px, rows {RowHeight.int}px, " &
    &"so about {int(ViewportHeight.float64 / RowHeight)} rows are visible"

  var samples: seq[Sample]
  for rowsLent in rowCounts:
    let rows = rowsLent
    block:
      var ui = newUI()
      ui.frame(rows)
      samples.add measure("steady", rows, frames, proc(index: int) =
        ui.frame(rows))

    block:
      var ui = newUI()
      ui.frame(rows)
      samples.add measure("scrolling", rows, frames, proc(index: int) =
        ui.scrollFrame(rows, if (index div 40) mod 2 == 0: -3.0 else: 3.0))

    block:
      var ui = newUI()
      ui.virtualFrame(rows)
      samples.add measure("steady, virtual", rows, frames, proc(index: int) =
        ui.virtualFrame(rows))

    block:
      var ui = newUI()
      ui.virtualFrame(rows)
      samples.add measure("scrolling, virtual", rows, frames, proc(index: int) =
        ui.virtualScrollFrame(rows,
          if (index div 40) mod 2 == 0: -3.0 else: 3.0))

  report(samples)
  bench.finish()

when isMainModule:
  main()
