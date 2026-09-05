import std/[macros, os, sets, strformat, strutils]

import nest/[appConfig, bench, palette, resources, ui]
import nest/[input, screen]
import nest/resizePacing

const
  FixedFrameNumerator = 1000
  FixedFrameDenominator = 60
  ResizeDrainBudgetMs = 2
  MaxResizeEventsPerFrame = 256

type ResizeTraceCounters = object
  resizeEvents: int
  fastResizePresents: int
  fullFrames: int
  resizeFullFrames: int
  blockedNoRetained: int
  blockedNonFastEvent: int
  maxFullFrameMs: int
  totalFullFrameMs: int
  lastReportTicks: int

var resizeTrace: ResizeTraceCounters

var resizeTraceFlag = -1

proc resizeTraceEnabled(): bool =
  if resizeTraceFlag < 0:
    resizeTraceFlag =
      if getEnv("NEST_RESIZE_TRACE").normalize in ["1", "true", "yes", "on"]:
        1
      else:
        0
  resizeTraceFlag == 1

proc resizeStrategy(): ResizeStrategy =
  resizeStrategyFromEnv()

proc reportResizeTrace(reason: string; force = false) =
  if not resizeTraceEnabled():
    return
  let now = input.getTicks()
  if not force and resizeTrace.lastReportTicks > 0 and
      now - resizeTrace.lastReportTicks < 1000:
    return
  resizeTrace.lastReportTicks = now
  let avgFull =
    if resizeTrace.fullFrames > 0:
      resizeTrace.totalFullFrameMs.float64 / resizeTrace.fullFrames.float64
    else:
      0.0
  echo &"[nest resize trace] {reason} resizeEvents={resizeTrace.resizeEvents} " &
    &"strategy={resizeStrategy()} fastPresents={resizeTrace.fastResizePresents} fullFrames={resizeTrace.fullFrames} " &
    &"resizeFullFrames={resizeTrace.resizeFullFrames} blockedNoRetained={resizeTrace.blockedNoRetained} " &
    &"blockedNonFastEvent={resizeTrace.blockedNonFastEvent} avgFullMs={avgFull:.2f} " &
    &"maxFullMs={resizeTrace.maxFullFrameMs}"

proc recordFullFrame(startTicks: int; resizeRelated: bool) =
  if not resizeTraceEnabled():
    return
  let dt = max(input.getTicks() - startTicks, 0)
  inc resizeTrace.fullFrames
  if resizeRelated:
    inc resizeTrace.resizeFullFrames
  resizeTrace.totalFullFrameMs += dt
  resizeTrace.maxFullFrameMs = max(resizeTrace.maxFullFrameMs, dt)
  reportResizeTrace("full")

proc shouldYieldResizeDrain(
    sawResize: bool; eventCount, drainStartTicks: int
): bool {.inline.} =
  ## Resize events can arrive faster than a frame can be laid out and
  ## presented. Stop draining periodically so the latest consumed size reaches
  ## the screen instead of waiting behind an unbounded event burst.
  sawResize and (
    eventCount >= MaxResizeEventsPerFrame or
    input.getTicks() - drainStartTicks >= ResizeDrainBudgetMs
  )

template drainPendingEvents(
    e: var Event; inputFlags: set[InputFlag]; running: var bool;
    firstEventHandled: bool; handle: untyped
) =
  let drainStartTicks = input.getTicks()
  var
    eventCount = if firstEventHandled: 1 else: 0
    sawResize = firstEventHandled and e.kind == WindowResizeEvent
  while running and not shouldYieldResizeDrain(
      sawResize, eventCount, drainStartTicks
  ) and pollEvent(e, inputFlags):
    inc eventCount
    sawResize = sawResize or e.kind == WindowResizeEvent
    handle

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

proc mergedAppWaitMs(a, b: int): int {.inline.} =
  if a < 0:
    b
  elif b < 0:
    a
  else:
    min(a, b)

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

proc resizeCoalescableEvent(kind: EventKind): bool {.inline.} =
  ## Whether an event may be answered by re-solving the retained layout.
  ##
  ## Only sizing and pointer motion can: everything else either changes the
  ## widget tree or has to reach a widget, and the fast path re-solves the
  ## tree the last full frame left behind rather than rebuilding it.
  kind in {NoEvent, WindowResizeEvent, MouseMoveEvent}

