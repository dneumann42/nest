## Compile-time frame instrumentation for Nest.
##
## Everything in this module compiles to nothing unless the application is
## built with `-d:nestBench`. The instrumentation is written as templates so
## that a disabled build leaves no call, no branch and no globals behind: a
## `bench.zone` expands to its body and nothing else.
##
## Two levels are available. `-d:nestBench` turns on the phase-level zones,
## which is what you want for a normal profiling run: they cost one clock read
## per zone and there are a few dozen per frame. `-d:nestBenchDetail` adds the
## per-widget and per-component zones on top, which are accurate but numerous
## enough to distort the very frame times they measure; use them to find which
## widget is expensive, not to quote an absolute frame cost.
##
## A run reports in three ways, all controlled by the environment so a build
## can be left instrumented and stay quiet:
##
## - `NEST_BENCH_REPORT_MS=1000` prints a rolling table every second.
## - `NEST_BENCH_JSON=path` writes the whole run as JSON when it ends.
## - `NEST_BENCH_SUMMARY=1` prints one table when it ends.
##
## Frames are classified as they are recorded, so the report says not just how
## long frames took but which kind of frame they were: a full rebuild, a
## re-solve of the retained layout, a repaint of the retained tree, or a frame
## that decided to hold what was already on screen.

import std/[algorithm, math, monotimes, os, strformat, strutils, tables]

const
  NestBench* {.booldefine: "nestBench".} = false
    ## Whether phase-level frame instrumentation is compiled in.
  NestBenchDetail* {.booldefine: "nestBenchDetail".} = false
    ## Whether per-widget instrumentation is compiled in on top of `NestBench`.

const
  MaxZones = 128
  FrameHistory = 600

type
  FrameKind* = enum ## How a frame decided to spend itself.
    fkUnknown = "unknown"
    fkHold = "hold" ## Nothing changed; the previous frame stays on screen.
    fkRealtime = "realtime" ## Only the animating widgets were repainted.
    fkRetainedDraw = "retained-draw" ## The retained tree was repainted.
    fkRetainedUpdate = "retained-update" ## Retained tree, hit-tested first.
    fkResolve = "resolve" ## Retained tree re-solved, normally a resize.
    fkReused = "full-reused"
      ## Widgets rebuilt and drawn, but the constraint system was the
      ## previous frame's, so the layout was a re-solve rather than a rebuild.
    fkFull = "full" ## Widgets rebuilt, layout solved, tree drawn.

  ZoneStat = object
    name: string
    calls: int
    totalNs: int64
    selfNs: int64
    maxNs: int64
    childNs: int64 # accumulator for the zone currently on the stack
    depth: int
    windowCalls: int
    windowTotalNs: int64
    windowSelfNs: int64
    windowMaxNs: int64

  CounterStat = object
    name: string
    total: int64
    window: int64
    windowMax: int64

  BenchState = object
    zones: array[MaxZones, ZoneStat]
    zoneCount: int
    zoneByName: Table[string, int]
    stack: seq[int]
    counters: array[MaxZones, CounterStat]
    counterCount: int
    counterByName: Table[string, int]
    frames: array[FrameKind, int]
    windowFrames: array[FrameKind, int]
    history: array[FrameHistory, int64]
    historyLen: int
    historyHead: int
    frameKind: FrameKind
    frameStartNs: int64
    inFrame: bool
    totalFrames: int
    windowFrameNs: int64
    totalFrameNs: int64
    maxFrameNs: int64
    startedNs: int64
    windowStartedNs: int64
    lastReportNs: int64
    configured: bool
    reportMs: int
    jsonPath: string
    summary: bool
    label: string

when NestBench:
  var benchState: BenchState

proc nowNs*(): int64 {.inline, raises: [].} =
  ## Return a monotonic timestamp in nanoseconds.
  getMonoTime().ticks

proc envInt(name: string, fallback: int): int {.raises: [].} =
  try:
    let raw = getEnv(name)
    if raw.len == 0: fallback else: parseInt(raw.strip())
  except CatchableError:
    fallback

proc envFlag(name: string): bool {.raises: [].} =
  try:
    getEnv(name).strip().toLowerAscii() in ["1", "true", "yes", "on"]
  except CatchableError:
    false

proc envText(name: string): string {.raises: [].} =
  try:
    getEnv(name)
  except CatchableError:
    ""

