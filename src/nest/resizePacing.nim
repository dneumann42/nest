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
  # The pump exists to keep pixels going to the compositor while a surface is
  # being resized, and it stops when the resize settles. Running it for a
  # second past the last resize event was a second of 60hz presents that
  # nothing had asked for, which an idle window paid for every time it was
  # touched.
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

var resizeFastPathFlag = -1

proc resizeFastPathAllowed*(configured: bool): bool =
  ## Whether a resize may re-solve the retained layout instead of rebuilding.
  ##
  ## `NEST_RESIZE_FAST_PATH` overrides the application's own setting either
  ## way, so a slow resize can be bisected without rebuilding.
  if resizeFastPathFlag < 0:
    let raw = getEnv("NEST_RESIZE_FAST_PATH").normalize
    resizeFastPathFlag =
      case raw
      of "": 2
      of "0", "false", "no", "off": 0
      else: 1
  case resizeFastPathFlag
  of 0: false
  of 1: true
  else: configured

var pointerFastPathFlag = -1

proc pointerFastPathAllowed*(configured: bool): bool =
  ## Whether pointer motion may be answered from the retained frame.
  ##
  ## `NEST_POINTER_FAST_PATH` overrides the application's own setting either
  ## way, the same as `NEST_RESIZE_FAST_PATH` does for resizing.
  if pointerFastPathFlag < 0:
    let raw = getEnv("NEST_POINTER_FAST_PATH").normalize
    pointerFastPathFlag =
      case raw
      of "": 2
      of "0", "false", "no", "off": 0
      else: 1
  case pointerFastPathFlag
  of 0: false
  of 1: true
  else: configured

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

proc settledResize*(pacer: var ResizePacer) =
  ## Stop pumping: the resize is over and the settle frame has been drawn.
  pacer.pumpUntil = 0
  pacer.nextPumpTicks = 0
