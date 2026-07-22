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

proc loadFont*(resources: Resources, name, path: string, size: Positive) =
  var metrics = FontMetrics()
  let font = openFont(path, size, metrics)
  resources.resources[name] = int(font)
  resources.fontMetrics[name] = metrics
  resources.textMeasurements.clear()

proc get*(
    resources: Resources, name: string
): tuple[resource: int, metrics: FontMetrics] =
  let res = resources.resources[name]
  let met = resources.fontMetrics[name]
  result = (res, met)

proc measureText*(resources: Resources, fontName, text: string): TextMeasurement =
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

proc loadImage*(resources: Resources, path: string): Image =
  if path.len == 0:
    return Image(0)
  let modified =
    try:
      getLastModificationTime(path)
    except OSError:
      Time()
  if resources.images.hasKey(path) and resources.imageTimes.getOrDefault(path) == modified:
    return resources.images[path]
  if resources.images.hasKey(path):
    screen.freeImage(resources.images[path])
  result = screen.loadImage(path)
  resources.images[path] = result
  resources.imageMeasurements[path] = screen.imageSize(result)
  resources.imageTimes[path] = modified

proc measureImage*(resources: Resources, path: string): TextExtent =
  discard resources.loadImage(path)
  resources.imageMeasurements.getOrDefault(path)
