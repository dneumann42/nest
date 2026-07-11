import std/[os, streams]

import ../nest
import ../nest_dsl/[nodes, reader, runtime]

type
  PathEditor* = object
    dsl: DslRuntime
    program: Program

proc init*(T: typedesc[PathEditor]): T =
  T(dsl: DslRuntime.init())

proc findDslFile(): string =
  const candidates = [
    "src/example/pathEditor.nest",
    "pathEditor.nest",
  ]
  for candidate in candidates:
    if fileExists(candidate):
      return candidate
  getAppDir() / "pathEditor.nest"

proc loadProgram(path: string): Program =
  let stream = newFileStream(path)
  if stream.isNil:
    raise newException(IOError, "could not open DSL file: " & path)
  defer: stream.close()

  let read = readProgram(stream)
  if not read.ok:
    raise newException(ValueError, "could not read DSL file: " & $read.error)
  Program(read.node)

proc start() =
  var ui = UI.init()
  var app = PathEditor.init()
  app.program = loadProgram(findDslFile())

  application AppConfig.init(width = 640, height = 480, title = "Path Editor"), ui:
    app.dsl.render(ui, app.program)

when isMainModule:
  start()
