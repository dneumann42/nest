import std/[macros, sets]

import nest/[appConfig, palette, resources, ui]
import nest/[input, screen]

const
  FixedFrameNumerator = 1000
  FixedFrameDenominator = 60

proc scheduleNextFrame(nextFrameTicks: var int; frameRemainder: var int; now: int) =
  frameRemainder += FixedFrameNumerator
  let frameTicks = max(frameRemainder div FixedFrameDenominator, 1)
  frameRemainder = frameRemainder mod FixedFrameDenominator
  if nextFrameTicks == 0:
    nextFrameTicks = now + frameTicks
  else:
    nextFrameTicks += frameTicks
    if now > nextFrameTicks + frameTicks:
      nextFrameTicks = now + frameTicks

proc textFromEvent(chars: array[4, char]): string =
  for ch in chars:
    if ch == '\0':
      break
    result.add(ch)

proc wheelDeltaX(e: Event): float64 =
  if e.wheelX != 0.0:
    e.wheelX
  else:
    e.x.toFloat

proc wheelDeltaY(e: Event): float64 =
  if e.wheelY != 0.0:
    e.wheelY
  else:
    e.y.toFloat

proc handleEvent(
    e: Event;
    running: var bool;
    updateContext: var UpdateContext;
    drawContext: var DrawContext;
) =
  case e.kind
  of QuitEvent, WindowCloseEvent:
    running = false
  of MouseMoveEvent:
    updateContext.mouseX = e.x
    updateContext.mouseY = e.y
    drawContext.mouseX = e.x
    drawContext.mouseY = e.y
  of MouseDownEvent:
    updateContext.mouseX = e.x
    updateContext.mouseY = e.y
    drawContext.mouseX = e.x
    drawContext.mouseY = e.y
    let last = updateContext.mouseLeftDown
    updateContext.mouseLeftDown = true
    updateContext.mouseLeftPressed = not last
  of MouseUpEvent:
    updateContext.mouseX = e.x
    updateContext.mouseY = e.y
    drawContext.mouseX = e.x
    drawContext.mouseY = e.y
    updateContext.mouseLeftDown = false
    updateContext.mouseLeftPressed = false
  of WindowResizeEvent:
    updateContext.windowWidth = max(e.x, 0)
    updateContext.windowHeight = max(e.y, 0)
    drawContext.windowWidth = updateContext.windowWidth
    drawContext.windowHeight = updateContext.windowHeight
  of KeyDownEvent:
    updateContext.keyInputs.add KeyInput(key: e.key, mods: e.mods)
  of TextInputEvent:
    let text = textFromEvent(e.text)
    if text.len > 0:
      updateContext.textInputs.add text
  of MouseWheelEvent:
    updateContext.mouseX = e.mouseX
    updateContext.mouseY = e.mouseY
    drawContext.mouseX = e.mouseX
    drawContext.mouseY = e.mouseY
    let
      wheelX = e.wheelDeltaX()
      wheelY = e.wheelDeltaY()
    if ShiftPressed in e.mods:
      updateContext.mouseWheelX += wheelX + wheelY
    else:
      updateContext.mouseWheelX += wheelX
      updateContext.mouseWheelY += wheelY
  else:
    discard

proc handleEvent(e: Event; running: var bool; ui: var UI) =
  case e.kind
  of QuitEvent, WindowCloseEvent:
    running = false
  of MouseMoveEvent:
    ui.mouseMove(e.x, e.y)
  of MouseDownEvent:
    ui.mouseMove(e.x, e.y)
    ui.mouseDown()
    ui.requestRedrawAfter(0)
  of MouseUpEvent:
    ui.mouseMove(e.x, e.y)
    ui.mouseUp()
    ui.requestRedrawAfter(0)
  of WindowResizeEvent:
    ui.resizeWindow(e.x, e.y)
    ui.markAllDirty()
  of KeyDownEvent:
    ui.keyDown(e.key, e.mods)
    ui.requestRedrawAfter(0)
  of TextInputEvent:
    ui.textInput(textFromEvent(e.text))
    ui.requestRedrawAfter(0)
  of MouseWheelEvent:
    ui.mouseMove(e.mouseX, e.mouseY)
    let
      wheelX = e.wheelDeltaX()
      wheelY = e.wheelDeltaY()
    if ShiftPressed in e.mods:
      ui.mouseWheel(wheelX + wheelY, 0.0)
    else:
      ui.mouseWheel(wheelX, wheelY)
    ui.requestRedrawAfter(0)
  else:
    discard

