## What the main loop decides to do with a frame.
##
## Nest answers cheap events from the frame it already has: a resize by
## re-solving its constraint system, pointer motion by re-running hit testing
## over it, and a quiet moment by holding it and drawing nothing at all. Only
## the events that can change the widget tree run the application body.
##
## These tests drive the real loop against a scripted event stream and count
## what it did, because the decision is easy to regress by accident: a stray
## redraw request or a lost dirty flag turns a held frame back into a rebuild
## and the cost only shows up as a hot CPU.

import std/[unittest]

import nest/[appConfig, coords, input, palette, resources, runtime, screen, ui]

type ScriptedInput = object
  events: seq[Event]
  next: int
  ticks: int

var script: ScriptedInput

proc scriptedPoll(e: var Event, flags: set[InputFlag]): bool {.nimcall.} =
  ## Nothing is ever pending: the script hands out one event per wake.
  ##
  ## The loop drains everything queued into a single frame, which is right
  ## for a burst but would collapse the whole script into one frame and
  ## measure nothing. One event per wake is the case these tests are about --
  ## events arriving faster than frames can be built.
  discard (e, flags)
  false

proc scriptedWait(
    e: var Event, timeoutMs: int, flags: set[InputFlag]
): bool {.nimcall.} =
  discard flags
  if script.next >= script.events.len:
    # Let the clock reach whatever deadline the loop was waiting for, so a
    # timer-driven frame still happens, then close the run down. Every wait
    # past the end of the script quits, so no scheduling decision can leave
    # the loop spinning here.
    script.ticks += (if timeoutMs > 0: timeoutMs else: 1)
    e = Event(kind: QuitEvent)
    return true
  e = script.events[script.next]
  inc script.next
  inc script.ticks
  true

proc scriptedTicks(): int {.nimcall.} =
  script.ticks

proc scriptedSleep(ms: int) {.nimcall.} =
  script.ticks += max(ms, 0)

proc scriptedShutdown() {.nimcall.} =
  discard

proc installScript(events: seq[Event]) =
  script = ScriptedInput(events: events, next: 0, ticks: 1)
  inputRelays = InputRelays(
    pollEvent: scriptedPoll,
    waitEvent: scriptedWait,
    getTicks: scriptedTicks,
    sleep: scriptedSleep,
    shutdown: scriptedShutdown,
  )

proc stubFonts() =
  fontRelays = FontRelays(
    openFont: proc(path: string, size: int, metrics: var FontMetrics): Font =
    discard path
    metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
    Font(max(size, 1)),
    closeFont: proc(f: Font) =
    discard f,
    getFontMetrics: proc(f: Font): FontMetrics =
    discard f
    FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
    measureText: proc(f: Font, text: string): TextExtent =
    discard f
    TextExtent(w: max(text.len, 1) * 9, h: 18),
    drawText: proc(f: Font, x, y: int, text: string, fg, bg: Color): TextExtent =
    discard (f, x, y, fg, bg)
    TextExtent(w: max(text.len, 1) * 9, h: 18),
  )

var presents = 0

proc stubScreen() =
  drawRelays = DrawRelays(
    fillRect: proc(r: Rect, color: Color) =
    discard (r, color),
    lineRect: proc(r: Rect, color: Color) =
    discard (r, color),
    drawLine: proc(x1, y1, x2, y2: int, color: Color) =
    discard (x1, y1, x2, y2, color),
    drawPoint: proc(x, y: int, color: Color) =
    discard (x, y, color),
    loadImage: proc(path: string): Image =
    discard path
    Image(1),
    freeImage: proc(img: Image) =
    discard img,
    drawImage: proc(img: Image, src, dst: Rect) =
    discard (img, src, dst),
    drawImageOpacity: proc(img: Image, src, dst: Rect, opacity: float64) =
    discard (img, src, dst, opacity),
    imageSize: proc(img: Image): TextExtent =
    discard img
    TextExtent(w: 32, h: 32),
  )
  windowRelays.createWindow = proc(layout: var ScreenLayout) =
    layout = ScreenLayout(width: 800, height: 600, scaleX: 1, scaleY: 1)
  windowRelays.refresh = proc() =
    inc presents
  windowRelays.saveState = proc() = discard
  windowRelays.restoreState = proc() = discard
  windowRelays.setClipRect = proc(r: Rect) = discard
  windowRelays.setCursor = proc(c: CursorKind) = discard
  windowRelays.setWindowTitle = proc(title: string) = discard
  windowRelays.moveWindowBy = proc(dx, dy: int) = discard

var
  bodyRuns = 0
  rightClicks = 0
  middleClicks = 0

