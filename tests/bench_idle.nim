## Idle cost benchmark for owl apps, and for the layer shell bar in
## particular.
##
## A shell bar is up for as long as the session is, so what it costs while
## nothing is happening matters more than what a frame costs. This runs an owl
## app for a few seconds of wall clock with no input at all and counts what it
## did: how often the loop woke, how often it repainted, how often it
## presented, and how much CPU that came to.
##
## The loop below makes the same decisions `runtime.application` makes -- it
## calls the same `redrawRetainedIfClean` -- with the waiting replaced by a
## sleep, so the numbers describe the real scheduler rather than a model of
## it.
##
##   nim c -r -d:release --path:src tests/bench_idle.nim [app] [seconds]
##
## Add `-d:nestBench` for the per-phase breakdown.

import std/[monotimes, os, strformat, strutils, tables]
from std/times import inNanoseconds

import owl

import nest/[bench, coords, input, resources, runtime, screen, ui]
import nest/owldsl

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

var presents = 0

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
  windowRelays.refresh = proc() =
    inc presents

var clockStartNs: int64

proc benchTicks(): int {.nimcall.} =
  int((getMonoTime().ticks - clockStartNs) div 1_000_000)

proc stubClock() =
  ## Nest reads time through the input backend, and no backend is open here.
  clockStartNs = getMonoTime().ticks
  inputRelays.getTicks = benchTicks

proc stubShell(runtime: NestOwlRuntime) =
  ## Shell-outs would dominate the measurement and are not what is being
  ## measured; every one answers instantly with the same text.
  runtime.evaluator.native "shell":
    discard (layout, bodyNodes, arguments, env)
    text("")
  runtime.evaluator.native "shellAsync":
    discard (layout, bodyNodes, arguments, env)
    text("")

type Counts = object
  wakes: int
  appFrames: int
  retainedWakes: int
  maintenanceWakes: int
  presents: int
  cpuMs: float64
  blocked: bool

proc runIdle(mainPath: string, seconds: float64): Counts =
  let app = NestOwlApp.init(mainPath)
  app.runtime.stubShell()
  var ui = UI.init()
  ui.initContext(1920, 34)
  ui.loadFont("font", "", 18)
  ui.loadFont("editor", "", 18)
  ui.loadFont("icon", "", 18)

  # One frame to get the app on screen, as the first loop iteration does.
  ui.beginInputFrame()
  ui.setDrawTicks(input.getTicks())
  app.render(ui)
  ui.finishInputFrame()

  presents = 0
  bench.reset()
  bench.setLabel(mainPath.lastPathPart & " idle")
  let deadlineNs = getMonoTime().ticks + int64(seconds * 1e9)
  var cpuNs: int64 = 0
  while getMonoTime().ticks < deadlineNs:
    let waitMs = ui.redrawDelayMs()
    if waitMs < 0:
      # Nothing is scheduled, so the real loop blocks until the compositor
      # or an external signal wakes it. Nothing here ever will.
      result.blocked = true
      break
    if waitMs > 0:
      os.sleep(min(waitMs, 50))
      if ui.redrawDelayMs() > 0:
        continue
    inc result.wakes
    if ui.maintenanceDue():
      inc result.maintenanceWakes
    let frameStart = getMonoTime()
    bench.frame:
      if ui.redrawRetainedIfClean():
        inc result.retainedWakes
      else:
        ui.clearRedrawRequest()
        inc result.appFrames
        ui.beginInputFrame()
        ui.setDrawTicks(input.getTicks())
        app.render(ui)
        ui.finishInputFrame()
        if ui.redrewFrame():
          refresh()
    cpuNs += (getMonoTime() - frameStart).inNanoseconds
  result.presents = presents
  result.cpuMs = cpuNs.float64 / 1_000_000.0
  app.runtime.closeShellProcesses()
  app.runtime.closeWorkspaceSubscriptions()

proc report(name: string, seconds: float64, counts: Counts) =
  let per = 1.0 / seconds
  echo "  ", name.alignLeft(26),
    (&"{counts.wakes.float64 * per:.1f}").align(10),
    (&"{counts.appFrames.float64 * per:.1f}").align(11),
    (&"{counts.retainedWakes.float64 * per:.1f}").align(11),
    (&"{counts.presents.float64 * per:.1f}").align(11),
    (&"{counts.maintenanceWakes.float64 * per:.1f}").align(11),
    (&"{100.0 * counts.cpuMs / (seconds * 1000.0):.2f}%").align(9),
    (if counts.blocked: "  (went fully idle)" else: "")

proc main() =
  stubFonts()
  stubDrawRelays()
  stubClock()
  let
    appArg =
      if paramCount() >= 1: paramStr(1) else: "apps/layerShellBar/main.owl"
    seconds =
      if paramCount() >= 2:
        try: parseFloat(paramStr(2)) except ValueError: 3.0
      else: 3.0

  echo ""
  echo "  ", "app".alignLeft(26), "wakes/s".align(10), "app/s".align(11),
    "repaint/s".align(11), "present/s".align(11), "maint/s".align(11),
    "cpu".align(9)
  echo "  ", repeat('-', 80)
  for path in [appArg, "apps/counter/main.owl"]:
    if not fileExists(path):
      echo "  ", path, ": missing, skipped"
      continue
    let counts = runIdle(path, seconds)
    report(path.parentDir.lastPathPart, seconds, counts)
    when bench.enabled():
      echo bench.summary()
  echo ""
  bench.finish()

when isMainModule:
  main()