template application*(cfg: AppConfig; blk: untyped) =
  ## Run `blk` as an application main loop against a raw update/draw context.
  ##
  ## Opens the window described by `cfg`, then repeats `blk` once per frame
  ## with `window`, `running`, `updateContext` and `drawContext` injected;
  ## set `running` to false to leave the loop. Frames are driven by input
  ## events unless `cfg.alwaysRun60Fps` is set, in which case the loop is
  ## paced at a fixed 60 fps. Prefer the `UI` overload for widget code.
  let window {.inject.} = cfg.initWindow()
  var
    running {.inject.} = true
    updateContext {.inject.} =
      UpdateContext(windowWidth: window.width, windowHeight: window.height)
    drawContext {.inject.} = DrawContext(
      resources: Resources.new(),
      palette: Palette.init(cfg.themeName),
      windowWidth: window.width,
      windowHeight: window.height,
      dirtyAll: true,
    )
  drawContext.resources.loadFont("font", "", 18)
  drawContext.resources.loadFont("editor", "nerd-monospace", 18)
  var
    firstFrame = true
    nextFrameTicks = input.getTicks()
    frameRemainder = 0
  while running:
    var e = Event()
    let inputFlags =
      if drawContext.focusedWidget != InvalidWidgetID:
        {WantTextInput}
      else:
        {}

    if cfg.alwaysRun60Fps:
      updateContext.keyInputs.setLen(0)
      updateContext.textInputs.setLen(0)
      updateContext.mouseWheelX = 0
      updateContext.mouseWheelY = 0
      updateContext.submittedWidgets.clear()
      updateContext.sliderValues.clear()
      var now = input.getTicks()
      while running and now < nextFrameTicks:
        if input.waitEvent(e, nextFrameTicks - now, inputFlags):
          handleEvent(e, running, updateContext, drawContext)
          while pollEvent(e, inputFlags):
            handleEvent(e, running, updateContext, drawContext)
        now = input.getTicks()
      while pollEvent(e, inputFlags):
        handleEvent(e, running, updateContext, drawContext)
      drawContext.ticks = input.getTicks()
      blk
      updateContext.mouseLeftPressed = false
      refresh()
      scheduleNextFrame(nextFrameTicks, frameRemainder, input.getTicks())
      continue

    var shouldRender = firstFrame
    firstFrame = false
    let frameEvent =
      if shouldRender:
        false
      else:
        input.waitEvent(e, -1, inputFlags)
    if frameEvent:
      shouldRender = true
    elif not shouldRender:
      continue
    updateContext.keyInputs.setLen(0)
    updateContext.textInputs.setLen(0)
    updateContext.mouseWheelX = 0
    updateContext.mouseWheelY = 0
    updateContext.submittedWidgets.clear()
    updateContext.sliderValues.clear()
    if frameEvent:
      handleEvent(e, running, updateContext, drawContext)
    while pollEvent(e, inputFlags):
      handleEvent(e, running, updateContext, drawContext)
    drawContext.ticks = input.getTicks()
    blk
    updateContext.mouseLeftPressed = false
    refresh()
  shutdown()

template application*(cfg: AppConfig; ui: var UI; blk: untyped) =
  ## Run `blk` as an application main loop that drives `ui`.
  ##
  ## Opens the window described by `cfg`, applies the configured theme and
  ## fonts to `ui`, then repeats `blk` once per frame with `window` and
  ## `running` injected; set `running` to false to leave the loop. `blk` is
  ## expected to declare the frame's widgets, normally through `ui.layout`.
  ## Redraws follow input events and `ui`'s own redraw requests unless
  ## `cfg.alwaysRun60Fps` is set.
  let window {.inject.} = cfg.initWindow()
  var running {.inject.} = true
  ui.setTheme(cfg.themeName)
  ui.initContext(window.width, window.height)
  ui.loadFont("font", "", 18)
  ui.loadFont("editor", "nerd-monospace", 18)
  var
    firstFrame = true
    nextFrameTicks = input.getTicks()
    frameRemainder = 0
  while running:
    var e = Event()
    let inputFlags =
      if ui.wantsTextInput():
        {WantTextInput}
      else:
        {}

    if cfg.alwaysRun60Fps:
      ui.beginInputFrame()
      var now = input.getTicks()
      while running and now < nextFrameTicks:
        if input.waitEvent(e, nextFrameTicks - now, inputFlags):
          handleEvent(e, running, ui)
          while pollEvent(e, inputFlags):
            handleEvent(e, running, ui)
        now = input.getTicks()
      while pollEvent(e, inputFlags):
        handleEvent(e, running, ui)
      ui.setDrawTicks(input.getTicks())
      blk
      ui.finishInputFrame()
      if ui.redrewFrame():
        refresh()
      scheduleNextFrame(nextFrameTicks, frameRemainder, input.getTicks())
      continue

    var shouldRender = firstFrame
    firstFrame = false
    let redrawWaitMs = ui.redrawDelayMs()
    let frameEvent =
      if shouldRender:
        false
      else:
        input.waitEvent(e, redrawWaitMs, inputFlags)
    if frameEvent:
      shouldRender = true
    elif redrawWaitMs >= 0:
      shouldRender = true
      ui.clearRedrawRequest()
    if not shouldRender:
      continue
    ui.beginInputFrame()
    if frameEvent:
      handleEvent(e, running, ui)
    while pollEvent(e, inputFlags):
      handleEvent(e, running, ui)
    ui.setDrawTicks(input.getTicks())
    blk
    ui.finishInputFrame()
    if ui.redrewFrame():
      refresh()
  shutdown()

