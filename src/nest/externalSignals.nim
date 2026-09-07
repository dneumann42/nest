import nest/owldsl

const sigUsr1Event* = "sigusr1"

when defined(posix) and not defined(windows):
  import std/posix
  import nest/layerShellSdl3Driver

  var
    pendingSigUsr1 {.volatile.}: cint
    pendingSigTerm {.volatile.}: cint
    eventLoopWakeReady {.volatile.}: cint

  proc handleSigUsr1(signal: cint) {.noconv.} =
    discard signal
    pendingSigUsr1 = 1
    if eventLoopWakeReady != 0:
      layerShellSdl3Driver.wakeEventLoopFromSignal()

  proc handleSigTerm(signal: cint) {.noconv.} =
    discard signal
    pendingSigTerm = 1
    if eventLoopWakeReady != 0:
      layerShellSdl3Driver.wakeEventLoopFromSignal()

  proc installExternalSignalHandlers*(gracefulTerminate = false) =
    ## Install the process signal handlers Nest reacts to.
    discard posix.signal(SIGUSR1, handleSigUsr1)
    discard posix.siginterrupt(SIGUSR1, 1)
    if gracefulTerminate:
      discard posix.signal(SIGTERM, handleSigTerm)
      discard posix.siginterrupt(SIGTERM, 1)

  proc enableExternalSignalWake*() =
    ## Allow the signal handler to wake a blocked event loop.
    ##
    ## Call this once the window and event loop are up, so a signal arriving
    ## before then cannot try to wake a loop that does not exist yet.
    layerShellSdl3Driver.enableSignalSafeEventLoopWake()
    eventLoopWakeReady = 1

  proc consumePendingSigUsr1(): bool =
    if pendingSigUsr1 == 0:
      return false
    pendingSigUsr1 = 0
    true

  proc consumePendingTerminate*(): bool =
    if pendingSigTerm == 0:
      return false
    pendingSigTerm = 0
    true

  proc queuePendingExternalSignals*(runtime: NestOwlRuntime) =
    ## Forward any signal received since the last call to `runtime` as an
    ## external event.
    if consumePendingSigUsr1():
      runtime.queueExternal(sigUsr1Event)
else:
  proc installExternalSignalHandlers*(gracefulTerminate = false) =
    ## External POSIX process signals are unavailable on this platform.
    discard gracefulTerminate

  proc enableExternalSignalWake*() =
    ## External POSIX process signals are unavailable on this platform.
    discard

  proc consumePendingTerminate*(): bool =
    ## External POSIX process signals are unavailable on this platform.
    false

  proc queuePendingExternalSignals*(runtime: NestOwlRuntime) =
    ## External POSIX process signals are unavailable on this platform.
    discard runtime
