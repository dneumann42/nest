import std/sets

import nest/[appConfig, framePacer, palette, resources, ui]
import nest/[input, screen]

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
    e: Event,
    running: var bool,
    updateContext: var UpdateContext,
    drawContext: var DrawContext,
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

proc handleEvent(e: Event, running: var bool, ui: var UI) =
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

template application*(cfg: AppConfig, blk: untyped) =
  let window {.inject.} = cfg.initWindow()
  const
    FixedFrameNumerator = 1000
    FixedFrameDenominator = 60
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
  var framePacer = FramePacer.init()
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
      framePacer.beginFixedFrame(17, now)
      while running and now < framePacer.nextFrameTicks:
        if input.waitEvent(e, framePacer.nextFrameTicks - now, inputFlags):
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
      framePacer.finishFixedFrame(
        FixedFrameNumerator, FixedFrameDenominator, input.getTicks()
      )
      continue

    var shouldRender = framePacer.takeFirstFrame()
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

template application*(cfg: AppConfig, ui: var UI, blk: untyped) =
  let window {.inject.} = cfg.initWindow()
  const
    FixedFrameNumerator = 1000
    FixedFrameDenominator = 60
  var running {.inject.} = true
  ui.setTheme(cfg.themeName)
  ui.initContext(window.width, window.height)
  ui.loadFont("font", "", 18)
  ui.loadFont("editor", "nerd-monospace", 18)
  var framePacer = FramePacer.init()
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
      framePacer.beginFixedFrame(17, now)
      while running and now < framePacer.nextFrameTicks:
        if input.waitEvent(e, framePacer.nextFrameTicks - now, inputFlags):
          handleEvent(e, running, ui)
          while pollEvent(e, inputFlags):
            handleEvent(e, running, ui)
        now = input.getTicks()
      while pollEvent(e, inputFlags):
        handleEvent(e, running, ui)
      ui.setDrawTicks(input.getTicks())
      ui.markAllDirty()
      blk
      ui.finishInputFrame()
      if ui.redrewFrame():
        refresh()
      framePacer.finishFixedFrame(
        FixedFrameNumerator, FixedFrameDenominator, input.getTicks()
      )
      continue

    var shouldRender = framePacer.takeFirstFrame()
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