proc resizeFastPathEvent(kind: EventKind): bool {.inline.} =
  kind in {
    NoEvent,
    MouseDownEvent,
    MouseUpEvent,
    MouseMoveEvent,
    WindowResizeEvent,
    WindowFocusGainedEvent,
    WindowFocusLostEvent,
    WindowMouseEnterEvent,
    WindowMouseLeaveEvent,
  }

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
  of WindowMouseEnterEvent, WindowFocusGainedEvent:
    discard
  of WindowMouseLeaveEvent, WindowFocusLostEvent:
    discard
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

proc countEvent(kind: EventKind) =
  ## Tally events by kind, so a profile says what is waking the loop.
  case kind
  of MouseMoveEvent: bench.count("event.motion", 1)
  of MouseDownEvent, MouseUpEvent: bench.count("event.button", 1)
  of MouseWheelEvent: bench.count("event.wheel", 1)
  of KeyDownEvent, TextInputEvent: bench.count("event.key", 1)
  of WindowResizeEvent: bench.count("event.resize", 1)
  of WindowFocusGainedEvent, WindowFocusLostEvent,
      WindowMouseEnterEvent, WindowMouseLeaveEvent:
    bench.count("event.window", 1)
  of NoEvent: bench.count("event.none", 1)
  else: bench.count("event.other", 1)

proc handleEvent(e: Event; running: var bool; ui: var UI) =
  countEvent(e.kind)
  case e.kind
  of QuitEvent, WindowCloseEvent:
    running = false
  of MouseMoveEvent:
    ui.mouseMove(e.x, e.y)
    ui.windowMouseEnter()
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
  of WindowMouseEnterEvent:
    ui.windowMouseEnter()
    ui.requestRedrawAfter(0)
  of WindowMouseLeaveEvent:
    ui.windowMouseLeave()
    ui.requestRedrawAfter(0)
  of WindowFocusGainedEvent:
    ui.windowFocusGained()
    ui.requestRedrawAfter(0)
  of WindowFocusLostEvent:
    ui.windowFocusLost()
    ui.requestRedrawAfter(0)
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

proc redrawRetainedIfClean*(ui: var UI): bool {.discardable.} =
  ## Service a timer-driven repaint without rebuilding the application when
  ## the retained widget tree is still valid. Timers which require Owl to be
  ## reevaluated use `requestFullRedrawAfter`, so clocks and virtualized views
  ## still take the application block once their deadline is due.
  ##
  ## A maintenance wake is not a repaint: it hands the frame back to the
  ## application body, which polls whatever it woke for and decides for
  ## itself whether anything now needs drawing.
  if not ui.hasRetainedFrame() or ui.needsFullRender() or
      ui.hasPendingFullRenderInput() or ui.maintenanceDue():
    return false
  ui.clearRedrawRequest()
  ui.setDrawTicks(input.getTicks())
  ui.clearRedrewFrame()
  let ticksDue = ui.markDueTicks(input.getTicks())
  if ui.hasPendingInput():
    discard ui.updateRetainedFrame()
  elif ui.hasSettlingScroll():
    # A settling scroll moves the whole tree, not just the animating widgets,
    # so it needs the repaint that redraws all of it.
    discard ui.drawRetainedFrame()
  elif ui.hasRealtimeWidgets():
    discard ui.drawRealtime()
  elif ticksDue or ui.hasRunningAnimations() or not ui.hasTickingWidgets():
    discard ui.drawRetainedFrame()
  let tickWait = ui.nextTickWaitMs(input.getTicks())
  if tickWait >= 0:
    ui.requestRedrawAfter(tickWait)
  if ui.redrewFrame():
    bench.classifyFrame(fkRetainedDraw)
    bench.zone("present"):
      refresh()
  else:
    bench.heldFrame()
  true

