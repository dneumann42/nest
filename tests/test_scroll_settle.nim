## A scroll that is still moving has to keep asking for frames.
##
## Scrolling is animated: a wheel notch moves the target and the offset eases
## toward it over the frames that follow. The easing happens while the frame is
## laid out, so a repaint of the retained frame does not advance it — a
## settling scroll has to ask for a *full* frame, and the loop has to agree
## that the frame is due. Get either half wrong and the list freezes the moment
## the wheel stops, then lurches forward whenever some unrelated input happens
## to force a rebuild, which looks like a scroll that only animates while the
## mouse is moving.
##
## The other half matters just as much: once the offset reaches its target the
## container must stop asking, so the loop goes back to sleep instead of
## running at sixty frames a second forever.
##
## These drive the real `application` loop rather than a stand-in for it. A
## hand-rolled loop is exactly where this bug hides: the frame clock and the
## live clock only disagree once something advances one of them and not the
## other, which is what the real loop does and a simplified one does not.

import std/[strformat, unittest]

import nest/[appConfig, coords, input, palette, resources, runtime, screen, ui]

const
  ViewportHeight = 300
  RowHeight = 25.0
  Rows = 200
  WheelNotches = -5.0

type Script = object
  pending: seq[Event]
  next: int
  ticks: int
  timeouts: int
  blockedForever: bool

var script: Script

proc scriptedPoll(e: var Event, flags: set[InputFlag]): bool {.nimcall.} =
  ## Nothing is ever pending: the loop gets one event per wake, so a frame
  ## cannot quietly absorb the whole script.
  discard (e, flags)
  false

proc scriptedWait(
    e: var Event, timeoutMs: int, flags: set[InputFlag]
): bool {.nimcall.} =
  discard flags
  if script.next < script.pending.len:
    e = script.pending[script.next]
    inc script.next
    inc script.ticks
    return true
  if timeoutMs < 0:
    # The loop asked to block until something happens. Nothing will: this is
    # the application saying it has nothing left to do.
    script.blockedForever = true
    e = Event(kind: QuitEvent)
    return true
  inc script.timeouts
  if script.timeouts > 400:
    e = Event(kind: QuitEvent)
    return true
  # Real time passes while the loop waits, and only real time.
  script.ticks += max(timeoutMs, 1)
  false

proc scriptedTicks(): int {.nimcall.} =
  script.ticks

proc scriptedSleep(ms: int) {.nimcall.} =
  script.ticks += max(ms, 0)

proc scriptedShutdown() {.nimcall.} =
  discard

proc installScript(events: seq[Event]) =
  script = Script(pending: events, next: 0, ticks: 1)
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
    layout = ScreenLayout(width: 300, height: ViewportHeight, scaleX: 1, scaleY: 1)
  windowRelays.refresh = proc() =
    inc presents
  windowRelays.saveState = proc() = discard
  windowRelays.restoreState = proc() = discard
  windowRelays.setClipRect = proc(r: Rect) = discard
  windowRelays.setCursor = proc(c: CursorKind) = discard
  windowRelays.setWindowTitle = proc(title: string) = discard
  windowRelays.moveWindowBy = proc(dx, dy: int) = discard

proc list(ui: var UI) =
  ui.column(ui.id("panel"), cfg(width = fill(), height = fill(), gap = 0)):
    ui.column(ui.id("list"), cfg(width = fill(), height = fill(), gap = 0,
        scrollY = true, scrollWheel = true, alignItems = Stretch)):
      for i in 0 ..< Rows:
        discard ui.button(ui.id("row", $i), &"row {i}", width = fill(),
            height = fixed(RowHeight))

type Run = object
  offsets: seq[float64] ## The scroll offset at the end of every full frame.
  fullFrames: int
  wentIdle: bool

proc runScroll(events: seq[Event]): Run =
  ## Run the real loop over `events`, then over nothing at all.
  var ui = UI.init()
  var installed = false
  var offsets: seq[float64]
  var fullFrames = 0
  let cfg = AppConfig.init(width = 300, height = ViewportHeight, title = "scroll")
  application cfg, ui:
    if not installed:
      installed = true
      installScript(events)
      stubScreen()
    ui.layout:
      ui.list()
    inc fullFrames
    offsets.add ui.scrollOffset(ui.id("list")).y
  Run(offsets: offsets, fullFrames: fullFrames,
      wentIdle: script.blockedForever)

proc wheel(notches: float64): Event =
  Event(kind: MouseWheelEvent, mouseX: 150, mouseY: 150, wheelY: notches)

proc movingFrames(offsets: seq[float64]): int =
  for i in 1 ..< offsets.len:
    if offsets[i] > offsets[i - 1] + 0.01:
      inc result

