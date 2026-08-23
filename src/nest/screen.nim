import std/math

import coords

type
  Color* = object
    r*, g*, b*, a*: uint8

  Font* = distinct int
  Image* = distinct int

  TextExtent* = object
    w*, h*: int

  CornerRadii* = object
    topLeft*, topRight*, bottomRight*, bottomLeft*: float64

  FontMetrics* = object
    ascent*, descent*, lineHeight*: int

  ScreenLayout* = object
    width*, height*: int
    pitch*: int
    scaleX*, scaleY*: int
    fullScreen*: bool

  CursorKind* = enum
    curDefault
    curArrow
    curIbeam
    curWait
    curCrosshair
    curHand
    curSizeNS
    curSizeWE

  DrawCommandKind* = enum
    SaveState
    RestoreState
    SetClipRect
    FillRect
    LineRect
    DrawLine
    DrawPoint
    DrawText
    DrawImage

  DrawCommand* = object
    case kind*: DrawCommandKind
    of SaveState, RestoreState:
      discard
    of SetClipRect, FillRect, LineRect:
      rect*: Rect
      color*: Color
    of DrawLine:
      x1*, y1*, x2*, y2*: int
      lineColor*: Color
    of DrawPoint:
      x*, y*: int
      pointColor*: Color
    of DrawText:
      font*: Font
      textX*, textY*: int
      text*: string
      fg*, bg*: Color
    of DrawImage:
      image*: Image
      imagePath*: string
      src*, dst*: Rect

  WindowRelays* = object
    createWindow*: proc(layout: var ScreenLayout) {.nimcall.}
    refresh*: proc() {.nimcall.}
    saveState*: proc() {.nimcall.}
    restoreState*: proc() {.nimcall.}
    setClipRect*: proc(r: Rect) {.nimcall.}
    setCursor*: proc(c: CursorKind) {.nimcall.}
    setWindowTitle*: proc(title: string) {.nimcall.}
    moveWindowBy*: proc(dx, dy: int) {.nimcall.}

  FontRelays* = object
    openFont*: proc(path: string, size: int, metrics: var FontMetrics): Font {.nimcall.}
    closeFont*: proc(f: Font) {.nimcall.}
    getFontMetrics*: proc(f: Font): FontMetrics {.nimcall.}
    measureText*: proc(f: Font, text: string): TextExtent {.nimcall.}
    drawText*:
      proc(f: Font, x, y: int, text: string, fg, bg: Color): TextExtent {.nimcall.}

  DrawRelays* = object
    fillRect*: proc(r: Rect, color: Color) {.nimcall.}
    lineRect*: proc(r: Rect, color: Color) {.nimcall.}
    drawLine*: proc(x1, y1, x2, y2: int, color: Color) {.nimcall.}
    drawPoint*: proc(x, y: int, color: Color) {.nimcall.}
    loadImage*: proc(path: string): Image {.nimcall.}
    freeImage*: proc(img: Image) {.nimcall.}
    drawImage*: proc(img: Image, src, dst: Rect) {.nimcall.}
    drawImageOpacity*: proc(img: Image, src, dst: Rect, opacity: float64) {.nimcall.}
    imageSize*: proc(img: Image): TextExtent {.nimcall.}

proc `==`*(a, b: Font): bool {.borrow.}
  ## Compare two font handles.
proc `==`*(a, b: Image): bool {.borrow.}
  ## Compare two image handles.

var windowRelays* = WindowRelays(
  createWindow: proc(layout: var ScreenLayout) =
    discard,
  refresh: proc() =
    discard,
  saveState: proc() =
    discard,
  restoreState: proc() =
    discard,
  setClipRect: proc(r: Rect) =
    discard,
  setCursor: proc(c: CursorKind) =
    discard,
  setWindowTitle: proc(title: string) =
    discard,
  moveWindowBy: proc(dx, dy: int) =
    discard,
)

var fontRelays* = FontRelays(
  openFont: proc(path: string, size: int, metrics: var FontMetrics): Font =
    Font(0),
  closeFont: proc(f: Font) =
    discard,
  getFontMetrics: proc(f: Font): FontMetrics =
    FontMetrics(),
  measureText: proc(f: Font, text: string): TextExtent =
    TextExtent(),
  drawText: proc(f: Font, x, y: int, text: string, fg, bg: Color): TextExtent =
    TextExtent(),
)