proc tree(ui: var UI) =
  inc bodyRuns
  ui.column(ui.id("root"), cfg(width = fill(), height = fill(), gap = 4,
      padding = 6)):
    ui.row(ui.id("bar"), cfg(width = fill(), height = fit(), gap = 4)):
      for i in 0 ..< 6:
        let toolID = ui.id("tool", $i)
        discard ui.button(toolID, "tool")
        if ui.rightClicked(toolID):
          inc rightClicks
        if ui.middleClicked(toolID):
          inc middleClicks
    ui.label(ui.id("body"), "content", width = fill(), height = fill())

type Counts = object
  bodyRuns: int
  presents: int

proc runLoop(events: seq[Event], cfg: AppConfig): Counts =
  var ui = UI.init()
  var frames = 0
  # `application` opens the window, and opening it installs the real backend
  # relays over these. The first iteration renders without waiting for an
  # event, so the scripted backend goes in from inside the body, before the
  # loop asks for its first one.
  var scriptInstalled = false
  application cfg, ui:
    if not scriptInstalled:
      scriptInstalled = true
      installScript(events)
      stubScreen()
      bodyRuns = 0
      presents = 0
      rightClicks = 0
      middleClicks = 0
    ui.layout:
      ui.tree()
    inc frames
    if script.ticks > 100_000 or frames > events.len + 16:
      running = false
  # The body runs twice per full frame: once to dispatch events and once to
  # build the tree. Report full frames, not passes.
  Counts(bodyRuns: bodyRuns div 2, presents: presents)

proc motion(x, y: int): Event =
  Event(kind: MouseMoveEvent, x: x, y: y)

proc resized(w, h: int): Event =
  Event(kind: WindowResizeEvent, x: w, y: h)

proc quitEvent(): Event =
  Event(kind: QuitEvent)

proc baseConfig(): AppConfig =
  AppConfig.init(width = 800, height = 600, title = "pacing")

suite "frame pacing":
  setup:
    stubFonts()
    stubScreen()

  test "a stream of pointer motion does not rebuild the frame each time":
    var events: seq[Event]
    for i in 0 ..< 60:
      events.add motion(20 + i, 30 + i)
    events.add quitEvent()

    let fast = runLoop(events, baseConfig())
    var slowConfig = baseConfig()
    slowConfig.pointerFastPath = false
    let slow = runLoop(events, slowConfig)

    checkpoint("fast " & $fast.bodyRuns & " rebuilds, slow " & $slow.bodyRuns)
    check fast.bodyRuns < slow.bodyRuns
    # A settle frame is allowed every `pointerSettleMs`, but nowhere near one
    # rebuild per motion event.
    check fast.bodyRuns * 3 < slow.bodyRuns

  test "a stream of resizes does not rebuild the frame each time":
    var events: seq[Event]
    for i in 0 ..< 60:
      events.add resized(800 + i * 4, 600 + i * 2)
    events.add quitEvent()

    let fast = runLoop(events, baseConfig())
    var slowConfig = baseConfig()
    slowConfig.resizeFastPath = false
    let slow = runLoop(events, slowConfig)

    checkpoint("fast " & $fast.bodyRuns & " rebuilds, slow " & $slow.bodyRuns)
    check fast.bodyRuns < slow.bodyRuns

  test "the fast pass still presents every frame it is given":
    var events: seq[Event]
    for i in 0 ..< 30:
      events.add resized(800 + i * 4, 600 + i * 2)
    events.add quitEvent()
    let counts = runLoop(events, baseConfig())
    check counts.presents >= 30

  test "a click always runs the application body":
    var events: seq[Event]
    events.add motion(24, 24)
    events.add Event(kind: MouseDownEvent, x: 24, y: 24)
    events.add Event(kind: MouseUpEvent, x: 24, y: 24)
    events.add quitEvent()
    let before = runLoop(@[quitEvent()], baseConfig())
    let after = runLoop(events, baseConfig())
    check after.bodyRuns > before.bodyRuns

  test "right and middle buttons retain their identity":
    discard runLoop(@[
      Event(kind: MouseDownEvent, button: RightButton, x: 24, y: 24),
      Event(kind: MouseUpEvent, button: RightButton, x: 24, y: 24),
      Event(kind: MouseDownEvent, button: MiddleButton, x: 24, y: 24),
      Event(kind: MouseUpEvent, button: MiddleButton, x: 24, y: 24),
      quitEvent(),
    ], baseConfig())
    check rightClicks == 1
    check middleClicks == 1

  test "a key press always runs the application body":
    var events: seq[Event]
    events.add Event(kind: KeyDownEvent, key: KeyA)
    events.add quitEvent()
    let before = runLoop(@[quitEvent()], baseConfig())
    let after = runLoop(events, baseConfig())
    check after.bodyRuns > before.bodyRuns

  test "an external wake always runs the application body":
    let before = runLoop(@[quitEvent()], baseConfig())
    let after = runLoop(@[Event(kind: WakeEvent), quitEvent()], baseConfig())
    check after.bodyRuns > before.bodyRuns
