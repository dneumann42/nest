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
    fontPaths: TableRef[string, string]
    textMeasurements: TableRef[string, TextMeasurement]
    images: TableRef[string, Image]
    imageMeasurements: TableRef[string, TextExtent]
    imageTimes: TableRef[string, Time]
    imageLastUsed: TableRef[string, int]
    imageGeneration: ref int

const MaxTextMeasurements = 1024
const MaxImages = 32

proc new*(T: typedesc[Resources]): T =
  T(
    fontMetrics: newTable[string, FontMetrics](),
    fontPaths: newTable[string, string](),
    resources: newTable[string, int](),
    textMeasurements: newTable[string, TextMeasurement](),
    images: newTable[string, Image](),
    imageMeasurements: newTable[string, TextExtent](),
    imageTimes: newTable[string, Time](),
    imageLastUsed: newTable[string, int](),
    imageGeneration: new(int),
  )

proc ready*(resources: Resources): bool =
  not resources.resources.isNil

proc loadFont*(resources: Resources, name, path: string, size: Positive) =
  var metrics = FontMetrics()
  let font = openFont(path, size, metrics)
  resources.resources[name] = int(font)
  resources.fontMetrics[name] = metrics
  resources.fontPaths[name] = path
  resources.textMeasurements.clear()

proc fontAtSize*(resources: Resources, name: string, size: int): string =
  ## Return a font resource at `size`, creating it from the named font when needed.
  if size <= 0:
    return name
  let sourceName = if resources.resources.hasKey(name): name else: "font"
  result = sourceName & "@" & $size
  if not resources.resources.hasKey(result):
    resources.loadFont(result, resources.fontPaths[sourceName], Positive(size))

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
  if resources.textMeasurements.len >= MaxTextMeasurements:
    resources.textMeasurements.clear()
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

proc nextImageGeneration(resources: Resources): int =
  inc resources.imageGeneration[]
  resources.imageGeneration[]

proc evictImagesIfNeeded(resources: Resources) =
  while resources.images.len > MaxImages:
    var oldestPath: string
    var oldestGen = high(int)
    var found = false
    for path, image in resources.images.pairs:
      discard image
      let lastUsed = resources.imageLastUsed.getOrDefault(path)
      if lastUsed < oldestGen:
        oldestPath = path
        oldestGen = lastUsed
        found = true
    if not found:
      break
    screen.freeImage(resources.images[oldestPath])
    resources.images.del(oldestPath)
    resources.imageMeasurements.del(oldestPath)
    resources.imageTimes.del(oldestPath)
    resources.imageLastUsed.del(oldestPath)

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
    resources.imageLastUsed[resolvedPath] = resources.nextImageGeneration()
    return resources.images[resolvedPath]
  if resources.images.hasKey(resolvedPath):
    screen.freeImage(resources.images[resolvedPath])
  result = screen.loadImage(resolvedPath)
  if result.int == 0:
    resources.images.del(resolvedPath)
    resources.imageMeasurements.del(resolvedPath)
    resources.imageTimes.del(resolvedPath)
    resources.imageLastUsed.del(resolvedPath)
    return
  resources.images[resolvedPath] = result
  resources.imageMeasurements[resolvedPath] = screen.imageSize(result)
  resources.imageTimes[resolvedPath] = modified
  resources.imageLastUsed[resolvedPath] = resources.nextImageGeneration()
  resources.evictImagesIfNeeded()

proc measureImage*(resources: Resources, path: string): TextExtent =
  let resolvedPath = resolveImagePath(path)
  if resources.imageMeasurements.hasKey(resolvedPath):
    resources.imageLastUsed[resolvedPath] = resources.nextImageGeneration()
    return resources.imageMeasurements[resolvedPath]
  let size = screen.measureImage(resolvedPath)
  if size.w > 0 and size.h > 0:
    resources.imageMeasurements[resolvedPath] = size
  resources.imageMeasurements.getOrDefault(resolvedPath)
