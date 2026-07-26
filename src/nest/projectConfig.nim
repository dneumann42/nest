import std/[os, strutils, tables]

import crow/[parser, syntax]
import nest/[appConfig, layerShellSdl3Driver]

type ProjectConfig* = object
  main*: string
  title*: string
  width*, height*: int
  layerShell*: string
  namespace*: string
  theme*: string
  exclusiveZone*: int
  marginTop*, marginRight*, marginBottom*, marginLeft*: int

proc defaultProjectConfig*(): ProjectConfig =
  ProjectConfig(
    main: "main.nest",
    title: "Nest",
    width: 800,
    height: 600,
    layerShell: "none",
    namespace: "nest",
    theme: "",
    exclusiveZone: low(int),
    marginTop: 0,
    marginRight: 0,
    marginBottom: 0,
    marginLeft: 0,
  )

proc parseProjectInt(value: string, fallback: int): int =
  try:
    parseInt(value.strip)
  except ValueError:
    fallback

type ProjectVariables = Table[string, string]

proc valueString(
    node: SyntaxNode; variables: ProjectVariables = initTable[string, string]()
): tuple[ok: bool, value: string] =
  case node.kind
  of String:
    (true, node.stringValue)
  of Symbol:
    (true, variables.getOrDefault(node.symbol, node.symbol))
  of Command:
    if node.arguments.len == 0 and node.layout == NoLayout and
        node.callee.kind == Symbol:
      (true, variables.getOrDefault(node.callee.symbol, node.callee.symbol))
    else:
      (false, "")
  else:
    (false, "")

proc commandName(node: SyntaxNode): string =
  if node.kind == Command and node.callee.kind == Symbol:
    node.callee.symbol.normalize
  else:
    ""

proc collectProjectVariables(
    path: string; variables: var ProjectVariables; seen: var seq[string]
)

proc collectImportedProjectVariables(
    baseDir: string; node: SyntaxNode; variables: var ProjectVariables; seen: var seq[string]
) =
  if node.commandName != "import" or node.arguments.len != 1:
    return
  let imported = node.arguments[0].valueString(variables)
  if not imported.ok:
    return
  let importPath =
    if imported.value.isAbsolute:
      imported.value.normalizedPath
    else:
      (baseDir / imported.value).normalizedPath
  collectProjectVariables(importPath, variables, seen)

proc collectDefinedProjectVariables(node: SyntaxNode; variables: var ProjectVariables) =
  if node.commandName != "define":
    return
  for entry in node.body:
    if entry.kind != Binding or variables.hasKey(entry.bindingSymbol):
      continue
    let parsed = entry.value.valueString(variables)
    if parsed.ok:
      variables[entry.bindingSymbol] = parsed.value

proc collectProjectVariables(
    path: string; variables: var ProjectVariables; seen: var seq[string]
) =
  let normalized = path.normalizedPath
  if normalized in seen or not fileExists(normalized):
    return
  seen.add normalized

  var program: SyntaxNode
  try:
    program = parse(readFile(normalized), normalized)
  except CatchableError:
    return

  let baseDir = normalized.parentDir
  for node in program.statements:
    collectImportedProjectVariables(baseDir, node, variables, seen)
  for node in program.statements:
    node.collectDefinedProjectVariables(variables)

proc loadProjectConfig*(projectDir: string): ProjectConfig =
  result = defaultProjectConfig()
  let configPath = projectDir / "project.nest"
  if not fileExists(configPath):
    return

  var program: SyntaxNode
  try:
    program = parse(readFile(configPath), configPath)
  except CatchableError:
    return

  var
    variables = initTable[string, string]()
    seen: seq[string] = @[]
  for node in program.statements:
    collectImportedProjectVariables(projectDir, node, variables, seen)
  for node in program.statements:
    node.collectDefinedProjectVariables(variables)

  for node in program.statements:
    if node.kind != Binding:
      continue
    let parsed = node.value.valueString(variables)
    if not parsed.ok:
      continue

    case node.bindingSymbol.normalize
    of "main":
      result.main = parsed.value
    of "title":
      result.title = parsed.value
    of "width":
      result.width = parseProjectInt(parsed.value, result.width)
    of "height":
      result.height = parseProjectInt(parsed.value, result.height)
    of "layershell", "layer":
      result.layerShell = parsed.value.normalize
    of "namespace":
      result.namespace = parsed.value
    of "theme":
      result.theme = parsed.value.normalize
    of "exclusivezone":
      result.exclusiveZone = parseProjectInt(parsed.value, result.exclusiveZone)
    of "margintop":
      result.marginTop = parseProjectInt(parsed.value, result.marginTop)
    of "marginright":
      result.marginRight = parseProjectInt(parsed.value, result.marginRight)
    of "marginbottom":
      result.marginBottom = parseProjectInt(parsed.value, result.marginBottom)
    of "marginleft":
      result.marginLeft = parseProjectInt(parsed.value, result.marginLeft)
    else:
      discard

proc positive(value: int): Positive =
  max(value, 1).Positive

proc withLayerShellMargins(app: AppConfig; config: ProjectConfig): AppConfig =
  result = app
  if config.exclusiveZone != low(int):
    result.layerShellConfig.exclusiveZone = config.exclusiveZone.int32
  result.layerShellConfig.marginTop = config.marginTop.int32
  result.layerShellConfig.marginRight = config.marginRight.int32
  result.layerShellConfig.marginBottom = config.marginBottom.int32
  result.layerShellConfig.marginLeft = config.marginLeft.int32

proc anchoredAppConfig(config: ProjectConfig; anchors: set[LayerShellEdge]): AppConfig =
  AppConfig
    .init(
      width = positive(config.width),
      height = positive(config.height),
      title = config.title,
    )
    .layerShell(
      LayerShellConfig(
        namespace: config.namespace,
        layer: LayerTop,
        anchors: anchors,
        exclusiveZone: config.exclusiveZone.int32,
        marginTop: config.marginTop.int32,
        marginRight: config.marginRight.int32,
        marginBottom: config.marginBottom.int32,
        marginLeft: config.marginLeft.int32,
        keyboard: KeyboardOnDemand,
      )
    )

proc appConfig*(config: ProjectConfig): AppConfig =
  result = case config.layerShell.normalize
  of "top":
    AppConfig.dockTop(positive(config.height), config.title,
        config.namespace).withLayerShellMargins(config)
  of "bottom":
    AppConfig.dockBottom(positive(config.height), config.title,
        config.namespace).withLayerShellMargins(config)
  of "left":
    AppConfig.dockLeft(positive(config.width), config.title,
        config.namespace).withLayerShellMargins(config)
  of "right":
    AppConfig.dockRight(positive(config.width), config.title,
        config.namespace).withLayerShellMargins(config)
  of "top-left", "topleft":
    config.anchoredAppConfig({EdgeTop, EdgeLeft})
  of "top-right", "topright":
    config.anchoredAppConfig({EdgeTop, EdgeRight})
  of "top-center", "top-middle", "topcenter", "topmiddle":
    config.anchoredAppConfig({EdgeTop})
  else:
    AppConfig.init(
      width = max(config.width, 1),
      height = max(config.height, 1),
      title = config.title,
    )
  result.themeName = config.theme

proc projectMainPath*(projectDir: string, config: ProjectConfig): string =
  if config.main.isAbsolute:
    config.main.normalizedPath
  else:
    (projectDir / config.main).normalizedPath