proc requestResizeFrame(ui: var UI) =
  ## Resize is an explicit redraw driver. The runtime still avoids doing work
  ## when idle, but while the compositor is delivering resize events the app
  ## should re-layout at frame cadence rather than waiting for hover or other
  ## incidental input to make it active.
  ui.markAllDirty()

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
  drawContext.resources.loadFont("icon", "nerd-monospace", 18)
  var
    firstFrame = true
    nextFrameTicks = input.getTicks()
    frameRemainder = 0
    hasResizeRedraw = false
    resizeRedrawTicks = 0
    resizePacer = ResizePacer.init(resizeStrategy())
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
          drainPendingEvents(e, inputFlags, running, true):
            handleEvent(e, running, updateContext, drawContext)
        now = input.getTicks()
      drainPendingEvents(e, inputFlags, running, false):
        handleEvent(e, running, updateContext, drawContext)
      drawContext.ticks = input.getTicks()
      bench.frame:
        blk
        updateContext.mouseLeftPressed = false
        bench.zone("present"):
          refresh()
      scheduleNextFrame(nextFrameTicks, frameRemainder, input.getTicks())
      continue

    var shouldRender = firstFrame
    firstFrame = false
    let nowTicks = input.getTicks()
    let resizeWaitMs =
      if hasResizeRedraw:
        max(resizeRedrawTicks - nowTicks, 0)
      else:
        -1
    let waitMs = resizePacer.waitMs(nowTicks, resizeWaitMs)
    let frameEvent =
      if shouldRender:
        false
      else:
        input.waitEvent(e, waitMs, inputFlags)
    let afterWaitTicks = input.getTicks()
    let pumpDue = resizePacer.pumpDue(afterWaitTicks)
    if frameEvent:
      shouldRender = true
    elif pumpDue:
      if resizeTraceEnabled():
        inc resizeTrace.fastResizePresents
      resizePacer.finishedPumpPresent(afterWaitTicks)
      shouldRender = true
    elif hasResizeRedraw:
      shouldRender = true
      hasResizeRedraw = false
    elif not shouldRender:
      continue
    updateContext.keyInputs.setLen(0)
    updateContext.textInputs.setLen(0)
    updateContext.mouseWheelX = 0
    updateContext.mouseWheelY = 0
    updateContext.submittedWidgets.clear()
    updateContext.sliderValues.clear()
    var
      sawResizeEvent = false
      sawNonResizeEvent = false
    if frameEvent:
      sawResizeEvent = e.kind == WindowResizeEvent
      sawNonResizeEvent = not resizeFastPathEvent(e.kind)
      if sawResizeEvent and resizeTraceEnabled():
        inc resizeTrace.resizeEvents
      handleEvent(e, running, updateContext, drawContext)
      drainPendingEvents(e, inputFlags, running, true):
        sawResizeEvent = sawResizeEvent or e.kind == WindowResizeEvent
        sawNonResizeEvent = sawNonResizeEvent or not resizeFastPathEvent(e.kind)
        if e.kind == WindowResizeEvent and resizeTraceEnabled():
          inc resizeTrace.resizeEvents
        handleEvent(e, running, updateContext, drawContext)
    else:
      drainPendingEvents(e, inputFlags, running, false):
        sawResizeEvent = sawResizeEvent or e.kind == WindowResizeEvent
        sawNonResizeEvent = sawNonResizeEvent or not resizeFastPathEvent(e.kind)
        if e.kind == WindowResizeEvent and resizeTraceEnabled():
          inc resizeTrace.resizeEvents
        handleEvent(e, running, updateContext, drawContext)
    if sawResizeEvent:
      if resizeTraceEnabled():
        inc resizeTrace.fastResizePresents
      let now = input.getTicks()
      resizePacer.startedResizePresent(now)
      resizeRedrawTicks = now + resizePacer.config.settleMs
      hasResizeRedraw = true
    let fullFrameStart = input.getTicks()
    drawContext.ticks = input.getTicks()
    bench.frame:
      blk
      recordFullFrame(fullFrameStart, sawResizeEvent)
      updateContext.mouseLeftPressed = false
      bench.zone("present"):
        refresh()
  reportResizeTrace("shutdown", true)
  bench.finish()
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
  ui.loadFont("icon", "nerd-monospace", 18)
  let
    useResizeFastPath = resizeFastPathAllowed(cfg.resizeFastPath)
    usePointerFastPath = pointerFastPathAllowed(cfg.pointerFastPath)
  var
    firstFrame = true
    nextFrameTicks = input.getTicks()
    frameRemainder = 0
    hasResizeRedraw = false
    resizeRedrawTicks = 0
    lastResizeFullFrameTicks = input.getTicks()
    resizePacer = ResizePacer.init(resizeStrategy())
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
          drainPendingEvents(e, inputFlags, running, true):
            handleEvent(e, running, ui)
        now = input.getTicks()
      drainPendingEvents(e, inputFlags, running, false):
        handleEvent(e, running, ui)
      ui.setDrawTicks(input.getTicks())
      bench.frame:
        blk
        ui.finishInputFrame()
        if ui.redrewFrame():
          bench.zone("present"):
            refresh()
        else:
          bench.heldFrame()
      scheduleNextFrame(nextFrameTicks, frameRemainder, input.getTicks())
      continue

    var shouldRender = firstFrame
    firstFrame = false
    let
      nowTicks = input.getTicks()
      redrawWaitMs = ui.redrawDelayMs()
      resizeWaitMs =
        if hasResizeRedraw:
          max(resizeRedrawTicks - nowTicks, 0)
        else:
          -1
      appWaitMs = mergedAppWaitMs(redrawWaitMs, resizeWaitMs)
      waitMs = resizePacer.waitMs(nowTicks, appWaitMs)
    let frameEvent =
      if shouldRender:
        false
      else:
        input.waitEvent(e, waitMs, inputFlags)
    let afterWaitTicks = input.getTicks()
    let pumpDue = resizePacer.pumpDue(afterWaitTicks)
    if frameEvent:
      shouldRender = true
    elif pumpDue:
      if resizeTraceEnabled():
        inc resizeTrace.fastResizePresents
      resizePacer.finishedPumpPresent(afterWaitTicks)
      # A pump is a present, not a frame. Nothing has changed since the last
      # resize event; the compositor just wants pixels while the surface is
      # being resized, so repaint what is already solved rather than running
      # the application again.
      var pumped = false
      if ui.hasRetainedFrame() and not ui.fullRedrawDue():
        bench.frame:
          if ui.drawRetainedFrame():
            pumped = true
            bench.zone("present"):
              refresh()
      if pumped:
        continue
      shouldRender = true
    elif hasResizeRedraw and resizeRedrawTicks <= afterWaitTicks:
      shouldRender = true
      hasResizeRedraw = false
      resizePacer.settledResize()
      if redrawWaitMs >= 0 and ui.redrawDelayMs() == 0:
        ui.clearRedrawRequest()
    elif hasResizeRedraw:
      if redrawWaitMs >= 0 and ui.redrawDelayMs() == 0:
        ui.clearRedrawRequest()
      shouldRender = true
    elif redrawWaitMs >= 0 and ui.redrawDelayMs() == 0:
      var serviced = false
      bench.frame:
        serviced = ui.redrawRetainedIfClean()
      if serviced:
        continue
      shouldRender = true
      ui.clearRedrawRequest()
    if not shouldRender:
      continue
    ui.beginInputFrame()
    var
      sawResizeEvent = false
      sawNonResizeEvent = false
      sawUncoalescableEvent = false
      sawPointerMotion = false
    if frameEvent:
      sawResizeEvent = e.kind == WindowResizeEvent
      sawNonResizeEvent = not resizeFastPathEvent(e.kind)
      sawUncoalescableEvent = not resizeCoalescableEvent(e.kind)
      sawPointerMotion = e.kind == MouseMoveEvent
      if sawResizeEvent and resizeTraceEnabled():
        inc resizeTrace.resizeEvents
      handleEvent(e, running, ui)
      drainPendingEvents(e, inputFlags, running, true):
        sawResizeEvent = sawResizeEvent or e.kind == WindowResizeEvent
        sawNonResizeEvent = sawNonResizeEvent or not resizeFastPathEvent(e.kind)
        sawUncoalescableEvent =
          sawUncoalescableEvent or not resizeCoalescableEvent(e.kind)
        sawPointerMotion = sawPointerMotion or e.kind == MouseMoveEvent
        if e.kind == WindowResizeEvent and resizeTraceEnabled():
          inc resizeTrace.resizeEvents
        handleEvent(e, running, ui)
    else:
      drainPendingEvents(e, inputFlags, running, false):
        sawResizeEvent = sawResizeEvent or e.kind == WindowResizeEvent
        sawNonResizeEvent = sawNonResizeEvent or not resizeFastPathEvent(e.kind)
        sawUncoalescableEvent =
          sawUncoalescableEvent or not resizeCoalescableEvent(e.kind)
        sawPointerMotion = sawPointerMotion or e.kind == MouseMoveEvent
        if e.kind == WindowResizeEvent and resizeTraceEnabled():
          inc resizeTrace.resizeEvents
        handleEvent(e, running, ui)
    if sawResizeEvent:
      if resizeTraceEnabled():
        inc resizeTrace.fastResizePresents
      let now = input.getTicks()
      resizePacer.startedResizePresent(now)
      resizeRedrawTicks = now + resizePacer.config.settleMs
      hasResizeRedraw = true
    if sawResizeEvent and resizeTraceEnabled():
      if not ui.hasRetainedFrame():
        inc resizeTrace.blockedNoRetained
      if sawNonResizeEvent:
        inc resizeTrace.blockedNonFastEvent
    # The fast pass. A resize changes only the size suggested for the root
    # box and pointer motion changes nothing at all about the tree, so both
    # can be answered from the frame that is already solved: a resize by
    # re-solving its constraint system, motion by re-running hit testing over
    # it. Either is a fraction of the cost of rebuilding the frame, which
    # means re-running the whole application body.
    #
    # The slow pass is not abandoned, only deferred. A resize burst gets a
    # full frame every `resizeFullFrameMs`, and a fast pointer frame asks for
    # one `pointerSettleMs` later, so anything the application draws from the
    # pointer's own position still catches up.
    var handledFast = false
    if not sawUncoalescableEvent and not ui.fullRedrawDue() and
        ui.hasRetainedFrame():
      if sawResizeEvent and useResizeFastPath and
          input.getTicks() - lastResizeFullFrameTicks < cfg.resizeFullFrameMs:
        bench.frame:
          handledFast = ui.resolveRetainedFrame(ui.windowWidth, ui.windowHeight)
          if handledFast:
            ui.finishInputFrame()
            if ui.redrewFrame():
              bench.zone("present"):
                refresh()
      elif not sawResizeEvent and sawPointerMotion and usePointerFastPath and
          ui.canResolveRetained():
        bench.frame:
          # Hit testing against the frame already on screen. Whether it turns
          # out to need repainting -- the pointer crossed into a widget -- or
          # not, the frame is answered: motion alone cannot change the tree.
          discard ui.updateRetainedFrame()
          handledFast = true
          ui.requestFullRedrawAfter(cfg.pointerSettleMs)
          ui.finishInputFrame()
          if ui.redrewFrame():
            bench.zone("present"):
              refresh()
          else:
            bench.heldFrame()
    if handledFast:
      continue
    if sawResizeEvent:
      lastResizeFullFrameTicks = input.getTicks()
      ui.requestResizeFrame()
    let fullFrameStart = input.getTicks()
    ui.setDrawTicks(input.getTicks())
    bench.frame:
      blk
      recordFullFrame(fullFrameStart, sawResizeEvent)
      ui.finishInputFrame()
      if ui.redrewFrame():
        bench.zone("present"):
          refresh()
      else:
        bench.heldFrame()
  reportResizeTrace("shutdown", true)
  bench.finish()
  shutdown()