when NestBench:
  proc configure() {.raises: [].} =
    if benchState.configured:
      return
    benchState.configured = true
    benchState.zoneByName = initTable[string, int]()
    benchState.counterByName = initTable[string, int]()
    benchState.reportMs = envInt("NEST_BENCH_REPORT_MS", 0)
    benchState.jsonPath = envText("NEST_BENCH_JSON")
    benchState.summary = envFlag("NEST_BENCH_SUMMARY") or
      benchState.jsonPath.len > 0 or benchState.reportMs > 0
    benchState.label = envText("NEST_BENCH_LABEL")
    benchState.startedNs = nowNs()
    benchState.windowStartedNs = benchState.startedNs
    benchState.lastReportNs = benchState.startedNs

proc zoneSlot*(name: string): int {.raises: [].} =
  ## Return the index of the zone called `name`, registering it on first use.
  ##
  ## Call sites cache the result, so this runs once per instrumented site.
  when NestBench:
    configure()
    let existing = benchState.zoneByName.getOrDefault(name, -1)
    if existing >= 0:
      return existing
    if benchState.zoneCount >= MaxZones:
      return -1
    result = benchState.zoneCount
    inc benchState.zoneCount
    benchState.zones[result] = ZoneStat(name: name)
    benchState.zoneByName[name] = result
  else:
    discard name
    -1

proc counterSlot*(name: string): int {.raises: [].} =
  ## Return the index of the counter called `name`, registering it on first use.
  when NestBench:
    configure()
    let existing = benchState.counterByName.getOrDefault(name, -1)
    if existing >= 0:
      return existing
    if benchState.counterCount >= MaxZones:
      return -1
    result = benchState.counterCount
    inc benchState.counterCount
    benchState.counters[result] = CounterStat(name: name)
    benchState.counterByName[name] = result
  else:
    discard name
    -1

proc enterZone*(slot: int): int64 {.raises: [].} =
  ## Push `slot` onto the zone stack and return its start timestamp.
  when NestBench:
    if slot < 0:
      return 0
    benchState.zones[slot].childNs = 0
    inc benchState.zones[slot].depth
    benchState.stack.add slot
    nowNs()
  else:
    discard slot
    0

proc exitZone*(slot: int, startNs: int64) {.raises: [].} =
  ## Pop `slot` and fold the time since `startNs` into its statistics.
  ##
  ## Time spent in nested zones is subtracted, so `self` is the zone's own
  ## work and `total` includes everything it called.
  when NestBench:
    if slot < 0:
      return
    let elapsed = nowNs() - startNs
    if benchState.stack.len > 0:
      benchState.stack.setLen(benchState.stack.len - 1)
    template z(): untyped =
      benchState.zones[slot]

    let self = max(elapsed - z.childNs, 0)
    dec z.depth
    inc z.calls
    # A recursive zone would count its own nested time twice in `total`.
    if z.depth == 0:
      z.totalNs += elapsed
      if elapsed > z.maxNs:
        z.maxNs = elapsed
      z.windowTotalNs += elapsed
      if elapsed > z.windowMaxNs:
        z.windowMaxNs = elapsed
    z.selfNs += self
    z.windowSelfNs += self
    inc z.windowCalls
    if benchState.stack.len > 0:
      benchState.zones[benchState.stack[^1]].childNs += elapsed
  else:
    discard slot
    discard startNs

proc addCount*(slot: int, amount: int) {.raises: [].} =
  ## Add `amount` to the counter at `slot`.
  when NestBench:
    if slot < 0:
      return
    benchState.counters[slot].total += amount
    benchState.counters[slot].window += amount
  else:
    discard slot
    discard amount

template zone*(name: static string, body: untyped) =
  ## Time `body` as the zone `name`.
  ##
  ## Compiles to `body` alone unless the build passed `-d:nestBench`.
  when NestBench:
    block:
      var slot {.global.} = -2
      if slot == -2:
        slot = zoneSlot(name)
      let startNs = enterZone(slot)
      try:
        body
      finally:
        exitZone(slot, startNs)
  else:
    body

template detail*(name: static string, body: untyped) =
  ## Time `body` as the zone `name`, but only in a `-d:nestBenchDetail` build.
  ##
  ## Use this where the zone is entered once per widget rather than once per
  ## frame, so a normal profiling run is not slowed by its own clock reads.
  when NestBench and NestBenchDetail:
    zone(name, body)
  else:
    body