suite "scroll settling":
  setup:
    stubFonts()
    stubScreen()
    presents = 0

  test "a scroll keeps easing on frames it asks for itself":
    # One wheel notch and then nothing: every frame after the first is one the
    # scroll container asked for, and the offset has to keep climbing across
    # them. Before this worked, the loop answered those requests with a repaint
    # of the retained frame, which cannot ease anything, and the list stopped
    # dead until unrelated input forced a rebuild.
    let run = runScroll(@[wheel(WheelNotches)])
    let moving = movingFrames(run.offsets)
    checkpoint(&"{run.fullFrames} full frames, {moving} of them moving, " &
      &"offsets {run.offsets}")
    check moving >= 4
    check run.offsets[^1] > 100.0

  test "the ease reaches its target and the loop then blocks":
    let run = runScroll(@[wheel(WheelNotches)])
    checkpoint(&"settled at {run.offsets[^1]} after {run.fullFrames} frames")
    # Five notches at the wheel step, eased to a stop.
    check run.offsets[^1] == 5.0 * 42.0
    # And it stopped asking: the loop got as far as an indefinite wait.
    check run.wentIdle
    # In a sane number of frames, not by running out of the timeout budget.
    check run.fullFrames < 60

  test "the last frames of a scroll do not repeat the same offset forever":
    # A container that keeps asking after it has come to rest pins the loop at
    # sixty frames a second for nothing.
    let run = runScroll(@[wheel(WheelNotches)])
    var trailing = 0
    for i in countdown(run.offsets.high, 1):
      if run.offsets[i] == run.offsets[i - 1]:
        inc trailing
      else:
        break
    checkpoint(&"{trailing} still frames at the end of {run.fullFrames}")
    # A handful of frames after the offset lands is the rest of the frame the
    # wheel started -- the pointer settle, the container going inactive. What
    # must not happen is the container asking for ever more of them, which
    # `wentIdle` above proves it does not.
    check trailing <= 6
    check trailing * 2 < run.fullFrames

  test "a repaint of the retained frame advances a settling scroll":
    # The easing used to happen only while a frame was laid out, so every
    # cheaper kind of frame -- a repaint, pointer motion answered from the
    # retained tree, a resize pump -- consumed the frame the scroll had asked
    # for without moving it. Whichever frame the loop picks has to advance it.
    installScript(@[])
    var ui = UI.init()
    ui.initContext(300, ViewportHeight)
    ui.loadFont("font", "", 18)

    ui.beginInputFrame()
    ui.setDrawTicks(script.ticks)
    ui.layout:
      ui.list()
    ui.finishInputFrame()

    # A wheel notch, consumed by a full frame, which sets the target.
    ui.beginInputFrame()
    ui.mouseMove(150, 150)
    ui.mouseWheel(0.0, WheelNotches)
    ui.setDrawTicks(script.ticks)
    ui.layout:
      ui.list()
    ui.finishInputFrame()
    check ui.hasSettlingScroll()

    # From here, only retained repaints. The offset still has to climb.
    var moved = 0
    var last = ui.scrollOffset(ui.id("list")).y
    for _ in 0 ..< 40:
      script.ticks += 16
      ui.setDrawTicks(script.ticks)
      discard ui.drawRetainedFrame()
      let now = ui.scrollOffset(ui.id("list")).y
      if now > last + 0.01:
        inc moved
        last = now
    checkpoint(&"{moved} repaints moved the scroll, ending at {last}")
    check moved >= 4
    check last == 5.0 * 42.0
    check not ui.hasSettlingScroll()

  test "a scroll eases while the pointer is moving over it":
    # The report this was written for: with the mouse moving, every frame goes
    # down the pointer fast path, which answers from the retained tree.
    var events: seq[Event]
    events.add wheel(WheelNotches)
    for i in 0 ..< 30:
      events.add Event(kind: MouseMoveEvent, x: 150 + i mod 7, y: 150 + i mod 5)
    let run = runScroll(events)
    checkpoint(&"offsets {run.offsets}")
    check run.offsets[^1] == 5.0 * 42.0

  test "a deadline is due on the clock the loop waits on":
    # The frame clock is frozen for the length of a frame so that everything
    # drawn in it agrees on the time. Deadlines must not be measured against
    # it: `redrawDelayMs` waits on the backend clock, so a deadline compared
    # against the frame clock is one the loop waits for and never sees arrive.
    installScript(@[])
    var ui = UI.init()
    ui.initContext(200, 200)
    ui.loadFont("font", "", 18)

    ui.beginInputFrame()
    ui.setDrawTicks(script.ticks)
    ui.layout:
      ui.label(ui.id("hello"), "hi", width = fill(), height = fit())
    ui.finishInputFrame()
    check not ui.needsFullRender()

    ui.beginInputFrame()
    ui.setDrawTicks(script.ticks)   # the frame clock stops here
    ui.requestFullRedrawAfter(16)
    ui.layout:
      ui.label(ui.id("hello"), "hi", width = fill(), height = fit())
    ui.finishInputFrame()

    script.ticks += 16              # only real time moves on
    check ui.redrawDelayMs() == 0   # the loop says the wait is over
    check ui.needsFullRender()      # and so must whatever decides it is due

  test "a list with no scrolling asks for nothing":
    # Starting up costs a few frames; what matters is that it reaches an
    # indefinite wait rather than settling into a steady tick.
    let run = runScroll(@[])
    checkpoint(&"{run.fullFrames} frames to reach idle")
    check run.wentIdle
    check run.fullFrames <= 6
