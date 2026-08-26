import std/[json, os, osproc, strutils]

import nest/[appConfig, owldsl, runtime, ui]
import nest/[input, screen]

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
    let exitCode = app.errorDialogProcess.peekExitCode()
    app.errorDialogProcess.close
    app.errorDialogProcess = nil
    if exitCode == 0 and app.errorDialogMessage.len > 0:
      app.runtime.dismissedError = app.errorDialogMessage
    elif exitCode != 0:
      app.errorDialogLaunchError = "Owl error dialog exited with code " & $exitCode

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

proc locationText(location: ErrorLocation): string =
  if location.path.len == 0:
    return ""
  result = location.path & ":" & $location.line & ":" & $location.column
  if location.label.len > 0:
    result.add " in " & location.label

proc openLocation(location: ErrorLocation) =
  let text = location.locationText()
  if text.len > 0:
    openDiagnosticLocation(text)

proc sourceContextLines(location: ErrorLocation): seq[string] =
  if location.sourceLine.len == 0:
    return
  let numberWidth = max(($location.line).len, 1)
  result.add ($location.line).align(numberWidth) & " | " & location.sourceLine
  if location.column > 0:
    result.add repeat(' ', numberWidth) & " | " &
      repeat(' ', max(location.column - 1, 0)) & "^"

proc diagnosticLines(details: ErrorDetails): seq[string] =
  ## Return the full diagnostic without truncation.
  result.add "error: " & details.message
  if details.primary.path.len > 0:
    result.add details.primary.locationText()
  for line in details.primary.sourceContextLines():
    result.add line
  if details.frames.len > 0:
    result.add ""
    result.add "Stack trace:"
    for frame in details.frames:
      result.add "  at " & frame.locationText()

proc launchOwlErrorDialog*(app: NestOwlApp, details: ErrorDetails): bool {.discardable.} =
  ## Show `details` in a separate error dialog process.
  ##
  ## Does nothing for an empty report, for an error the user has already
  ## dismissed, or while a dialog for it is still open.
  app.errorDialogLaunchError = ""
  let message = details.errorReport()
  if message.len == 0 or app.runtime.dismissedError == message:
    return true
  app.pollOwlErrorDialog()
  if app.errorDialogProcess != nil and app.errorDialogMessage == message:
    return true
  app.closeOwlErrorDialog()
  app.lastError = message
  app.lastErrorDetails = details
  try:
    app.errorDialogProcess = startProcess(
      getAppFilename(), args = @["error-dialog-json", details.detailsJson()],
      options = {poUsePath, poParentStreams}
    )
    app.errorDialogMessage = message
    true
  except OSError as error:
    app.errorDialogLaunchError = "could not launch Owl error dialog: " & error.msg
    false
  except IOError as error:
    app.errorDialogLaunchError = "could not launch Owl error dialog: " & error.msg
    false