template count*(name: static string, amount: int) =
  ## Add `amount` to the counter `name`.
  when NestBench:
    block:
      var slot {.global.} = -2
      if slot == -2:
        slot = counterSlot(name)
      addCount(slot, amount)
  else:
    discard amount

template countDetail*(name: static string, amount: int) =
  ## Add `amount` to the counter `name`, in a `-d:nestBenchDetail` build only.
  when NestBench and NestBenchDetail:
    count(name, amount)
  else:
    discard amount

proc enabled*(): bool {.inline, raises: [].} =
  ## Test whether instrumentation is compiled into this build.
  NestBench

proc detailEnabled*(): bool {.inline, raises: [].} =
  ## Test whether per-widget instrumentation is compiled into this build.
  NestBench and NestBenchDetail

proc classifyFrame*(kind: FrameKind) {.raises: [].} =
  ## Record what kind of work the frame being measured turned out to be.
  ##
  ## A frame often only learns this partway through -- it may start as a
  ## repaint and discover it needs a full rebuild -- so the last call before
  ## the frame ends is the one that counts.
  when NestBench:
    configure()
    benchState.frameKind = kind
  else:
    discard kind

proc heldFrame*() {.raises: [].} =
  ## Record that the frame drew nothing, unless it already said what it did.
  ##
  ## A frame that ran the application and found nothing to paint is still a
  ## full frame -- that it presented nothing is what the `present` zone's
  ## call count says. Only a frame that did no work at all is a hold.
  when NestBench:
    configure()
    if benchState.frameKind == fkUnknown:
      benchState.frameKind = fkHold

proc beginFrame*() {.raises: [].} =
  ## Start measuring a frame.
  when NestBench:
    configure()
    benchState.frameKind = fkUnknown
    benchState.frameStartNs = nowNs()
    benchState.inFrame = true

proc report*(force = false) {.raises: [].}

proc endFrame*() {.raises: [].} =
  ## Finish measuring a frame and fold it into the statistics.
  when NestBench:
    if not benchState.inFrame:
      return
    benchState.inFrame = false
    let elapsed = nowNs() - benchState.frameStartNs
    inc benchState.totalFrames
    inc benchState.frames[benchState.frameKind]
    inc benchState.windowFrames[benchState.frameKind]
    benchState.totalFrameNs += elapsed
    benchState.windowFrameNs += elapsed
    if elapsed > benchState.maxFrameNs:
      benchState.maxFrameNs = elapsed
    benchState.history[benchState.historyHead] = elapsed
    benchState.historyHead = (benchState.historyHead + 1) mod FrameHistory
    if benchState.historyLen < FrameHistory:
      inc benchState.historyLen
    if benchState.reportMs > 0 and
        nowNs() - benchState.lastReportNs >= benchState.reportMs.int64 * 1_000_000:
      report()

template frame*(body: untyped) =
  ## Measure `body` as one frame.
  when NestBench:
    beginFrame()
    try:
      body
    finally:
      endFrame()
  else:
    body

