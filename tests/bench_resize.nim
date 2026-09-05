## Frame-cost benchmark for window resize.
##
## A compositor reports a new window size for every pixel of a drag, so the
## cost of one resize frame is the whole story of whether a window resizes
## smoothly. This measures three ways of answering that event against the same
## widget tree:
##
## - `full frame` rebuilds the tree and the constraint system, which is what
##   Nest did for every resize event before the fast path existed.
## - `re-solve` keeps the constraint system the last full frame built and only
##   suggests a new size for the root box.
## - `retained repaint` is the floor: repaint the last frame with no layout
##   work at all, which is what a resize can never be faster than.
##
##   nim c -r -d:release --path:src tests/bench_resize.nim [widgets] [frames]
##
## Add `-d:nestBench` for the per-phase breakdown of each.

import std/[monotimes, os, strformat, strutils]
from std/times import inNanoseconds

import nest/[bench, coords, palette, resources, screen, ui]

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

proc panelTree(ui: var UI, rows, columns: int) =
  ## An editor-shaped tree: a toolbar, a sidebar and a grid of labelled cards.
  ui.column(ui.id("root"), cfg(width = fill(), height = fill(), gap = 4,
      padding = 6)):
    ui.row(ui.id("toolbar"), cfg(width = fill(), height = fit(), gap = 4)):
      for i in 0 ..< 8:
        discard ui.button(ui.id("tool", $i), &"tool {i}")
    ui.row(ui.id("body"), cfg(width = fill(), height = fill(), gap = 6)):
      ui.column(ui.id("sidebar"), cfg(width = fixed(180), height = fill(),
          gap = 2, padding = 4)):
        for i in 0 ..< rows:
          ui.label(ui.id("side", $i), &"item {i}", width = fill(), height = fit())
      ui.column(ui.id("cards"), cfg(width = fill(), height = fill(), gap = 4)):
        # `row` and `column` are widget templates; a loop variable of either
        # name shadows them inside the block.
        for rowIndex in 0 ..< rows:
          ui.row(ui.id("cardRow", $rowIndex), cfg(width = fill(),
              height = fit(), gap = 4)):
            for columnIndex in 0 ..< columns:
              ui.card(ui.id("card", $rowIndex, $columnIndex), cfg(width = fill(),
                  height = fit(), padding = 6, gap = 2)):
                ui.label(ui.id("cardLabel", $rowIndex, $columnIndex),
                    &"card {rowIndex}.{columnIndex}", width = fill(),
                    height = fit())
    ui.row(ui.id("status"), cfg(width = fill(), height = fit(), gap = 8)):
      ui.label(ui.id("statusText"), "ready", width = fit(), height = fit())

proc fullFrame(ui: var UI, rows, columns, width, height: int) =
  ui.beginInputFrame()
  ui.resizeWindow(width, height)
  ui.layout:
    ui.panelTree(rows, columns)
  ui.finishInputFrame()

type Sample = object
  label: string
  msPerFrame: float64
  bytesPerFrame: int
  widgets: int

proc report(samples: seq[Sample]) =
  echo ""
  echo "  ", "resize path".alignLeft(24), "widgets".align(9),
    "ms/frame".align(11), "KB/frame".align(11), "fps".align(9)
  echo "  ", repeat('-', 64)
  for sample in samples:
    echo "  ", sample.label.alignLeft(24), ($sample.widgets).align(9),
      (&"{sample.msPerFrame:.3f}").align(11),
      (&"{sample.bytesPerFrame.float64 / 1024.0:.1f}").align(11),
      (&"{1000.0 / max(sample.msPerFrame, 0.0001):.0f}").align(9)
  echo ""

proc measure(label: string, frames, widgets: int, body: proc(index: int)): Sample =
  body(0)
  bench.reset()
  bench.setLabel(label)
  let
    startMem = getOccupiedMem()
    start = getMonoTime()
  for index in 1 .. frames:
    body(index)
  let
    elapsed = (getMonoTime() - start).inNanoseconds.float64 / 1_000_000.0
    usedMem = getOccupiedMem() - startMem
  when bench.enabled():
    echo bench.summary()
  Sample(
    label: label,
    msPerFrame: elapsed / frames.float64,
    bytesPerFrame: usedMem div frames,
    widgets: widgets,
  )

proc newUI(): UI =
  result = UI.init()
  result.initContext(1200, 800)
  result.loadFont("font", "", 18)
  result.loadFont("editor", "", 18)
  result.loadFont("icon", "", 18)

proc main() =
  stubFonts()
  stubDrawRelays()
  let
    rows =
      if paramCount() >= 1:
        try: parseInt(paramStr(1)) except ValueError: 12
      else: 12
    frames =
      if paramCount() >= 2:
        try: parseInt(paramStr(2)) except ValueError: 300
      else: 300
    columns = 3

  var samples: seq[Sample]
  var widgetCount = 0

  block:
    var ui = newUI()
    ui.fullFrame(rows, columns, 1200, 800)
    widgetCount = ui.widgetCount()
    samples.add measure("full frame", frames, widgetCount, proc(index: int) =
      let step = index mod 200
      ui.fullFrame(rows, columns, 1000 + step * 2, 700 + step))

  block:
    var ui = newUI()
    ui.fullFrame(rows, columns, 1200, 800)
    samples.add measure("re-solve", frames, widgetCount, proc(index: int) =
      let step = index mod 200
      ui.beginInputFrame()
      doAssert ui.resolveRetainedFrame(1000 + step * 2, 700 + step),
        "the re-solve path refused a resize; the benchmark is measuring nothing"
      ui.finishInputFrame())

  block:
    var ui = newUI()
    ui.fullFrame(rows, columns, 1200, 800)
    samples.add measure("retained repaint", frames, widgetCount, proc(index: int) =
      discard index
      ui.beginInputFrame()
      discard ui.drawRetainedFrame()
      ui.finishInputFrame())

  report(samples)
  bench.finish()

when isMainModule:
  main()
