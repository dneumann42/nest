import std/[json, os, osproc]

import nest/[appConfig, owldsl, runtime, ui]
import nest/input

proc closeOwlErrorDialog*(app: NestOwlApp) =
  ## Close the error dialog `app` has open, terminating the dialog process if
  ## it is still running.
  if app.errorDialogProcess != nil:
    if app.errorDialogProcess.running:
      app.errorDialogProcess.terminate
    app.errorDialogProcess.close
    app.errorDialogProcess = nil

proc pollOwlErrorDialog*(app: NestOwlApp) =
  ## Reap the error dialog process once the user has closed it.
  ##
  ## The reported error is remembered as dismissed, so the same error does
  ## not immediately raise the dialog again.
  if app.errorDialogProcess != nil and not app.errorDialogProcess.running:
    app.errorDialogProcess.close
    app.errorDialogProcess = nil
    if app.errorDialogMessage.len > 0:
      app.runtime.dismissedError = app.errorDialogMessage

proc detailsJson(details: ErrorDetails): string =
  var frames = newJArray()
  for frame in details.frames:
    frames.add(%* {"path": frame.path, "line": frame.line,
      "column": frame.column, "label": frame.label})
  $(%* {"message": details.message, "primary": {"path": details.primary.path,
    "line": details.primary.line, "column": details.primary.column,
    "sourceLine": details.primary.sourceLine}, "frames": frames})

proc errorDetailsFromJson*(value: string): ErrorDetails =
  ## Parse the JSON error description passed to the `error-dialog-json`
  ## command into `ErrorDetails`.
  try:
    let node = parseJson(value)
    result.message = node["message"].getStr
    let primary = node["primary"]
    result.primary = ErrorLocation(path: primary["path"].getStr,
      line: primary["line"].getInt, column: primary["column"].getInt,
      sourceLine: primary["sourceLine"].getStr)
    for item in node["frames"]:
      result.frames.add ErrorLocation(path: item["path"].getStr,
        line: item["line"].getInt, column: item["column"].getInt,
        label: item["label"].getStr)
  except CatchableError:
    result = ErrorDetails(message: value)

proc launchOwlErrorDialog*(app: NestOwlApp, details: ErrorDetails) =
  ## Show `details` in a separate error dialog process.
  ##
  ## Does nothing for an empty report, for an error the user has already
  ## dismissed, or while a dialog for it is still open.
  let message = details.errorReport()
  if message.len == 0 or app.runtime.dismissedError == message:
    return
  app.pollOwlErrorDialog()
  if app.errorDialogProcess != nil and app.errorDialogMessage == message:
    return
  app.closeOwlErrorDialog()
  try:
    app.errorDialogProcess = startProcess(
      getAppFilename(), args = @["error-dialog-json", details.detailsJson()], options = {poUsePath}
    )
    app.errorDialogMessage = message
  except OSError:
    discard
  except IOError:
    discard

template owlErrorDialogBody(
    ui: var UI, details: ErrorDetails, copied, stackExpanded: var bool, running: var bool
) =
  ui.events:
    if ui.clicked(ui.id("_nest_error_copy")):
      putClipboardText(details.errorReport())
      copied = true
    if ui.clicked(ui.id("_nest_error_stack")):
      stackExpanded = not stackExpanded
    if ui.clicked(ui.id("_nest_error_close")):
      running = false
  ui.card(
    ui.id("_nest_error_dialog"),
    cfg(
      width = fixed(ui.windowWidth.toFloat),
      height = fixed(ui.windowHeight.toFloat),
      padding = 0,
      gap = 0,
      alignItems = AlignStretch,
    ),
  ):
    ui.dialogHeader(
      ui.id("_nest_error_header"),
      cfg(
        width = fill(), height = fixed(36), padding = 4, gap = 4,
            alignItems = AlignCenter
      ),
    ):
      let titleID = ui.id("_nest_error_title")
      ui.label(titleID, "Owl error", fill(), fit())
      ui.dragWindow(titleID)
      discard ui.button(ui.id("_nest_error_close"), "×", fixed(26), fixed(26))
    ui.column(
      ui.id("_nest_error_body"),
      cfg(
        width = fill(), height = fill(), padding = 16, gap = 8, scrollY = true,
            alignItems = AlignStretch
      ),
    ):
      for index, line in owlErrorLines(details.message, maxLines = 1024):
        ui.label(ui.id("_nest_error_message", $index), line, fill(), fit())
      if details.primary.path.len > 0:
        ui.diagnosticLabel(ui.id("_nest_error_primary"),
          details.primary.path & ":" & $details.primary.line & ":" & $details.primary.column,
          ui.palette.textColor, fill(), fit(), clickable = false)
      if details.primary.sourceLine.len > 0:
        ui.label(ui.id("_nest_error_source"), details.primary.sourceLine, fill(), fit())
      if details.frames.len > 0:
        discard ui.button(ui.id("_nest_error_stack"),
          (if stackExpanded: "▾" else: "▸") & " Stack trace (" & $details.frames.len & ")",
          fill(), fit())
        if stackExpanded:
          for index, frame in details.frames:
            let location = frame.path & ":" & $frame.line & ":" & $frame.column &
              (if frame.label.len > 0: " in " & frame.label else: "")
            ui.diagnosticLabel(ui.id("_nest_error_frame", $index), location,
              ui.palette.textColor, fill(), fit(), clickable = false)
      if copied:
        ui.label(ui.id("_nest_error_copied"), "Copied to clipboard", fill(),
            fit())
    ui.row(
      ui.id("_nest_error_actions"),
      cfg(width = fill(), height = fit(), gap = 8, padding = 10,
          justifyContent = JustifyEnd),
    ):
      discard ui.button(ui.id("_nest_error_copy"), "Copy", fit(), fit())

proc drawOwlErrorDialog(
    ui: var UI, details: ErrorDetails, copied, stackExpanded: var bool, running: var bool
) =
  ui.layout:
    owlErrorDialogBody(ui, details, copied, stackExpanded, running)

proc layoutOwlErrorDialogForTest*(
    ui: var UI, message: string, width, height: int
): bool =
  ## Lay out the error dialog once against `ui` at `width` by `height` and
  ## report whether the layout succeeded. Exposed for the test suite.
  var
    copied = false
    stackExpanded = false
    running = true
  ui.initContext(width, height)
  ui.beginLayout(width, height)
  owlErrorDialogBody(ui, ErrorDetails(message: message), copied, stackExpanded, running)
  ui.applyIntrinsicSizes(ui.resources)
  ui.endLayout()

proc runOwlErrorDialog*(details: ErrorDetails) =
  ## Run the error dialog for `details` as its own application, blocking
  ## until the user closes it.
  ##
  ## This is what the `nest error-dialog` command runs.
  var ui = UI.init()
  var copied = false
  var stackExpanded = false
  application AppConfig.overlayDialog(
    width = 620.Positive,
    height = 360.Positive,
    title = "Owl Error",
    namespace = "nest-owl-error-dialog",
    draggable = true,
  ), ui:
    drawOwlErrorDialog(ui, details, copied, stackExpanded, running)

proc runOwlErrorDialog*(message: string) =
  ## Run the error dialog for a plain `message`, blocking until the user
  ## closes it.
  runOwlErrorDialog(ErrorDetails(message: message))