when NestBench:
  proc ms(ns: int64): float64 {.inline.} =
    ns.float64 / 1_000_000.0

  proc percentile(sorted: openArray[int64], fraction: float64): int64 =
    if sorted.len == 0:
      return 0
    let index = clamp(int(round(fraction * (sorted.len - 1).float64)), 0,
        sorted.len - 1)
    sorted[index]

  proc sortedHistory(): seq[int64] =
    result = newSeqOfCap[int64](benchState.historyLen)
    for i in 0 ..< benchState.historyLen:
      result.add benchState.history[i]
    result.sort()

  proc resetWindow() =
    for i in 0 ..< benchState.zoneCount:
      benchState.zones[i].windowCalls = 0
      benchState.zones[i].windowTotalNs = 0
      benchState.zones[i].windowSelfNs = 0
      benchState.zones[i].windowMaxNs = 0
    for i in 0 ..< benchState.counterCount:
      benchState.counters[i].window = 0
    for kind in FrameKind:
      benchState.windowFrames[kind] = 0
    benchState.windowFrameNs = 0
    benchState.windowStartedNs = nowNs()

  proc frameKindSummary(windowed: bool): string =
    var parts: seq[string]
    for kind in FrameKind:
      let n = if windowed: benchState.windowFrames[kind] else: benchState.frames[kind]
      if n > 0:
        parts.add &"{kind} {n}"
    parts.join("  ")

  proc zoneTable(windowed: bool, frames: int): string =
    var order: seq[int]
    for i in 0 ..< benchState.zoneCount:
      let calls = if windowed: benchState.zones[i].windowCalls else: benchState.zones[i].calls
      if calls > 0:
        order.add i
    order.sort do (a, b: int) -> int:
      let
        left = if windowed: benchState.zones[a].windowTotalNs else: benchState.zones[a].totalNs
        right = if windowed: benchState.zones[b].windowTotalNs else: benchState.zones[b].totalNs
      cmp(right, left)

    let denom = max(frames, 1).float64
    result = "  " & "zone".alignLeft(30) & "calls/f".align(9) &
      "total ms".align(11) & "self ms".align(10) & "ms/frame".align(10) &
      "max ms".align(9) & "\n"
    result.add "  " & repeat('-', 79) & "\n"
    for i in order:
      let
        z = benchState.zones[i]
        calls = if windowed: z.windowCalls else: z.calls
        total = if windowed: z.windowTotalNs else: z.totalNs
        self = if windowed: z.windowSelfNs else: z.selfNs
        peak = if windowed: z.windowMaxNs else: z.maxNs
      result.add "  " & z.name.alignLeft(30) &
        (&"{calls.float64 / denom:.1f}").align(9) &
        (&"{ms(total):.2f}").align(11) &
        (&"{ms(self):.2f}").align(10) &
        (&"{ms(total) / denom:.3f}").align(10) &
        (&"{ms(peak):.3f}").align(9) & "\n"

  proc counterTable(windowed: bool, frames: int): string =
    var parts: seq[string]
    let denom = max(frames, 1).float64
    for i in 0 ..< benchState.counterCount:
      let
        c = benchState.counters[i]
        value = if windowed: c.window else: c.total
      if value != 0:
        parts.add &"{c.name}={value.float64 / denom:.1f}/f"
    if parts.len == 0:
      return ""
    "  counters: " & parts.join("  ") & "\n"

proc summary*(windowed = false): string {.raises: [].} =
  ## Return the instrumentation report as a text table.
  ##
  ## `windowed` reports only what happened since the last periodic report,
  ## which is what a live run wants; the default reports the whole run.
  when NestBench:
    configure()
    let
      frames = if windowed: (
        var n = 0
        for kind in FrameKind: n += benchState.windowFrames[kind]
        n
      ) else: benchState.totalFrames
      spanNs =
        if windowed: nowNs() - benchState.windowStartedNs
        else: nowNs() - benchState.startedNs
      frameNs = if windowed: benchState.windowFrameNs else: benchState.totalFrameNs
      sorted = sortedHistory()
      avg = ms(frameNs) / max(frames, 1).float64
      label = if benchState.label.len > 0: benchState.label & " " else: ""
    result = "\n[nest bench] " & label &
      &"span={ms(spanNs) / 1000.0:.2f}s frames={frames} " &
      &"avg={avg:.3f}ms " &
      &"p50={ms(percentile(sorted, 0.50)):.3f} " &
      &"p95={ms(percentile(sorted, 0.95)):.3f} " &
      &"p99={ms(percentile(sorted, 0.99)):.3f} " &
      &"max={ms(benchState.maxFrameNs):.3f} " &
      &"busy={100.0 * frameNs.float64 / max(spanNs, 1).float64:.1f}%\n"
    result.add "  frames: " & frameKindSummary(windowed) & "\n"
    result.add zoneTable(windowed, frames)
    result.add counterTable(windowed, frames)
  else:
    discard windowed
    ""

