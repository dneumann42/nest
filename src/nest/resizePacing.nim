import std/[os, strutils]

type
  ResizeStrategy* = enum
    rsStretch
    rsRetained
    rsPump

  ResizePacerConfig* = object
    settleMs*: int
    pumpFrameMs*: int
    pumpDurationMs*: int

  ResizePacer* = object
    strategy*: ResizeStrategy
    config*: ResizePacerConfig
    pumpUntil*: int
    nextPumpTicks*: int

const DefaultResizePacerConfig* = ResizePacerConfig(
  settleMs: 250,
  pumpFrameMs: 16,
  pumpDurationMs: 250,
)

proc parseResizeStrategy*(value: string): ResizeStrategy =
  case value.normalize
  of "", "pump":
    rsPump
  of "stretch":
    rsStretch
  of "retained":
    rsRetained
  else:
    rsStretch

proc resizeStrategyFromEnv*(): ResizeStrategy =
  parseResizeStrategy(getEnv("NEST_RESIZE_STRATEGY"))

proc init*(
    T: typedesc[ResizePacer],
    strategy = rsPump,
    config = DefaultResizePacerConfig,
): T =
  T(strategy: strategy, config: config)

proc active*(pacer: ResizePacer; now: int): bool =
  pacer.strategy == rsPump and pacer.pumpUntil > now

proc pumpDue*(pacer: ResizePacer; now: int): bool =
  pacer.active(now) and pacer.nextPumpTicks <= now

proc pumpWaitMs*(pacer: ResizePacer; now: int): int =
  if pacer.active(now):
    max(pacer.nextPumpTicks - now, 0)
  else:
    -1

proc mergedWaitMs*(redrawWaitMs, pumpWaitMs: int): int =
  if redrawWaitMs < 0:
    pumpWaitMs
  elif pumpWaitMs < 0:
    redrawWaitMs
  else:
    min(redrawWaitMs, pumpWaitMs)

proc waitMs*(pacer: ResizePacer; now, redrawWaitMs: int): int =
  mergedWaitMs(redrawWaitMs, pacer.pumpWaitMs(now))

proc startedResizePresent*(pacer: var ResizePacer; now: int) =
  if pacer.strategy == rsPump:
    pacer.pumpUntil = now + pacer.config.pumpDurationMs
    pacer.nextPumpTicks = now + pacer.config.pumpFrameMs

proc finishedPumpPresent*(pacer: var ResizePacer; now: int) =
  pacer.nextPumpTicks = now + pacer.config.pumpFrameMs
