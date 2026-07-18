import std/[os, strutils, tables, times]

import crow
import ui

type
  WidgetIDValue* = ref object of NativeValue
    value*: WidgetID

  SizePolicyValue* = ref object of NativeValue
    value*: SizePolicy

  AlignmentValue* = ref object of NativeValue
    value*: Alignment

  JustificationValue* = ref object of NativeValue
    value*: Justification

  NestCrowRuntime* = ref object
    evaluator*: Evaluator
    loadedFiles*: Table[string, Time]
    moduleStack: seq[string]
    currentUi: ptr UI
    hasError*: bool
    lastError*: string

  NestCrowApp* = ref object
    rootPath*: string
    runtime*: NestCrowRuntime
    program*: SyntaxNode
    lastError*: string

proc init*(T: typedesc[NestCrowRuntime]): T
proc renderNodes(runtime: NestCrowRuntime; nodes: seq[SyntaxNode]): Value

proc widgetValue(id: WidgetID): Value =
  nativeValue(WidgetIDValue(value: id))

proc sizeValue(policy: SizePolicy): Value =
  nativeValue(SizePolicyValue(value: policy))

proc alignValue(alignment: Alignment): Value =
  nativeValue(AlignmentValue(value: alignment))

proc justifyValue(justification: Justification): Value =
  nativeValue(JustificationValue(value: justification))

proc requireUi(runtime: NestCrowRuntime): var UI {.raises: [EvaluatorError].} =
  if runtime.currentUi.isNil:
    raise newException(EvaluatorError, "Nest UI is not rendering")
  runtime.currentUi[]

proc asString(value: Value): string =
  case value.kind
  of Text:
    value.text
  of Number:
    if value.number == value.number.int.float:
      $value.number.int
    else:
      $value.number
  of Boolean:
    if value.boolean: "true" else: "false"
  of Native:
    if value.native of WidgetIDValue:
      $WidgetIDValue(value.native).value
    else:
      $value
  else:
    $value

proc asNumber(value: Value; fallback = 0.0): float64 =
  case value.kind
  of Number:
    value.number
  of Text:
    try:
      parseFloat(value.text)
    except ValueError:
      fallback
  else:
    fallback

proc asWidgetID(runtime: NestCrowRuntime; value: Value): WidgetID =
  if value.kind == Native and value.native of WidgetIDValue:
    WidgetIDValue(value.native).value
  else:
    runtime.requireUi().id(value.asString)

proc asSizePolicy(value: Value; fallback: SizePolicy): SizePolicy =
  if value.kind == Native and value.native of SizePolicyValue:
    SizePolicyValue(value.native).value
  else:
    fallback

proc asAlignment(value: Value; fallback: Alignment): Alignment =
  if value.kind == Native and value.native of AlignmentValue:
    AlignmentValue(value.native).value
  else:
    fallback

proc asJustification(value: Value; fallback: Justification): Justification =
  if value.kind == Native and value.native of JustificationValue:
    JustificationValue(value.native).value
  else:
    fallback

proc evalArg(env: Environment; node: SyntaxNode): Value {.raises: [EvaluatorError].} =
  env.eval(node)

proc evalArgs(env: Environment; nodes: seq[SyntaxNode]): seq[Value] {.raises: [EvaluatorError].} =
  for node in nodes:
    result.add env.evalArg(node)

proc evalConfig(env: Environment; body: seq[SyntaxNode]): BoxConfig {.raises: [EvaluatorError].} =
  result = cfg()
  for node in body:
    if node.kind != Binding:
      continue
    let value = env.eval(node.value)
    case node.bindingSymbol
    of "width":
      result.width = value.asSizePolicy(result.width)
    of "height":
      result.height = value.asSizePolicy(result.height)
    of "gap":
      result.gap = value.asNumber(result.gap)
    of "padding":
      result.padding = value.asNumber(result.padding)
    of "alignItems":
      result.alignItems = value.asAlignment(result.alignItems)
    of "justifyContent":
      result.justifyContent = value.asJustification(result.justifyContent)
    of "alignSelf":
      result.alignSelf = value.asAlignment(result.alignSelf)
    of "scrollX":
      result.scrollX = value.isTruthy
    of "scrollY":
      result.scrollY = value.isTruthy
    else:
      discard

proc childNodes(nodes: seq[SyntaxNode]): seq[SyntaxNode] =
  for node in nodes:
    if node.kind != Binding:
      result.add node

proc currentDir(runtime: NestCrowRuntime): string =
  if runtime.moduleStack.len > 0:
    runtime.moduleStack[^1].parentDir
  else:
    getCurrentDir()

proc resolveModulePath(runtime: NestCrowRuntime; path: string): string =
  if path.isAbsolute:
    path.normalizedPath
  else:
    (runtime.currentDir / path).normalizedPath

proc rememberFile(runtime: NestCrowRuntime; path: string) =
  try:
    runtime.loadedFiles[path] = getLastModificationTime(path)
  except OSError:
    discard