proc toJson*(): string {.raises: [].} =
  ## Return the whole run's instrumentation as a JSON document.
  when NestBench:
    configure()
    proc quoted(value: string): string =
      result = "\""
      for ch in value:
        case ch
        of '"': result.add "\\\""
        of '\\': result.add "\\\\"
        of '\n': result.add "\\n"
        else: result.add ch
      result.add "\""

    let sorted = sortedHistory()
    var zones: seq[string]
    for i in 0 ..< benchState.zoneCount:
      let z = benchState.zones[i]
      if z.calls == 0:
        continue
      zones.add &"{{\"name\":{quoted(z.name)},\"calls\":{z.calls}," &
        &"\"totalMs\":{ms(z.totalNs):.4f},\"selfMs\":{ms(z.selfNs):.4f}," &
        &"\"maxMs\":{ms(z.maxNs):.4f}}}"
    var counters: seq[string]
    for i in 0 ..< benchState.counterCount:
      let c = benchState.counters[i]
      if c.total == 0:
        continue
      counters.add &"{{\"name\":{quoted(c.name)},\"total\":{c.total}}}"
    var kinds: seq[string]
    for kind in FrameKind:
      if benchState.frames[kind] > 0:
        kinds.add &"{quoted($kind)}:{benchState.frames[kind]}"
    result = "{\"label\":" & quoted(benchState.label) &
      &",\"frames\":{benchState.totalFrames}" &
      &",\"spanMs\":{ms(nowNs() - benchState.startedNs):.3f}" &
      &",\"frameMs\":{ms(benchState.totalFrameNs):.3f}" &
      &",\"avgMs\":{ms(benchState.totalFrameNs) / max(benchState.totalFrames, 1).float64:.4f}" &
      &",\"p50Ms\":{ms(percentile(sorted, 0.50)):.4f}" &
      &",\"p95Ms\":{ms(percentile(sorted, 0.95)):.4f}" &
      &",\"p99Ms\":{ms(percentile(sorted, 0.99)):.4f}" &
      &",\"maxMs\":{ms(benchState.maxFrameNs):.4f}" &
      ",\"frameKinds\":{" & kinds.join(",") & "}" &
      ",\"zones\":[" & zones.join(",") & "]" &
      ",\"counters\":[" & counters.join(",") & "]}"
  else:
    "{}"

proc report*(force = false) {.raises: [].} =
  ## Print the rolling report and start a new window.
  ##
  ## Does nothing unless `NEST_BENCH_REPORT_MS` asked for periodic reports, or
  ## `force` is set.
  when NestBench:
    configure()
    if not force and benchState.reportMs <= 0:
      return
    let text = summary(windowed = true)
    benchState.lastReportNs = nowNs()
    resetWindow()
    try:
      stderr.write text
      stderr.flushFile()
    except IOError:
      discard
  else:
    discard force

proc finish*() {.raises: [].} =
  ## Emit the end-of-run report, as configured by the environment.
  ##
  ## Safe to call more than once and safe to call in a build with no
  ## instrumentation, where it does nothing.
  when NestBench:
    configure()
    if benchState.totalFrames == 0 and benchState.zoneCount == 0:
      return
    if benchState.summary:
      try:
        stderr.write summary(windowed = false)
        stderr.flushFile()
      except IOError:
        discard
    if benchState.jsonPath.len > 0:
      try:
        writeFile(benchState.jsonPath, toJson())
      except IOError, OSError:
        discard
    benchState.summary = false
    benchState.jsonPath = ""

proc reset*() {.raises: [].} =
  ## Throw away everything collected so far.
  ##
  ## Benchmarks that run several scenarios in one process use this between
  ## them so each scenario reports only its own frames.
  ##
  ## Zone and counter registrations survive: call sites cache the slot they
  ## were given on first use, so renumbering them here would leave every
  ## instrumented site writing into the wrong statistics.
  when NestBench:
    configure()
    for i in 0 ..< benchState.zoneCount:
      let name = benchState.zones[i].name
      benchState.zones[i] = ZoneStat(name: name)
    for i in 0 ..< benchState.counterCount:
      let name = benchState.counters[i].name
      benchState.counters[i] = CounterStat(name: name)
    benchState.stack.setLen(0)
    for kind in FrameKind:
      benchState.frames[kind] = 0
      benchState.windowFrames[kind] = 0
    benchState.historyLen = 0
    benchState.historyHead = 0
    benchState.frameKind = fkUnknown
    benchState.inFrame = false
    benchState.totalFrames = 0
    benchState.windowFrameNs = 0
    benchState.totalFrameNs = 0
    benchState.maxFrameNs = 0
    benchState.startedNs = nowNs()
    benchState.windowStartedNs = benchState.startedNs
    benchState.lastReportNs = benchState.startedNs

proc setLabel*(label: string) {.raises: [].} =
  ## Name the run, so a report says which scenario produced it.
  when NestBench:
    configure()
    benchState.label = label
  else:
    discard label

proc frameCount*(): int {.raises: [].} =
  ## Return how many frames have been measured.
  when NestBench:
    benchState.totalFrames
  else:
    0

proc averageFrameMs*(): float64 {.raises: [].} =
  ## Return the mean measured frame time in milliseconds.
  when NestBench:
    if benchState.totalFrames == 0:
      0.0
    else:
      ms(benchState.totalFrameNs) / benchState.totalFrames.float64
  else:
    0.0