var drawRelays* = DrawRelays(
  fillRect: proc(r: Rect, color: Color) =
    discard,
  lineRect: proc(r: Rect, color: Color) =
    discard,
  drawLine: proc(x1, y1, x2, y2: int, color: Color) =
    discard,
  drawPoint: proc(x, y: int, color: Color) =
    discard,
  loadImage: proc(path: string): Image =
    Image(0),
  freeImage: proc(img: Image) =
    discard,
  drawImage: proc(img: Image, src, dst: Rect) =
    discard,
  drawImageOpacity: proc(img: Image, src, dst: Rect, opacity: float64) =
    discard,
  imageSize: proc(img: Image): TextExtent =
    TextExtent(),
)

var drawCommands*: ptr seq[DrawCommand]
var commandMeasureText*: proc(f: Font, text: string): TextExtent {.nimcall.}
var commandMeasureImage*: proc(path: string): TextExtent {.nimcall.}
var externalPopoversEnabled* = false

proc printableText*(text: string): string =
  ## Return `text` with characters the renderer cannot draw replaced.
  ##
  ## Tabs become spaces and other control characters are dropped, so a
  ## string taken from a file or the clipboard is safe to hand to the font
  ## backend.
  for ch in text:
    case ch
    of '\t':
      result.add "    "
    of '\0' .. '\b', '\l' .. '\r', '\14' .. '\31', '\127':
      result.add ' '
    else:
      result.add ch

proc createWindow*(requestedW, requestedH: int, fullScreen = false): ScreenLayout =
  ## Create the application window at `requestedW` by `requestedH` pixels and
  ## return the layout the backend settled on, which may differ from the
  ## request.
  result = ScreenLayout(width: requestedW, height: requestedH, fullScreen: fullScreen)
  windowRelays.createWindow(result)

proc refresh*() =
  ## Present what has been drawn since the last refresh.
  windowRelays.refresh()

proc saveState*() =
  ## Save the renderer's clip state so it can be restored later.
  ##
  ## Recorded into the active draw-command buffer instead when one is set.
  if drawCommands != nil:
    drawCommands[].add DrawCommand(kind: SaveState)
    return
  windowRelays.saveState()

proc restoreState*() =
  ## Restore the clip state saved by the matching `saveState`.
  ##
  ## Recorded into the active draw-command buffer instead when one is set.
  if drawCommands != nil:
    drawCommands[].add DrawCommand(kind: RestoreState)
    return
  windowRelays.restoreState()

proc setClipRect*(r: Rect) =
  ## Clip further drawing to `r`.
  ##
  ## Recorded into the active draw-command buffer instead when one is set.
  if drawCommands != nil:
    drawCommands[].add DrawCommand(kind: SetClipRect, rect: r)
    return
  windowRelays.setClipRect(r)

proc setCursor*(c: CursorKind) =
  ## Set the mouse cursor shape.
  windowRelays.setCursor(c)

proc setWindowTitle*(title: string) =
  ## Set the window's title.
  windowRelays.setWindowTitle(title)

proc moveWindowBy*(dx, dy: int) =
  ## Moves a normal window or adjusts the position of a layer-shell popup.
  if dx != 0 or dy != 0:
    windowRelays.moveWindowBy(dx, dy)

proc openFont*(path: string, size: int, metrics: var FontMetrics): Font =
  ## Open the font at `path` at `size` and report its `metrics`.
  ##
  ## An empty path, or the name `nerd-monospace`, lets the backend choose a
  ## system font. Returns a null handle when no font could be opened.
  fontRelays.openFont(path, size, metrics)

proc closeFont*(f: Font) =
  ## Release a font handle.
  fontRelays.closeFont(f)

proc getFontMetrics*(f: Font): FontMetrics =
  ## Return the ascent, descent and line height of `f`.
  fontRelays.getFontMetrics(f)

proc fontLineSkip*(f: Font): int =
  ## Return the baseline-to-baseline distance of `f`, in pixels.
  fontRelays.getFontMetrics(f).lineHeight

proc measureText*(f: Font, text: string): TextExtent =
  ## Return the pixel size `text` occupies in font `f`.
  ##
  ## Unprintable characters are normalised first, as they are for drawing.
  let rendered = printableText(text)
  if drawCommands != nil and commandMeasureText != nil:
    return commandMeasureText(f, rendered)
  fontRelays.measureText(f, rendered)