proc loadSyntaxFile*(runtime: NestCrowRuntime; path: string): SyntaxNode {.raises: [EvaluatorError].} =
  var resolved = path
  try:
    resolved = runtime.resolveModulePath(path)
    result = parse(readFile(resolved))
    runtime.rememberFile(resolved)
  except IOError as error:
    raise newException(EvaluatorError, resolved & ": " & error.msg)
  except OSError as error:
    raise newException(EvaluatorError, resolved & ": " & error.msg)
  except ParserError as error:
    raise newException(EvaluatorError, resolved & ": " & error.msg)

proc renderNodes(runtime: NestCrowRuntime; nodes: seq[SyntaxNode]): Value =
  result = nothing()
  for node in nodes:
    if runtime.hasError:
      return
    try:
      result = runtime.evaluator.env.eval(node)
    except EvaluatorError as error:
      runtime.hasError = true
      runtime.lastError = error.msg
      return nothing()

proc registerNestCommands(runtime: NestCrowRuntime) =
  runtime.evaluator.native "define":
    discard layout
    discard arguments
    result = nothing()
    for node in bodyNodes:
      if node.kind != Binding:
        raise newException(EvaluatorError, "define body entries must be bindings")
      if not env.contains(node.bindingSymbol):
        result = env.eval(node.value)
        env.define(node.bindingSymbol, result)

  runtime.evaluator.native "id":
    discard layout
    discard bodyNodes
    if arguments.len == 0:
      return widgetValue(nextWidgetID())
    var parts: seq[string]
    for value in env.evalArgs(arguments):
      parts.add value.asString
    widgetValue(runtime.requireUi().id(parts))

  runtime.evaluator.native "clicked":
    discard layout
    discard bodyNodes
    if arguments.len == 0:
      return boolean(false)
    boolean(
      runtime.requireUi().inEventPhase() and
        runtime.requireUi().clicked(runtime.asWidgetID(env.eval(arguments[0])))
    )

  runtime.evaluator.native "fill":
    discard env
    discard arguments
    discard layout
    discard bodyNodes
    sizeValue(fill())

  runtime.evaluator.native "fit":
    discard env
    discard arguments
    discard layout
    discard bodyNodes
    sizeValue(fit())

  runtime.evaluator.native "fixed":
    discard layout
    discard bodyNodes
    if arguments.len != 1:
      raise newException(EvaluatorError, "fixed expects one size")
    sizeValue(fixed(env.eval(arguments[0]).asNumber))

  runtime.evaluator.native "hug":
    discard layout
    discard bodyNodes
    if arguments.len != 1:
      raise newException(EvaluatorError, "hug expects one size")
    sizeValue(hug(env.eval(arguments[0]).asNumber))

  runtime.evaluator.native "prefer":
    discard layout
    discard bodyNodes
    if arguments.len != 1:
      raise newException(EvaluatorError, "prefer expects one size")
    sizeValue(prefer(env.eval(arguments[0]).asNumber))

  runtime.evaluator.native "clock":
    discard layout
    discard bodyNodes
    let pattern =
      if arguments.len > 0:
        env.eval(arguments[0]).asString
      else:
        "HH:mm"
    text(now().format(pattern))

  runtime.evaluator.native "import":
    discard layout
    discard bodyNodes
    if arguments.len != 1:
      raise newException(EvaluatorError, "import expects one path")
    let path = env.eval(arguments[0]).asString
    var resolved = path
    try:
      resolved = runtime.resolveModulePath(path)
    except OSError as error:
      raise newException(EvaluatorError, path & ": " & error.msg)
    if resolved in runtime.moduleStack:
      return nothing()
    let node = runtime.loadSyntaxFile(resolved)
    runtime.moduleStack.add resolved
    try:
      result = runtime.renderNodes(node.statements)
    finally:
      runtime.moduleStack.setLen(runtime.moduleStack.len - 1)

  runtime.evaluator.native "events":
    discard env
    discard arguments
    discard layout
    if runtime.requireUi().inEventPhase():
      runtime.renderNodes(bodyNodes)
    else:
      nothing()

  runtime.evaluator.native "scope":
    discard layout
    if arguments.len == 0:
      return runtime.renderNodes(bodyNodes)
    let key = env.eval(arguments[0]).asString
    runtime.currentUi[].scope(key):
      result = runtime.renderNodes(bodyNodes)

  runtime.evaluator.native "panel":
    discard layout
    let values = env.evalArgs(arguments)
    let id =
      if values.len > 0: runtime.asWidgetID(values[0]) else: nextWidgetID()
    let config = env.evalConfig(bodyNodes)
    runtime.currentUi[].panel(id, config):
      discard runtime.renderNodes(bodyNodes.childNodes)
    nothing()

  runtime.evaluator.native "row":
    discard layout
    let values = env.evalArgs(arguments)
    let id =
      if values.len > 0: runtime.asWidgetID(values[0]) else: nextWidgetID()
    let config = env.evalConfig(bodyNodes)
    runtime.currentUi[].row(id, config):
      discard runtime.renderNodes(bodyNodes.childNodes)
    nothing()

  runtime.evaluator.native "column":
    discard layout
    let values = env.evalArgs(arguments)
    let id =
      if values.len > 0: runtime.asWidgetID(values[0]) else: nextWidgetID()
    let config = env.evalConfig(bodyNodes)
    runtime.currentUi[].column(id, config):
      discard runtime.renderNodes(bodyNodes.childNodes)
    nothing()

  runtime.evaluator.native "spacer":
    discard layout
    let values = env.evalArgs(arguments)
    let id =
      if values.len > 0: runtime.asWidgetID(values[0]) else: nextWidgetID()
    let config = env.evalConfig(bodyNodes)
    discard runtime.currentUi[].spacer(id, config.width, config.height, config.alignSelf)
    nothing()

  runtime.evaluator.native "label":
    discard layout
    let values = env.evalArgs(arguments)
    let id =
      if values.len > 0: runtime.asWidgetID(values[0]) else: nextWidgetID()
    let labelText =
      if values.len > 1:
        values[1].asString
      else:
        ""
    let config = env.evalConfig(bodyNodes)
    runtime.currentUi[].label(id, labelText, config.width, config.height, alignSelf = config.alignSelf)
    nothing()

  runtime.evaluator.native "button":
    discard layout
    let values = env.evalArgs(arguments)
    let id =
      if values.len > 0: runtime.asWidgetID(values[0]) else: nextWidgetID()
    let labelText =
      if values.len > 1:
        values[1].asString
      else:
        ""
    let config = env.evalConfig(bodyNodes)
    boolean(runtime.currentUi[].button(id, labelText, config.width, config.height, config.alignSelf))

  runtime.evaluator.env.define("AlignAuto", alignValue(AlignAuto))
  runtime.evaluator.env.define("AlignStart", alignValue(AlignStart))
  runtime.evaluator.env.define("AlignCenter", alignValue(AlignCenter))
  runtime.evaluator.env.define("AlignEnd", alignValue(AlignEnd))
  runtime.evaluator.env.define("AlignStretch", alignValue(AlignStretch))
  runtime.evaluator.env.define("JustifyStart", justifyValue(JustifyStart))
  runtime.evaluator.env.define("JustifyCenter", justifyValue(JustifyCenter))
  runtime.evaluator.env.define("JustifyEnd", justifyValue(JustifyEnd))