proc eventTypeOf*[M, E](
    view: proc(ui: var UI; model: M; emitted: var seq[E]) {.nimcall.}
): E =
  ## Return the event type of a root widget that collects into a parameter.
  ##
  ## Only its type is of interest: `runApp` declares its queue from it, and
  ## never calls this.
  discard

proc eventTypeOf*[M, E](
    view: proc(ui: var UI; model: var M; emitted: var seq[E]) {.nimcall.}
): E =
  ## Return the event type of a root widget that collects into a parameter and
  ## takes its model by `var`.
  discard

proc appLoop(cfg, initial, update, view, blk: NimNode): NimNode =
  ## Build the frame loop `runApp` expands to.
  ##
  ## `ui`, `model` and `msgs` are spliced as plain identifiers, so the caller's
  ## block can name them. `update` may be nil, for a root widget that emits
  ## nothing and so has no events to apply.
  let
    uiSym = ident"ui"
    modelSym = ident"model"
    msgsSym = ident"msgs"
    msgSym = ident"msg"
    cfgSym = genSym(nskLet, "appCfg")

  let eventlessLoop = quote do:
    application `cfgSym`, `uiSym`:
      `uiSym`.layout:
        `view`(`uiSym`, `modelSym`)

        `uiSym`.events:
          `blk`

  if update.isNil:
    return quote do:
      block:
        let `cfgSym` = `cfg`
        var `uiSym` = UI.init()
        var `modelSym` = `initial`
        when compiles(`view`(`uiSym`, `modelSym`)):
          when typeof(`view`(`uiSym`, `modelSym`)) is void:
            `eventlessLoop`
          else:
            {.
              error:
                "runApp needs an `update` for a root widget that emits its " &
                "own events"
            .}
        else:
          {.
            error:
              "runApp without an `update` needs a root widget that takes " &
              "only the model, as `widget name(model: M)`"
          .}

  let queuedLoop = quote do:
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

  quote do:
    block:
      let `cfgSym` = `cfg`
      var `uiSym` = UI.init()
      var `modelSym` = `initial`
      when compiles(`view`(`uiSym`, `modelSym`)):
        when typeof(`view`(`uiSym`, `modelSym`)) is void:
          `eventlessLoop`
        else:
          var `msgsSym`: typeof(`view`(`uiSym`, `modelSym`))
          `queuedLoop`
      elif compiles(eventTypeOf(`view`)):
        var `msgsSym`: seq[typeof(eventTypeOf(`view`))]
        `queuedLoop`
      else:
        {.
          error:
            "runApp needs a root widget that emits its own events, takes an " &
            "`emitted: var seq[E]` parameter, or emits nothing at all"
        .}

