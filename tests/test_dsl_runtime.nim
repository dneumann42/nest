import std/[os, streams, unittest]

import nest/[layouts, ui]
import nest_dsl/[nodes, reader, runtime]

proc parseDsl(source: string): Program =
  let stream = newStringStream(source)
  defer: stream.close()
  let read = readProgram(stream)
  doAssert read.ok, $read.error
  Program(read.node)

proc parseDslFile(path: string): Program =
  let stream = newFileStream(path)
  require stream != nil
  defer: stream.close()
  let read = readProgram(stream)
  require read.ok
  Program(read.node)

suite "DSL runtime":
  test "define binds once":
    let program = parseDsl("define:\n  buttonID (id)\n")
    var ui = UI.init()
    let runtime = DslRuntime.init()
    let defines = Block(lines: @[program.body.lines[0]])

    runtime.renderBlock(ui, defines)
    let first = runtime.widgetID("buttonID")
    runtime.renderBlock(ui, defines)

    check first != InvalidWidgetID
    check runtime.widgetID("buttonID") == first

  test "call keyword assignments evaluate":
    let program = parseDsl("define:\n  width (prefer 800: min = 400)\n")
    var ui = UI.init()
    let runtime = DslRuntime.init()

    runtime.renderBlock(ui, Block(lines: @[program.body.lines[0]]))

    let width = runtime.get("width")
    check width.kind == Size
    check width.sizePolicyValue.kind == Prefer
    check width.sizePolicyValue.value == 800
    check width.sizePolicyValue.min == 400

  test "command defines a script command with scoped arguments":
    let program = parseDsl(
      "command addPath input:\n" &
        "  capture input\n" &
        "addPath \"from-dsl\"\n",
    )
    var ui = UI.init()
    let runtime = DslRuntime.init()
    var captured = ""
    runtime.registerCommand(
      "capture",
      proc(runtime: DslRuntime, ui: var UI, args: seq[DslValue], body: Block): DslValue =
        if args.len > 0:
          captured = $args[0]
        nilValue(),
    )

    runtime.renderBlock(ui, program.body)

    check captured == "from-dsl"
    check runtime.get("input").kind == None

  test "list and file utilities mutate and persist lines":
    let output = "/tmp/nest-dsl-runtime-lines.txt"
    removeFile(output)
    let program = parseDsl(
      "define:\n" &
        "  output \"" & output & "\"\n" &
        "  paths (split \"alpha:gamma\" \":\")\n" &
      "appendLine paths \"delta\"\n" &
      "insertLine paths 1 \"beta\"\n" &
      "writeLines output paths\n" &
      "define:\n" &
        "  loaded (loadLines output)\n",
    )
    var ui = UI.init()
    let runtime = DslRuntime.init()

    runtime.renderBlock(ui, program.body)

    check runtime.get("paths").kind == List
    check runtime.get("paths").listValue.items == @["alpha", "beta", "gamma", "delta"]
    check runtime.get("loaded").kind == List
    check runtime.get("loaded").listValue.items == @["alpha", "beta", "gamma", "delta"]
    check readFile(output) == "alpha\nbeta\ngamma\ndelta"
    removeFile(output)

  test "exec runs asynchronously and captures stdout":
    let program = parseDsl("exec \"printf dsl-runtime\"\n")
    var ui = UI.init()
    let runtime = DslRuntime.init()

    runtime.renderBlock(ui, program.body)
    for _ in 0 ..< 50:
      runtime.pollExec()
      if runtime.exec.isNil or not runtime.exec.running:
        break
      sleep(20)

    check not runtime.exec.isNil
    check not runtime.exec.running
    check runtime.exec.output == "dsl-runtime"

  test "path editor DSL files parse":
    check parseDslFile("docs/dsl").body.lines.len > 0
    check parseDslFile("src/example/pathEditor.nest").body.lines.len > 0
