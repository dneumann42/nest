import std/[cmdline, os]

import nest/[errorDialogs, generator, runner]

proc usage*(): string =
  """Usage:
  nest --project DIR
  nest run DIR
  nest dialog DIR [DATA] [RESULT_PATH] [ANCHOR_JSON]
  nest error-dialog MESSAGE
  nest generate [DIR]

Project files:
  DIR/project.nest  optional project config
  DIR/main.nest     default UI entrypoint
"""

proc main*() =
  let args = commandLineParams()
  if args.len == 0:
    quit(usage(), 1)
  case args[0]
  of "--project", "-p":
    if args.len < 2:
      quit(usage(), 1)
    discard runProject(args[1])
  of "run":
    if args.len < 2:
      quit(usage(), 1)
    discard runProject(args[1])
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
    if args.len < 2:
      quit(usage(), 1)
    runCrowErrorDialog(args[1])
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
