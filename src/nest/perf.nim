import std/strformat

import nest/[coords, input, screen]

const
  DefaultHistorySize* = 240
  DefaultAverageWindow* = 60

type
  PerfOptions* = object
    overlay*: bool
    benchmarkFrames*: int

  PerfStats* = object
    samples: seq[float64]
    head: int
    filled: bool
    lastTicks: int
    frameCount*: int
    minDt*, maxDt*, totalDt*: float64

var overlayEnabled: bool

proc enabled*(options: PerfOptions): bool =
  options.overlay or options.benchmarkFrames > 0

proc perfOverlayEnabled*(): bool =
  overlayEnabled

proc setPerfOverlay*(enabled: bool) =
  overlayEnabled = enabled

proc togglePerfOverlay*(): bool =
  overlayEnabled = not overlayEnabled
  overlayEnabled

proc init*(T: typedesc[PerfStats], historySize = DefaultHistorySize): T =
  T(samples: newSeq[float64](max(historySize, 1)))

proc recordFrame*(stats: var PerfStats; ticks = input.getTicks()) =
  if stats.lastTicks == 0:
    stats.lastTicks = ticks
    return
  let dt = max((ticks - stats.lastTicks).float64 / 1000.0, 0.000_001)
  stats.lastTicks = ticks
  stats.samples[stats.head] = dt
  stats.head = (stats.head + 1) mod stats.samples.len
  stats.filled = stats.filled or stats.head == 0
  inc stats.frameCount
  stats.totalDt += dt
  if stats.frameCount == 1 or dt < stats.minDt:
    stats.minDt = dt
  if dt > stats.maxDt:
    stats.maxDt = dt

proc sampleCount(stats: PerfStats): int =
  if stats.filled:
    stats.samples.len
  else:
    stats.head

proc sampleAt(stats: PerfStats; index: int): float64 =
  let count = stats.sampleCount
  if index < 0 or index >= count:
    return 0
  let offset =
    if stats.filled:
      (stats.head + index) mod stats.samples.len
    else:
      index
  stats.samples[offset]

proc fps*(dt: float64): float64 =
  if dt <= 0:
    0
  else:
    1.0 / dt

proc latestFps*(stats: PerfStats): float64 =
  let count = stats.sampleCount
  if count == 0:
    0
  else:
    fps(stats.sampleAt(count - 1))

proc averageFps*(stats: PerfStats; window = DefaultAverageWindow): float64 =
  let count = stats.sampleCount
  if count == 0:
    return 0
  let first = max(count - max(window, 1), 0)
  var total = 0.0
  for i in first ..< count:
    total += stats.sampleAt(i)
  if total <= 0:
    0
  else:
    (count - first).float64 / total

proc summary*(stats: PerfStats): string =
  let avg =
    if stats.totalDt > 0:
      stats.frameCount.float64 / stats.totalDt
    else:
      0.0
  let avgFrameMs = stats.totalDt * 1000.0 / max(stats.frameCount, 1).float64
  &"frames={stats.frameCount} avgFps={avg:.1f} latestFps={stats.latestFps():.1f} avgFrameMs={avgFrameMs:.2f} minFrameMs={stats.minDt * 1000.0:.2f} maxFrameMs={stats.maxDt * 1000.0:.2f}"

proc drawOverlay*(stats: PerfStats; windowWidth, windowHeight: int; font: Font) =
  let
    panelW = min(260, max(windowWidth - 16, 120))
    panelH = 116
    x = max(windowWidth - panelW - 8, 8)
    y = 8
    bg = color(18, 22, 24, 218)
    grid = color(64, 72, 76, 190)
    line = color(103, 211, 165)
    text = color(234, 239, 236)
    muted = color(158, 170, 166)
  fillRect(rect(x, y, panelW, panelH), bg)
  lineRect(rect(x, y, panelW, panelH), grid)
  discard drawText(
    font,
    x + 10,
    y + 8,
    &"FPS {stats.latestFps():.1f}  avg {stats.averageFps():.1f}",
    text,
    color(0, 0, 0, 0),
  )
  discard drawText(
    font,
    x + 10,
    y + 30,
    &"frame {(if stats.latestFps > 0: 1000.0 / stats.latestFps else: 0):.2f}ms",
    muted,
    color(0, 0, 0, 0),
  )

  let
    left = x + 10
    top = y + 58
    right = x + panelW - 10
    bottom = y + panelH - 12
    w = max(right - left, 1)
    h = max(bottom - top, 1)
    count = stats.sampleCount
  for i in 0 .. 3:
    let gy = top + h * i div 3
    drawLine(left, gy, right, gy, grid)
  if count > 1:
    var
      prevX = left
      prevY = bottom - min(stats.sampleAt(0).fps, 120.0).int * h div 120
    for i in 1 ..< count:
      let
        sx = left + i * w div max(count - 1, 1)
        sy = bottom - min(stats.sampleAt(i).fps, 120.0).int * h div 120
      drawLine(prevX, prevY, sx, sy, line)
      prevX = sx
      prevY = sy
