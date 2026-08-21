import std/posix

import nest/owldsl
import nest/layerShellSdl3Driver

const sigUsr1Event* = "sigusr1"

var
  pendingSigUsr1 {.volatile.}: cint
  eventLoopWakeReady {.volatile.}: cint

proc handleSigUsr1(signal: cint) {.noconv.} =
  discard signal
  pendingSigUsr1 = 1
  if eventLoopWakeReady != 0:
    layerShellSdl3Driver.wakeEventLoop()

proc installExternalSignalHandlers*() =
  ## Install the process signal handlers Nest reacts to (`SIGUSR1`).
  discard posix.signal(SIGUSR1, handleSigUsr1)

proc enableExternalSignalWake*() =
  ## Allow the signal handler to wake a blocked event loop.
  ##
  ## Call this once the window and event loop are up, so a signal arriving
  ## before then cannot try to wake a loop that does not exist yet.
  eventLoopWakeReady = 1

proc consumePendingSigUsr1(): bool =
  if pendingSigUsr1 == 0:
    return false
  pendingSigUsr1 = 0
  true

proc queuePendingExternalSignals*(runtime: NestOwlRuntime) =
  ## Forward any signal received since the last call to `runtime` as an
  ## external event.
  if consumePendingSigUsr1():
    runtime.queueExternal(sigUsr1Event)
