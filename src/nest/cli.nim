import std/[cmdline, os, strutils]

import nest/[owldsl, errorDialogs, generator, perf, runner]

proc usage*(): string =
  """Usage:
  nest --project DIR
  nest run DIR [--perf-overlay] [--benchmark [FRAMES]]
  nest dialog DIR [DATA] [RESULT_PATH] [ANCHOR_JSON]
  nest error-dialog [example | MESSAGE]
  nest generate [DIR]

Project files:
  DIR/project.owl  optional project config
  DIR/main.owl     default UI entrypoint
"""

proc parseRunPerfOptions(args: seq[string]; start: int): PerfOptions =
  var i = start
  while i < args.len:
    case args[i]
    of "--perf-overlay":
      result.overlay = true
    of "--benchmark":
      result.benchmarkFrames = 600
      if i + 1 < args.len and not args[i + 1].startsWith("-"):
        try:
          result.benchmarkFrames = max(parseInt(args[i + 1]), 1)
          inc i
        except ValueError:
          quit("invalid benchmark frame count: " & args[i + 1], 1)
    else:
      quit("unknown run option: " & args[i], 1)
    inc i

proc main*() =
  let args = commandLineParams()
  if args.len == 0:
    quit(usage(), 1)
  case args[0]
  of "--project", "-p":
    if args.len < 2:
      quit(usage(), 1)
    discard runProject(args[1], perfOptions = parseRunPerfOptions(args, 2))
  of "run":
    if args.len < 2:
      quit(usage(), 1)
    discard runProject(args[1], perfOptions = parseRunPerfOptions(args, 2))
  of "dialog":
    if args.len < 2:
      quit(usage(), 1)
    let data =
      if args.len >= 3:
        args[2]
      else:
        ""
    let resultPath =
      if args.len >= 4:
        args[3]
      else:
        ""
    let anchor =
      if args.len >= 5:
        args[4]
      else:
        ""
    let value = runProject(
      args[1],
      dialogData = data,
      dialogMode = true,
      dialogResultPath = resultPath,
      dialogAnchor = anchor,
    )
    if resultPath.len > 0:
      writeFile(resultPath, value)
    elif value.len > 0:
      echo value
  of "error-dialog":
    if args.len >= 2 and args[1] != "example":
      runOwlErrorDialog(args[1])
    else:
      runOwlErrorDialog(ErrorDetails(
        message: "missing field: start-label",
        primary: ErrorLocation(path: "main.owl", line: 12, column: 5,
          sourceLine: "label (id \"start-label\")"),
        frames: @[
          ErrorLocation(path: "main.owl", line: 12, column: 5,
            label: "renderStartMenu"),
          ErrorLocation(path: "main.owl", line: 4, column: 1, label: "main"),
        ],
      ))
  of "error-dialog-json":
    if args.len < 2:
      quit(usage(), 1)
    runOwlErrorDialog(errorDetailsFromJson(args[1]))
  of "generate", "gen":
    let dir =
      if args.len >= 2:
        args[1]
      else:
        getCurrentDir()
    generateProject(dir)
  of "--help", "-h", "help":
    echo usage()
  else:
    quit(usage(), 1)
