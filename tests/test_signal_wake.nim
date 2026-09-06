import std/[posix, unittest]

import nest/[appConfig, externalSignals, input]

suite "external signal wake":
  test "SIGUSR1 interrupts an indefinitely idle event loop":
    let cfg = AppConfig.init(width = 64, height = 64)
    discard cfg.initWindow()
    installExternalSignalHandlers()
    enableExternalSignalWake()

    var event: Event
    while pollEvent(event):
      discard

    discard posix.raise(SIGUSR1)
    check waitEvent(event, 500)
    check event.kind == WakeEvent
    shutdown()