proc drawText*(f: Font, x, y: int, text: string, fg, bg: Color): TextExtent =
  ## Draw `text` in font `f` at `x`, `y` in colour `fg` over background `bg`,
  ## and return the size it occupied.
  ##
  ## The position is the top-left corner of the text. Recorded into the active draw-command buffer instead when one is set, so retained frames can be replayed without touching the backend.
  let rendered = printableText(text)
  if drawCommands != nil:
    result = fontRelays.measureText(f, rendered)
    drawCommands[].add DrawCommand(
      kind: DrawText, font: f, textX: x, textY: y, text: rendered, fg: fg, bg: bg
    )
    return
  fontRelays.drawText(f, x, y, rendered, fg, bg)

proc fillRect*(r: Rect, color: Color) =
  ## Fill `r` with `color`.
  ##
  ## Recorded into the active draw-command buffer instead when one is set, so retained frames can be replayed without touching the backend.
  if drawCommands != nil:
    drawCommands[].add DrawCommand(kind: FillRect, rect: r, color: color)
    return
  drawRelays.fillRect(r, color)

proc drawLine*(x1, y1, x2, y2: int, color: Color)
proc drawPoint*(x, y: int, color: Color)

proc clampRadius(radius: float64, w, h: int): int =
  radius.int.clamp(0, min(w, h) div 2)

proc scaledAlpha(color: Color, coverage: int, samples: int): Color =
  result = color
  result.a = uint8(((color.a.int * coverage + samples div 2) div samples).clamp(0, 255))

proc insideRoundedRect(px, py: float64, w, h: int, radii: CornerRadii): bool =
  if px < 0 or py < 0 or px >= w.float64 or py >= h.float64:
    return false
  let
    fw = w.float64
    fh = h.float64
    tl = clampRadius(radii.topLeft, w, h).float64
    tr = clampRadius(radii.topRight, w, h).float64
    br = clampRadius(radii.bottomRight, w, h).float64
    bl = clampRadius(radii.bottomLeft, w, h).float64

  if tl > 0 and px < tl and py < tl:
    let dx = px - tl
    let dy = py - tl
    return dx * dx + dy * dy <= tl * tl
  if tr > 0 and px >= fw - tr and py < tr:
    let dx = px - (fw - tr)
    let dy = py - tr
    return dx * dx + dy * dy <= tr * tr
  if br > 0 and px >= fw - br and py >= fh - br:
    let dx = px - (fw - br)
    let dy = py - (fh - br)
    return dx * dx + dy * dy <= br * br
  if bl > 0 and px < bl and py >= fh - bl:
    let dx = px - bl
    let dy = py - (fh - bl)
    return dx * dx + dy * dy <= bl * bl
  true

proc roundedCoverage(x, y, w, h: int, radii: CornerRadii): int =
  const SampleGrid = 4
  for sy in 0 ..< SampleGrid:
    for sx in 0 ..< SampleGrid:
      let
        px = x.float64 + (sx.float64 + 0.5) / SampleGrid.float64
        py = y.float64 + (sy.float64 + 0.5) / SampleGrid.float64
      if insideRoundedRect(px, py, w, h, radii):
        inc result

proc roundedStrokeCoverage(x, y, w, h: int, radii: CornerRadii): int =
  const SampleGrid = 4
  let innerRadii = CornerRadii(
    topLeft: max(radii.topLeft - 1.0, 0.0),
    topRight: max(radii.topRight - 1.0, 0.0),
    bottomRight: max(radii.bottomRight - 1.0, 0.0),
    bottomLeft: max(radii.bottomLeft - 1.0, 0.0),
  )
  for sy in 0 ..< SampleGrid:
    for sx in 0 ..< SampleGrid:
      let
        px = x.float64 + (sx.float64 + 0.5) / SampleGrid.float64
        py = y.float64 + (sy.float64 + 0.5) / SampleGrid.float64
      if insideRoundedRect(px, py, w, h, radii) and
          not insideRoundedRect(px - 1.0, py - 1.0, max(w - 2, 0), max(h - 2, 0),
            innerRadii):
        inc result

proc fillCoverageRuns(
    originX, originY, w, h: int,
    coverage: proc(x, y: int): int,
    color: Color,
) =
  const Samples = 16
  for y in 0 ..< h:
    var
      runX = 0
      runCoverage = -1
      hasRun = false
    for x in 0 ..< w:
      let c = coverage(x, y)
      if c == runCoverage:
        if not hasRun:
          runX = x
          hasRun = true
      else:
        if hasRun and runCoverage > 0:
          fillRect(
            rect(originX + runX, originY + y, x - runX, 1),
            color.scaledAlpha(runCoverage, Samples),
          )
        runX = x
        runCoverage = c
        hasRun = true
    if hasRun and runCoverage > 0:
      fillRect(
        rect(originX + runX, originY + y, w - runX, 1),
        color.scaledAlpha(runCoverage, Samples),
      )