proc eventTypeOf*[M, E](
    view: proc(ui: var UI, model: M, emitted: var seq[E]) {.nimcall.}
): E =
  ## Return the event type of a root widget that collects into a parameter.
  ##
  ## Only its type is of interest: `runApp` declares its queue from it, and
  ## never calls this.
  discard

proc eventTypeOf*[M, E](
    view: proc(ui: var UI, model: var M, emitted: var seq[E]) {.nimcall.}
): E =
  ## Return the event type of a root widget that collects into a parameter and
  ## takes its model by `var`.
  discard

proc appLoop(cfg, initial, update, view, blk: NimNode): NimNode =
  ## Build the frame loop `runApp` expands to.
  ##
  ## `ui`, `model` and `msgs` are spliced as plain identifiers, so the caller's
  ## block can name them.
  let
    uiSym = ident"ui"
    modelSym = ident"model"
    msgsSym = ident"msgs"
    msgSym = ident"msg"
    cfgSym = genSym(nskLet, "appCfg")
  quote do:
    block:
      let `cfgSym` = `cfg`
      var `uiSym` = UI.init()
      var `modelSym` = `initial`
      # The queue's type comes from the root widget, whichever shape it has.
      when compiles(`view`(`uiSym`, `modelSym`)):
        when typeof(`view`(`uiSym`, `modelSym`)) is void:
          {.
            error:
              "runApp needs a root widget that either emits its own events " &
              "or takes an `emitted: var seq[E]` parameter"
          .}
        else:
          var `msgsSym`: typeof(`view`(`uiSym`, `modelSym`))
      elif compiles(eventTypeOf(`view`)):
        var `msgsSym`: seq[typeof(eventTypeOf(`view`))]
      else:
        {.
          error:
            "runApp needs a root widget that either emits its own events or " &
            "takes an `emitted: var seq[E]` parameter"
        .}
      application `cfgSym`, `uiSym`:
        `uiSym`.layout:
          `uiSym`.events:
            `msgsSym`.setLen(0)

          when compiles(`msgsSym`.add `view`(`uiSym`, `modelSym`)):
            `msgsSym`.add `view`(`uiSym`, `modelSym`)
          else:
            `view`(`uiSym`, `modelSym`, `msgsSym`)

          `uiSym`.events:
            for `msgSym` in `msgsSym`:
              `update`(`modelSym`, `msgSym`)
            if `msgsSym`.len > 0:
              `uiSym`.markAllDirty()
            `blk`

macro runApp*(cfg, initial, update, view, blk: untyped): untyped =
  ## Run a Model/Msg/update/view application until its window closes.
  ##
  ## Opens the window described by `cfg`, holds `initial` as the model, and runs
  ## one frame at a time: the message queue is cleared, `view` declares the
  ## interface, then every message it collected is applied with `update`.
  ##
  ## `view` is the root widget, in either shape: one that emits its own events,
  ## called as `view(ui, model)` and returning them, or one that collects into a
  ## parameter, called as `view(ui, model, emitted)`. The queue's type is taken
  ## from whichever it is. `update` is called as `update(model, event)` for every
  ## event of the frame, which resolves among as many `update` overloads as the
  ## application has state types.
  ##
  ## `blk` runs at the end of every event pass, with `ui`, `model`, `msgs` and
  ## `running` in scope. Setting `running` to false leaves the loop.
  ##
  ## ```nim
  ## runApp(AppConfig.init(title = "Counter"), Model(), update, counter):
  ##   if ui.keyPressed("Escape"):
  ##     running = false
  ## ```
  appLoop(cfg, initial, update, view, blk)

macro runApp*(cfg, initial, update, view: untyped): untyped =
  ## Run a Model/Msg/update/view application until its window closes.
  ##
  ## This is the whole main module of a typical application:
  ##
  ## ```nim
  ## when isMainModule:
  ##   runApp(AppConfig.init(width = 320, height = 160, title = "Counter"),
  ##       Model(), update, counter)
  ## ```
  ##
  ## Use the overload taking a trailing block to reach `ui`, `model`, `msgs` and
  ## `running` once per frame.
  appLoop(cfg, initial, update, view, newStmtList(nnkDiscardStmt.newTree(newEmptyNode())))
