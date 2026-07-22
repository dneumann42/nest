import std/[os, osproc]

import nest/[appConfig, crowdsl, runtime, ui]
import nest/input

proc closeCrowErrorDialog*(app: NestCrowApp) =
  if app.errorDialogProcess != nil:
    if app.errorDialogProcess.running:
      app.errorDialogProcess.terminate
    app.errorDialogProcess.close
    app.errorDialogProcess = nil

proc pollCrowErrorDialog*(app: NestCrowApp) =
  if app.errorDialogProcess != nil and not app.errorDialogProcess.running:
    app.errorDialogProcess.close
    app.errorDialogProcess = nil
    if app.errorDialogMessage.len > 0:
      app.runtime.dismissedError = app.errorDialogMessage

proc launchCrowErrorDialog*(app: NestCrowApp, message: string) =
  if message.len == 0 or app.runtime.dismissedError == message:
    return
  app.pollCrowErrorDialog()
  if app.errorDialogProcess != nil and app.errorDialogMessage == message:
    return
  app.closeCrowErrorDialog()
  try:
    app.errorDialogProcess = startProcess(
      getAppFilename(), args = @["error-dialog", message], options = {poUsePath}
    )
    app.errorDialogMessage = message
  except OSError:
    discard
  except IOError:
    discard

template crowErrorDialogBody(
    ui: var UI, message: string, copied: var bool, running: var bool
) =
  ui.events:
    if ui.clicked(ui.id("_nest_error_copy")):
      putClipboardText(message)
      copied = true
    if ui.clicked(ui.id("_nest_error_close")):
      running = false
  ui.card(
    ui.id("_nest_error_dialog"),
    cfg(
      width = fixed(ui.windowWidth.toFloat),
      height = fixed(ui.windowHeight.toFloat),
      padding = 12,
      gap = 10,
      alignItems = AlignStretch,
    ),
  ):
    ui.dialogHeader(
      ui.id("_nest_error_header"),
      cfg(
        width = fill(), height = fit(), padding = 8, gap = 8,
            alignItems = AlignCenter
      ),
    ):
      ui.label(ui.id("_nest_error_title"), "Crow error", fill(), fit())
      discard ui.button(ui.id("_nest_error_close"), "Close", fit(), fit())
    ui.column(
      ui.id("_nest_error_body"),
      cfg(
        width = fill(), height = fill(), padding = 8, gap = 4,
            alignItems = AlignStretch
      ),
    ):
      for index, line in crowErrorLines(message, maxLines = 8):
        renderCrowErrorLine(ui, index, line, fill(), fit())
      if copied:
        ui.label(ui.id("_nest_error_copied"), "Copied to clipboard", fill(),
            fit())
    ui.row(
      ui.id("_nest_error_actions"),
      cfg(width = fill(), height = fit(), gap = 8, justifyContent = JustifyEnd),
    ):
      discard ui.button(ui.id("_nest_error_copy"), "Copy", fit(), fit())

proc drawCrowErrorDialog(
    ui: var UI, message: string, copied: var bool, running: var bool
) =
  ui.layout:
    crowErrorDialogBody(ui, message, copied, running)

proc layoutCrowErrorDialogForTest*(
    ui: var UI, message: string, width, height: int
): bool =
  var
    copied = false
    running = true
  ui.initContext(width, height)
  ui.beginLayout(width, height)
  crowErrorDialogBody(ui, message, copied, running)
  ui.applyIntrinsicSizes(ui.resources)
  ui.endLayout()

proc runCrowErrorDialog*(message: string) =
  var ui = UI.init()
  var copied = false
  application AppConfig.overlayDialog(
    width = 800.Positive,
    height = 600.Positive,
    title = "Crow Error",
    namespace = "nest-crow-error-dialog",
  ), ui:
    drawCrowErrorDialog(ui, message, copied, running)