proc init*(T: typedesc[NestCrowRuntime]): T =
  result = T(evaluator: Evaluator.init())
  result.registerNestCommands()

proc get*(runtime: NestCrowRuntime; name: string): Value {.raises: [EvaluatorError].} =
  runtime.evaluator.env.get(name)

proc widgetID*(runtime: NestCrowRuntime; name: string): WidgetID {.raises: [EvaluatorError].} =
  runtime.asWidgetID(runtime.get(name))

proc dependenciesChanged*(runtime: NestCrowRuntime): bool =
  for path, lastTime in runtime.loadedFiles:
    try:
      if getLastModificationTime(path) != lastTime:
        return true
    except OSError:
      return true

proc reload*(app: NestCrowApp): bool {.discardable.} =
  app.runtime = NestCrowRuntime.init()
  app.runtime.loadedFiles.clear()
  try:
    app.program = app.runtime.loadSyntaxFile(app.rootPath)
    app.lastError = ""
    true
  except EvaluatorError as error:
    app.program = nil
    app.lastError = error.msg
    false

proc init*(T: typedesc[NestCrowApp]; rootPath: string): T =
  result = T(rootPath: rootPath.normalizedPath, runtime: NestCrowRuntime.init())
  discard result.reload()

proc render*(runtime: NestCrowRuntime; ui: var UI; program: SyntaxNode) =
  if program.isNil:
    return
  runtime.hasError = false
  runtime.lastError = ""
  runtime.currentUi = addr ui
  try:
    ui.layout:
      discard runtime.renderNodes(program.statements)
  finally:
    runtime.currentUi = nil

proc renderLayoutOnly*(
    runtime: NestCrowRuntime; ui: var UI; program: SyntaxNode; width, height: int
) =
  if program.isNil:
    return
  runtime.hasError = false
  runtime.lastError = ""
  runtime.currentUi = addr ui
  try:
    ui.beginLayout(width, height)
    discard runtime.renderNodes(program.statements)
    ui.applyIntrinsicSizes(ui.resources)
    discard ui.endLayout()
  finally:
    runtime.currentUi = nil

proc render*(app: NestCrowApp; ui: var UI) =
  if app.isNil:
    return
  if app.program.isNil or app.runtime.dependenciesChanged():
    discard app.reload()
  if app.program.isNil:
    return
  app.runtime.moduleStack.add app.rootPath
  app.runtime.render(ui, app.program)
  app.runtime.moduleStack.setLen(app.runtime.moduleStack.len - 1)
  if app.runtime.hasError:
    app.lastError = app.runtime.lastError