proc fillRoundedRect*(r: Rect, radii: CornerRadii, color: Color) =
  ## Fill `r`, rounding each corner independently.
  if r.w <= 0 or r.h <= 0:
    return
  let
    tl = clampRadius(radii.topLeft, r.w, r.h)
    tr = clampRadius(radii.topRight, r.w, r.h)
    br = clampRadius(radii.bottomRight, r.w, r.h)
    bl = clampRadius(radii.bottomLeft, r.w, r.h)
  if tl == 0 and tr == 0 and br == 0 and bl == 0:
    fillRect(r, color)
    return
  fillCoverageRuns(
    r.x,
    r.y,
    r.w,
    r.h,
    proc(x, y: int): int =
      roundedCoverage(x, y, r.w, r.h, radii),
    color,
  )

proc lineRect*(r: Rect, color: Color) =
  ## Stroke the outline of `r` in `color`, skipping empty rectangles.
  ##
  ## Recorded into the active draw-command buffer instead when one is set, so retained frames can be replayed without touching the backend.
  if r.w <= 0 or r.h <= 0:
    return
  if drawCommands != nil:
    drawCommands[].add DrawCommand(kind: LineRect, rect: r, color: color)
    return
  if drawRelays.lineRect != nil:
    drawRelays.lineRect(r, color)
    return
  drawRelays.drawLine(r.x, r.y, r.x + r.w - 1, r.y, color)
  drawRelays.drawLine(r.x, r.y + r.h - 1, r.x + r.w - 1, r.y + r.h - 1, color)
  drawRelays.drawLine(r.x, r.y, r.x, r.y + r.h - 1, color)
  drawRelays.drawLine(r.x + r.w - 1, r.y, r.x + r.w - 1, r.y + r.h - 1, color)

proc lineRoundedRect*(r: Rect, radii: CornerRadii, color: Color) =
  ## Stroke `r`, rounding each corner independently.
  if r.w <= 0 or r.h <= 0:
    return
  let
    tl = clampRadius(radii.topLeft, r.w, r.h)
    tr = clampRadius(radii.topRight, r.w, r.h)
    br = clampRadius(radii.bottomRight, r.w, r.h)
    bl = clampRadius(radii.bottomLeft, r.w, r.h)
  if tl == 0 and tr == 0 and br == 0 and bl == 0:
    lineRect(r, color)
    return
  fillCoverageRuns(
    r.x,
    r.y,
    r.w,
    r.h,
    proc(x, y: int): int =
      roundedStrokeCoverage(x, y, r.w, r.h, radii),
    color,
  )

proc drawLine*(x1, y1, x2, y2: int, color: Color) =
  ## Draw a line from `x1`, `y1` to `x2`, `y2` in `color`.
  ##
  ## Recorded into the active draw-command buffer instead when one is set, so retained frames can be replayed without touching the backend.
  if drawCommands != nil:
    drawCommands[].add DrawCommand(
      kind: DrawLine, x1: x1, y1: y1, x2: x2, y2: y2, lineColor: color
    )
    return
  drawRelays.drawLine(x1, y1, x2, y2, color)

proc drawPoint*(x, y: int, color: Color) =
  ## Draw a single pixel at `x`, `y` in `color`.
  ##
  ## Recorded into the active draw-command buffer instead when one is set, so retained frames can be replayed without touching the backend.
  if drawCommands != nil:
    drawCommands[].add DrawCommand(kind: DrawPoint, x: x, y: y, pointColor: color)
    return
  drawRelays.drawPoint(x, y, color)

proc loadImage*(path: string): Image =
  ## Load the image at `path` and return its handle.
  drawRelays.loadImage(path)

proc freeImage*(img: Image) =
  ## Release an image handle.
  drawRelays.freeImage(img)

proc drawImage*(img: Image, src, dst: Rect) =
  ## Draw the `src` region of `img` into the `dst` rectangle, scaling as
  ## needed.
  ##
  ## Recorded into the active draw-command buffer instead when one is set, so retained frames can be replayed without touching the backend.
  if drawCommands != nil:
    drawCommands[].add DrawCommand(kind: DrawImage, image: img, src: src, dst: dst)
    return
  drawRelays.drawImage(img, src, dst)

