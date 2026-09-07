import std/[json, os, strutils]

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
when defined(linux):
  import nest/tray

proc needsSingleInstance(config: ProjectConfig; dialogMode: bool): bool =
  not dialogMode and config.layerShell.normalize in ["top", "bottom", "left", "right"]

proc envBenchmarkFrames(): int =
  try:
    parseInt(getEnv("NEST_BENCHMARK_FRAMES", "0"))
  except ValueError:
    0

type DialogOptions* = object
  dismissOnInactive*: bool
  inactiveGraceMs*: int

proc parseDialogOptions*(value: string): DialogOptions =
  result.inactiveGraceMs = 350
  if value.len == 0:
    return
  try:
    let parsed = parseJson(value)
    if parsed.hasKey("dismissOnInactive"):
      result.dismissOnInactive = parsed["dismissOnInactive"].getBool(false)
    if parsed.hasKey("inactiveGraceMs"):
      result.inactiveGraceMs = max(parsed["inactiveGraceMs"].getInt(350), 0)
  except JsonParsingError:
    discard
  except KeyError:
    discard

proc runProject*(
    projectDir: string;
    dialogData = "";
    dialogMode = false;
    dialogResultPath = "";
    dialogAnchor = "";
    dialogOptions = DialogOptions(inactiveGraceMs: 350);
    perfOptions = PerfOptions();
): string =
  ## Load and run the Nest project in `projectDir` until it quits, returning
  ## the value the project closed its dialog with.
  ##
  ## `dialogData` is handed to the project as its dialog input, and
  ## `dialogMode` marks the process as a dialog so it skips the
  ## single-instance lock. `dialogAnchor` is a JSON anchor description used
  ## to place a dialog next to its opener, `dialogOptions` controls dialog
  ## auto-dismiss behavior, and `perfOptions` controls the performance
  ## overlay and benchmark mode. Quits when the directory or the project's
  ## main file is missing.
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
  installExternalSignalHandlers(gracefulTerminate = dialogMode)
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
      discard app.enableHotReloadNotifications()
      app.runtime.queuePendingExternalSignals()
      if dialogMode and consumePendingTerminate():
        app.runtime.requestDialogClose("")
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
      var requestedCloseThisFrame = false
      if dialogMode and dialogOptions.dismissOnInactive and
          not app.runtime.dialogPinned:
        if ui.windowInactiveFor(dialogOptions.inactiveGraceMs):
          app.runtime.requestDialogClose("")
          ui.markAllDirty()
          ui.requestRedrawAfter(0)
          requestedCloseThisFrame = true
        else:
          let remaining = ui.windowInactiveRemainingMs(
              dialogOptions.inactiveGraceMs)
          if remaining >= 0:
            ui.requestRedrawAfter(remaining)
      if dialogMode and app.runtime.dialogCloseRequested and
          not requestedCloseThisFrame:
        if ui.hasRunningAnimations():
          ui.requestRedrawAfter(16)
        else:
          running = false
      if options.benchmarkFrames > 0 and stats.frameCount >=
          options.benchmarkFrames:
        echo stats.summary()
        running = false
  finally:
    result = app.runtime.dialogCloseValue
    app.close()
    when defined(linux):
      tray.closeTrayHost()
    app.closeOwlErrorDialog()
    instanceLock.removeSingleInstanceLock()
