import std/[json, math]

import nest/[appConfig, layerShellSdl3Driver]

type DialogAnchor* = object
  ok*: bool
  x*, y*, width*, height*: float64
  windowWidth*, windowHeight*: int

proc numberField(node: JsonNode; name: string): float64 =
  if node.kind == JObject and node.hasKey(name):
    let field = node[name]
    if field.kind == JInt:
      return field.getInt.float64
    if field.kind == JFloat:
      return field.getFloat
  0.0

proc intField(node: JsonNode; name: string): int =
  numberField(node, name).int

proc parseDialogAnchor*(value: string): DialogAnchor =
  if value.len == 0:
    return
  try:
    let node = parseJson(value)
    result = DialogAnchor(
      ok: node.kind == JObject,
      x: numberField(node, "x"),
      y: numberField(node, "y"),
      width: numberField(node, "width"),
      height: numberField(node, "height"),
      windowWidth: intField(node, "windowWidth"),
      windowHeight: intField(node, "windowHeight"),
    )
    result.ok = result.ok and result.windowWidth > 0 and result.windowHeight > 0
  except JsonParsingError:
    result = DialogAnchor()
  except KeyError:
    result = DialogAnchor()

proc edgeDistance(value: float64): int32 =
  max(value.int, 0).int32

proc clampDistance(value, size, limit: float64): float64 =
  value.clamp(0.0, max(limit - size, 0.0))

proc applyDialogAnchor*(app: AppConfig; anchor: DialogAnchor): AppConfig =
  result = app
  if not anchor.ok:
    return

  let
    centerX = anchor.x + anchor.width / 2.0
    centerY = anchor.y + anchor.height / 2.0
    leftZone = centerX < anchor.windowWidth.float64 / 3.0
    rightZone = centerX > anchor.windowWidth.float64 * 2.0 / 3.0
    topZone = centerY <= anchor.windowHeight.float64 / 2.0
    desiredLeft =
      if leftZone:
        anchor.x
      elif rightZone:
        anchor.x + anchor.width - app.width.float64
      else:
        centerX - app.width.float64 / 2.0
    popupLeft = clampDistance(desiredLeft, app.width.float64,
        anchor.windowWidth.float64)

  result.layerShell = true
  result.layerShellConfig.layer = LayerOverlay
  result.layerShellConfig.exclusiveZone = 0
  result.layerShellConfig.marginTop = 0
  result.layerShellConfig.marginRight = 0
  result.layerShellConfig.marginBottom = 0
  result.layerShellConfig.marginLeft = 0
  result.layerShellConfig.anchors = {}

  if topZone:
    result.layerShellConfig.anchors.incl EdgeTop
    result.layerShellConfig.marginTop = edgeDistance(anchor.y)
  else:
    result.layerShellConfig.anchors.incl EdgeBottom
    result.layerShellConfig.marginBottom =
      edgeDistance(anchor.windowHeight.float64 - anchor.y)

  if leftZone:
    result.layerShellConfig.anchors.incl EdgeLeft
    result.layerShellConfig.marginLeft = edgeDistance(popupLeft)
  elif rightZone:
    result.layerShellConfig.anchors.incl EdgeRight
    result.layerShellConfig.marginRight =
      edgeDistance(anchor.windowWidth.float64 - popupLeft - app.width.float64)
  else:
    result.layerShellConfig.anchors.incl EdgeLeft
    result.layerShellConfig.marginLeft = edgeDistance(popupLeft)