proc drawImage*(img: Image, src, dst: Rect, opacity: float64) =
  ## Draw `img` into `dst` with alpha multiplied by `opacity`.
  ##
  ## Recorded command replay uses this to composite animated subtrees.
  if opacity >= 0.999:
    drawImage(img, src, dst)
  elif opacity > 0.0:
    drawRelays.drawImageOpacity(img, src, dst, opacity)

proc imageSize*(img: Image): TextExtent =
  ## Return the pixel size of a loaded image.
  drawRelays.imageSize(img)

proc measureImage*(path: string): TextExtent =
  ## Return the pixel size of the image at `path`, loading it if necessary.
  if drawCommands != nil and commandMeasureImage != nil:
    return commandMeasureImage(path)
  let image = loadImage(path)
  if image.int == 0:
    return TextExtent()
  result = imageSize(image)
  freeImage(image)

proc drawImage*(path: string, src, dst: Rect) =
  ## Draw the `src` region of the image at `path` into the `dst` rectangle.
  ##
  ## The path is resolved when the command is replayed, which lets recorded
  ## frames refer to images that are not loaded yet.
  if drawCommands != nil:
    drawCommands[].add DrawCommand(
      kind: DrawImage, image: Image(0), imagePath: path, src: src, dst: dst
    )
    return
  let image = loadImage(path)
  if image.int == 0:
    return
  drawRelays.drawImage(image, src, dst)
  freeImage(image)

proc scaledColor(color: Color, opacity: float64): Color =
  result = color
  result.a = uint8((color.a.float64 * opacity.min(1.0).max(0.0) + 0.5).int)

proc transformedRect(r: Rect, originX, originY, scale, offsetX, offsetY: float64): Rect =
  let
    x = originX + (r.x.float64 - originX) * scale + offsetX
    y = originY + (r.y.float64 - originY) * scale + offsetY
  rect(x.round.int, y.round.int, max((r.w.float64 * scale).round.int, 0),
      max((r.h.float64 * scale).round.int, 0))

proc transformedCoord(value: int, origin, scale, offset: float64): int =
  (origin + (value.float64 - origin) * scale + offset).round.int

proc replayDrawCommand*(
    command: DrawCommand,
    originX, originY, scale, opacity, offsetX, offsetY: float64,
) =
  ## Replay a recorded draw command with a simple compositing transform.
  ##
  ## Rectangles and images are scaled around `originX`, `originY`; text keeps
  ## its current font size and follows the transformed origin. Alpha is
  ## multiplied into every colour.
  case command.kind
  of SaveState:
    saveState()
  of RestoreState:
    restoreState()
  of SetClipRect:
    setClipRect(command.rect.transformedRect(originX, originY, scale, offsetX,
        offsetY))
  of FillRect:
    fillRect(
      command.rect.transformedRect(originX, originY, scale, offsetX, offsetY),
      command.color.scaledColor(opacity),
    )
  of LineRect:
    lineRect(
      command.rect.transformedRect(originX, originY, scale, offsetX, offsetY),
      command.color.scaledColor(opacity),
    )
  of DrawLine:
    drawLine(
      transformedCoord(command.x1, originX, scale, offsetX),
      transformedCoord(command.y1, originY, scale, offsetY),
      transformedCoord(command.x2, originX, scale, offsetX),
      transformedCoord(command.y2, originY, scale, offsetY),
      command.lineColor.scaledColor(opacity),
    )
  of DrawPoint:
    drawPoint(
      transformedCoord(command.x, originX, scale, offsetX),
      transformedCoord(command.y, originY, scale, offsetY),
      command.pointColor.scaledColor(opacity),
    )
  of DrawText:
    discard drawText(
      command.font,
      transformedCoord(command.textX, originX, scale, offsetX),
      transformedCoord(command.textY, originY, scale, offsetY),
      command.text,
      command.fg.scaledColor(opacity),
      command.bg.scaledColor(opacity),
    )
  of DrawImage:
    let dst = command.dst.transformedRect(originX, originY, scale, offsetX, offsetY)
    if command.imagePath.len > 0:
      let image = loadImage(command.imagePath)
      if image.int != 0:
        drawImage(image, command.src, dst, opacity)
        freeImage(image)
    else:
      drawImage(command.image, command.src, dst, opacity)

proc color*(r, g, b: uint8, a: uint8 = 255): Color =
  ## Construct an opaque `Color`, or a translucent one when `a` is given.
  Color(r: r, g: g, b: b, a: a)
