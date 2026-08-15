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
  discard posix.signal(SIGUSR1, handleSigUsr1)

proc enableExternalSignalWake*() =
  eventLoopWakeReady = 1

proc consumePendingSigUsr1(): bool =
  if pendingSigUsr1 == 0:
    return false
  pendingSigUsr1 = 0
  true

proc queuePendingExternalSignals*(runtime: NestOwlRuntime) =
  if consumePendingSigUsr1():
    runtime.queueExternal(sigUsr1Event)