macro runApp*(cfg, initial, update, view, blk: untyped): untyped =
  ## Run a Model/Msg/update/view application until its window closes.
  ##
  ## Opens the window described by `cfg`, holds `initial` as the model, and runs
  ## one frame at a time: the message queue is cleared, `view` declares the
  ## interface, then every message it collected is applied with `update`.
  ##
  ## `view` is the root widget, in any of three shapes: one that emits its own
  ## events, called as `view(ui, model)` and returning them; one that collects
  ## into a parameter, called as `view(ui, model, emitted)`; or one that emits
  ## nothing, called as `view(ui, model)` and returning nothing. The queue's
  ## type is taken from whichever it is. `update` is called as
  ## `update(model, event)` for every event of the frame, which resolves among
  ## as many `update` overloads as the application has state types, and is not
  ## called at all for a root widget that emits nothing.
  ##
  ## `blk` runs at the end of every event pass, with `ui`, `model` and `running`
  ## in scope, plus `msgs` unless the root emits nothing. Setting `running` to
  ## false leaves the loop.
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
  ## The last argument may also be a trailing block rather than the root widget,
  ## as in `runApp(cfg, initial, view): ...`, which runs an application whose
  ## root emits nothing. Use the five-argument overload to pass both an `update`
  ## and a trailing block.
  if view.kind == nnkStmtList:
    appLoop(cfg, initial, nil, update, view)
  else:
    appLoop(cfg, initial, update, view,
      newStmtList(nnkDiscardStmt.newTree(newEmptyNode())))

macro runApp*(cfg, initial, view: untyped): untyped =
  ## Run an application whose root widget emits nothing, until its window
  ## closes.
  ##
  ## Opens the window described by `cfg`, holds `initial` as the model, and
  ## calls `view(ui, model)` once per frame. There is no message queue and no
  ## `update`: a root widget in this shape either draws from the model alone or
  ## takes it as `var` and changes it in place.
  ##
  ## ```nim
  ## widget root(model: App):
  ##   ui.label(ui.id("hello"), "Hello, World!")
  ##
  ## when isMainModule:
  ##   runApp(AppConfig.init(width = 360, height = 180, title = "Hello"), App(), root)
  ## ```
  appLoop(cfg, initial, nil, view,
    newStmtList(nnkDiscardStmt.newTree(newEmptyNode())))
