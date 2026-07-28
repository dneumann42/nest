import std/[os, tables, times]
import nest/[coords, screen]
export coords, screen

type
  ResourceID* = string
  Resource* = int
  TextMeasurement* = object
    width*, height*, lineHeight*: int

  Resources* = object
    resources: TableRef[string, int]
    fontMetrics: TableRef[string, FontMetrics]
    textMeasurements: TableRef[string, TextMeasurement]
    images: TableRef[string, Image]
    imageMeasurements: TableRef[string, TextExtent]
    imageTimes: TableRef[string, Time]

proc new*(T: typedesc[Resources]): T =
  T(
    fontMetrics: newTable[string, FontMetrics](),
    resources: newTable[string, int](),
    textMeasurements: newTable[string, TextMeasurement](),
    images: newTable[string, Image](),
    imageMeasurements: newTable[string, TextExtent](),
    imageTimes: newTable[string, Time](),
  )

proc ready*(resources: Resources): bool =
  not resources.resources.isNil

proc loadFont*(resources: Resources, name, path: string, size: Positive) =
  var metrics = FontMetrics()
  let font = openFont(path, size, metrics)
  resources.resources[name] = int(font)
  resources.fontMetrics[name] = metrics
  resources.textMeasurements.clear()

proc get*(
    resources: Resources, name: string
): tuple[resource: int, metrics: FontMetrics] =
  let resolvedName =
    if resources.resources.hasKey(name):
      name
    else:
      "font"
  let res = resources.resources[resolvedName]
  let met = resources.fontMetrics[resolvedName]
  result = (res, met)

proc measureText*(resources: Resources, fontName,
    text: string): TextMeasurement =
  let key = fontName & "\0" & text
  if resources.textMeasurements.hasKey(key):
    return resources.textMeasurements[key]

  let (font, metrics) = resources.get(fontName)
  let extent = screen.measureText(Font(font), text)
  result = TextMeasurement(
    width: extent.w,
    height:
    if extent.h > 0:
        extent.h
      else:
        metrics.lineHeight,
    lineHeight: metrics.lineHeight,
  )
  resources.textMeasurements[key] = result

proc resolveImagePath(path: string): string =
  if path.len == 0:
    return path
  if path.isAbsolute:
    return path.normalizedPath

  for base in [getCurrentDir(), getAppDir()]:
    let candidate = base / path
    if candidate.fileExists:
      return candidate.absolutePath.normalizedPath

  path.absolutePath.normalizedPath

proc loadImage*(resources: Resources, path: string): Image =
  if path.len == 0:
    return Image(0)
  let resolvedPath = resolveImagePath(path)
  let modified =
    try:
      getLastModificationTime(resolvedPath)
    except OSError:
      Time()
  if resources.images.hasKey(resolvedPath) and
      resources.imageTimes.getOrDefault(resolvedPath) == modified:
    return resources.images[resolvedPath]
  if resources.images.hasKey(resolvedPath):
    screen.freeImage(resources.images[resolvedPath])
  result = screen.loadImage(resolvedPath)
  if result.int == 0:
    resources.images.del(resolvedPath)
    resources.imageMeasurements.del(resolvedPath)
    resources.imageTimes.del(resolvedPath)
    return
  resources.images[resolvedPath] = result
  resources.imageMeasurements[resolvedPath] = screen.imageSize(result)
  resources.imageTimes[resolvedPath] = modified

proc measureImage*(resources: Resources, path: string): TextExtent =
  let resolvedPath = resolveImagePath(path)
  if resources.imageMeasurements.hasKey(resolvedPath):
    return resources.imageMeasurements[resolvedPath]
  let size = screen.measureImage(resolvedPath)
  if size.w > 0 and size.h > 0:
    resources.imageMeasurements[resolvedPath] = size
  resources.imageMeasurements.getOrDefault(resolvedPath)
