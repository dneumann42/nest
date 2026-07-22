import std/[os, strutils]

import crow/[parser, syntax]
import nest/[appConfig, layerShellSdl3Driver]

type ProjectConfig* = object
  main*: string
  title*: string
  width*, height*: int
  layerShell*: string
  namespace*: string
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

proc valueString(node: SyntaxNode): tuple[ok: bool, value: string] =
  case node.kind
  of String:
    (true, node.stringValue)
  of Symbol:
    (true, node.symbol)
  of Command:
    if node.arguments.len == 0 and node.layout == NoLayout and
        node.callee.kind == Symbol:
      (true, node.callee.symbol)
    else:
      (false, "")
  else:
    (false, "")

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

  for node in program.statements:
    if node.kind != Binding:
      continue
    let parsed = node.value.valueString
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
  case config.layerShell.normalize
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

proc projectMainPath*(projectDir: string, config: ProjectConfig): string =
  if config.main.isAbsolute:
    config.main.normalizedPath
  else:
    (projectDir / config.main).normalizedPath