template owlErrorDialogBody(
    ui: var UI, details: ErrorDetails, copied: var bool, running: var bool
) =
  ui.events:
    if ui.clicked(ui.id("_nest_error_copy")):
      putClipboardText(details.errorReport())
      copied = true
    if ui.clicked(ui.id("_nest_error_open_primary")) or
        ui.clicked(ui.id("_nest_error_primary")) or
        ui.clicked(ui.id("_nest_error_source", "0")) or
        ui.clicked(ui.id("_nest_error_source", "1")):
      details.primary.openLocation()
    for index, frame in details.frames:
      if ui.clicked(ui.id("_nest_error_frame", $index)):
        frame.openLocation()
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
      cornerStyle = RoundedCorners,
      radius = 6,
      shadow = true,
      shadowColor = color(0, 0, 0, 150),
      shadowOffsetY = 4,
      shadowBlur = 12,
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
      ui.label(titleID, "Owl Error", fill(), fit())
      ui.dragWindow(titleID)
      discard ui.button(ui.id("_nest_error_close"), "×", fixed(26), fixed(26))
    ui.column(
      ui.id("_nest_error_body"),
      cfg(
        width = fill(), height = fill(), padding = 14, gap = 10,
            scrollY = true, scrollX = true,
            alignItems = AlignStretch
      ),
    ):
      ui.label(ui.id("_nest_error_summary"), details.message, fill(), fit(),
        textScroll = true)
      if details.primary.path.len > 0:
        ui.diagnosticLabel(ui.id("_nest_error_primary"),
          details.primary.locationText(), ui.palette.rose, fill(), fit(),
          clickable = true)
      for index, line in details.primary.sourceContextLines():
        ui.diagnosticLabel(ui.id("_nest_error_source", $index), line,
          if line.strip == "^": ui.palette.rose else: ui.palette.textColor,
          fill(), fit(), clickable = details.primary.path.len > 0)
      ui.label(ui.id("_nest_error_full_heading"), "Full report", fill(), fit())
      for index, line in details.diagnosticLines():
        let location = diagnosticLocation(line)
        if location.ok:
          renderOwlErrorLine(ui, index, line, fill(), fit())
        else:
          ui.label(ui.id("_nest_error_message", $index), line, fill(), fit(),
            textScroll = true)
      if details.frames.len > 0:
        ui.label(ui.id("_nest_error_stack_title"),
          "Stack trace (" & $details.frames.len & ")", fill(), fit())
        for index, frame in details.frames:
          ui.diagnosticLabel(ui.id("_nest_error_frame", $index),
            frame.locationText(), ui.palette.sky, fill(), fit(), clickable = true)
      if copied:
        ui.label(ui.id("_nest_error_copied"), "Copied to clipboard", fill(),
            fit())
    ui.row(
      ui.id("_nest_error_actions"),
      cfg(width = fill(), height = fit(), gap = 8, padding = 10,
          justifyContent = JustifyEnd),
    ):
      if details.primary.path.len > 0:
        discard ui.button(ui.id("_nest_error_open_primary"), "Open Location", fit(), fit())
      discard ui.button(ui.id("_nest_error_copy"), "Copy", fit(), fit())

proc drawOwlErrorDialog(
    ui: var UI, details: ErrorDetails, copied: var bool, running: var bool
) =
  ui.layout:
    owlErrorDialogBody(ui, details, copied, running)

proc layoutOwlErrorDialogForTest*(
    ui: var UI, message: string, width, height: int
): bool =
  ## Lay out the error dialog once against `ui` at `width` by `height` and
  ## report whether the layout succeeded. Exposed for the test suite.
  var
    copied = false
    running = true
  ui.initContext(width, height)
  ui.beginLayout(width, height)
  owlErrorDialogBody(ui, ErrorDetails(message: message), copied, running)
  ui.applyIntrinsicSizes(ui.resources)
  ui.endLayout()

proc layoutOwlErrorDialogForTest*(
    ui: var UI, details: ErrorDetails, width, height: int
): bool =
  ## Lay out the structured error dialog once against `ui` for tests.
  var
    copied = false
    running = true
  ui.initContext(width, height)
  ui.beginLayout(width, height)
  owlErrorDialogBody(ui, details, copied, running)
  ui.applyIntrinsicSizes(ui.resources)
  ui.endLayout()

proc runOwlErrorDialog*(details: ErrorDetails) =
  ## Run the error dialog for `details` as its own application, blocking
  ## until the user closes it.
  ##
  ## This is what the `nest error-dialog` command runs.
  var ui = UI.init()
  var copied = false
  application AppConfig.overlayDialog(
    width = 960.Positive,
    height = 640.Positive,
    title = "Owl Error",
    namespace = "nest-owl-error-dialog",
    draggable = true,
  ), ui:
    drawOwlErrorDialog(ui, details, copied, running)

proc runOwlErrorDialog*(message: string) =
  ## Run the error dialog for a plain `message`, blocking until the user
  ## closes it.
  runOwlErrorDialog(ErrorDetails(message: message))
