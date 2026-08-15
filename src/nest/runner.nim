import std/[os, strutils]

import nest/[
  appConfig,
  owldsl,
  dialogAnchors,
  errorDialogs,
  externalSignals,
  perf,
  projectConfig,
  runtime,
  singleInstance,
  ui,
]

proc needsSingleInstance(config: ProjectConfig; dialogMode: bool): bool =
  not dialogMode and config.layerShell.normalize in ["top", "bottom", "left", "right"]

proc envBenchmarkFrames(): int =
  try:
    parseInt(getEnv("NEST_BENCHMARK_FRAMES", "0"))
  except ValueError:
    0

proc runProject*(
    projectDir: string;
    dialogData = "";
    dialogMode = false;
    dialogResultPath = "";
    dialogAnchor = "";
    perfOptions = PerfOptions();
): string =
  discard dialogResultPath
  let dir = projectDir.normalizedPath
  if not dirExists(dir):
    quit("Nest project directory does not exist: " & projectDir)

  let config = loadProjectConfig(dir)
  let mainPath = projectMainPath(dir, config)
  if not fileExists(mainPath):
    quit("Nest project main file does not exist: " & mainPath)

  let instanceLock =
    if config.needsSingleInstance(dialogMode):
      acquireSingleInstanceLock(config.namespace)
    else:
      SingleInstanceLock()

  var ui = UI.init()
  let app = NestOwlApp.init(mainPath)
  app.runtime.dialogData = dialogData
  installExternalSignalHandlers()
  var
    options = perfOptions
    stats = PerfStats.init()
  if options.benchmarkFrames <= 0:
    options.benchmarkFrames = envBenchmarkFrames()
  options.overlay =
    options.overlay or getEnv("NEST_PERF_OVERLAY").normalize in ["1", "true", "yes"]
  if options.overlay:
    setPerfOverlay(true)
  var cfg = appConfig(config).applyDialogAnchor(parseDialogAnchor(dialogAnchor))
  cfg.perfOptions = options
  if options.benchmarkFrames > 0:
    cfg.alwaysRun60Fps = true
  try:
    application cfg, ui:
      enableExternalSignalWake()
      app.runtime.queuePendingExternalSignals()
      let wasShowingPerf = perfOverlayEnabled()
      if options.benchmarkFrames > 0 or wasShowingPerf:
        ui.markAllDirty()
      app.render(ui)
      let showPerf = perfOverlayEnabled()
      if options.benchmarkFrames > 0 or showPerf:
        stats.recordFrame()
        if showPerf:
          stats.drawOverlay(ui.windowWidth, ui.windowHeight, ui.font())
          ui.requestRedrawAfter(16)
      if app.lastError.len > 0:
        app.launchOwlErrorDialog(app.lastErrorDetails)
      else:
        app.pollOwlErrorDialog()
        app.closeOwlErrorDialog()
      if app.runtime.requestQuit:
        running = false
      if options.benchmarkFrames > 0 and stats.frameCount >=
          options.benchmarkFrames:
        echo stats.summary()
        running = false
  finally:
    result = app.runtime.dialogCloseValue
    app.runtime.closeDialogProcesses()
    app.runtime.closeShellProcesses()
    app.runtime.closeWorkspaceSubscriptions()
    app.closeOwlErrorDialog()
    instanceLock.removeSingleInstanceLock()
