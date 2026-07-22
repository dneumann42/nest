import std/[os, strutils]

import nest/[
  appConfig,
  crowdsl,
  dialogAnchors,
  errorDialogs,
  externalSignals,
  projectConfig,
  runtime,
  singleInstance,
  ui,
]

proc needsSingleInstance(config: ProjectConfig; dialogMode: bool): bool =
  not dialogMode and config.layerShell.normalize in ["top", "bottom", "left", "right"]

proc runProject*(
    projectDir: string,
    dialogData = "",
    dialogMode = false,
    dialogResultPath = "",
    dialogAnchor = "",
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
  let app = NestCrowApp.init(mainPath)
  app.runtime.dialogData = dialogData
  installExternalSignalHandlers()
  try:
    application appConfig(config).applyDialogAnchor(parseDialogAnchor(
        dialogAnchor)), ui:
      enableExternalSignalWake()
      app.runtime.queuePendingExternalSignals()
      app.render(ui)
      if app.lastError.len > 0:
        app.launchCrowErrorDialog(app.lastError)
      else:
        app.pollCrowErrorDialog()
        app.closeCrowErrorDialog()
      if app.runtime.requestQuit:
        running = false
  finally:
    result = app.runtime.dialogCloseValue
    app.runtime.closeDialogProcesses()
    app.runtime.closeShellProcesses()
    app.runtime.closeWorkspaceSubscriptions()
    app.closeCrowErrorDialog()
    instanceLock.removeSingleInstanceLock()
