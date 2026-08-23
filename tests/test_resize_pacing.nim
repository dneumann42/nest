import std/[os, unittest]

import nest/layerShellSdl3Driver
import nest/resizePacing

type ResizeStreamResult = object
  resizeEvents: int
  resizePresents: int
  pumpPresents: int

proc countPumpPresents(strategy: ResizeStrategy): int =
  var pacer = ResizePacer.init(strategy)
  pacer.startedResizePresent(0)

  var now = 0
  while true:
    let waitMs = pacer.waitMs(now, -1)
    if waitMs < 0:
      break
    now += waitMs
    if pacer.pumpDue(now):
      inc result
      pacer.finishedPumpPresent(now)
    else:
      break

proc simulateResizeStream(
    strategy: ResizeStrategy; durationMs, eventIntervalMs: int
): ResizeStreamResult =
  var
    pacer = ResizePacer.init(strategy)
    now = 0
    nextResizeEvent = 0

  while now < durationMs:
    if now >= nextResizeEvent:
      inc result.resizeEvents
      inc result.resizePresents
      pacer.startedResizePresent(now)
      nextResizeEvent += eventIntervalMs
      continue

    let
      resizeWaitMs = nextResizeEvent - now
      waitMs = pacer.waitMs(now, resizeWaitMs)
    if waitMs < 0:
      break
    now += waitMs

    if pacer.pumpDue(now):
      inc result.pumpPresents
      pacer.finishedPumpPresent(now)

suite "resize pacing":
  test "normal windows do not default to blocking renderer vsync":
    check renderVsyncSetting(layerShell = false, envValue = "") == 0
    check renderVsyncSetting(layerShell = true, envValue = "") == 1
    check renderVsyncSetting(layerShell = false, envValue = "1") == 1
    check renderVsyncSetting(layerShell = true, envValue = "0") == 0

  test "environment strategy names parse to concrete policies":
    check parseResizeStrategy("stretch") == rsStretch
    check parseResizeStrategy("retained") == rsRetained
    check parseResizeStrategy("pump") == rsPump
    check parseResizeStrategy("") == rsStretch
    check parseResizeStrategy("unknown") == rsStretch

  test "runtime environment defaults to event driven resize presents":
    let
      hadOriginal = existsEnv("NEST_RESIZE_STRATEGY")
      original = getEnv("NEST_RESIZE_STRATEGY")
    delEnv("NEST_RESIZE_STRATEGY")
    try:
      check resizeStrategyFromEnv() == rsStretch
    finally:
      if hadOriginal:
        putEnv("NEST_RESIZE_STRATEGY", original)
      else:
        delEnv("NEST_RESIZE_STRATEGY")

  test "stretch keeps resize presents event driven":
    check countPumpPresents(rsStretch) == 0

  test "pump creates headless 60hz present opportunities after a sparse resize":
    let presents = countPumpPresents(rsPump)
    check presents >= 14
    check presents <= 16

  test "pump timeout composes with app redraw timeout":
    var pacer = ResizePacer.init(rsPump)
    pacer.startedResizePresent(100)

    check pacer.waitMs(100, -1) == 16
    check pacer.waitMs(100, 40) == 16
    check pacer.waitMs(100, 5) == 5
    check not pacer.pumpDue(105)
    check pacer.pumpDue(116)

  test "headless stream reproduces sparse resize slowness":
    let
      nideLike = simulateResizeStream(rsStretch, durationMs = 1000,
          eventIntervalMs = 125)
      duckLike = simulateResizeStream(rsStretch, durationMs = 1000,
          eventIntervalMs = 16)
      pumpedNideLike = simulateResizeStream(rsPump, durationMs = 1000,
          eventIntervalMs = 125)

    check nideLike.resizeEvents == 8
    check nideLike.resizePresents == 8
    check duckLike.resizePresents >= 60
    check pumpedNideLike.resizeEvents == nideLike.resizeEvents
    check pumpedNideLike.resizePresents + pumpedNideLike.pumpPresents >= 55
