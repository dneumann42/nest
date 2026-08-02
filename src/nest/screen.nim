import coords

type
  Color* = object
    r*, g*, b*, a*: uint8

  Font* = distinct int
  Image* = distinct int

  TextExtent* = object
    w*, h*: int

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
    imageSize*: proc(img: Image): TextExtent {.nimcall.}

proc `==`*(a, b: Font): bool {.borrow.}
proc `==`*(a, b: Image): bool {.borrow.}

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
  imageSize: proc(img: Image): TextExtent =
    TextExtent(),
)

var drawCommands*: ptr seq[DrawCommand]
var commandMeasureText*: proc(f: Font, text: string): TextExtent {.nimcall.}
var commandMeasureImage*: proc(path: string): TextExtent {.nimcall.}

proc printableText*(text: string): string =
  for ch in text:
    case ch
    of '\t':
      result.add "    "
    of '\0' .. '\b', '\l' .. '\r', '\14' .. '\31', '\127':
      result.add ' '
    else:
      result.add ch

proc createWindow*(requestedW, requestedH: int, fullScreen = false): ScreenLayout =
  result = ScreenLayout(width: requestedW, height: requestedH, fullScreen: fullScreen)
  windowRelays.createWindow(result)

proc refresh*() =
  windowRelays.refresh()

proc saveState*() =
  if drawCommands != nil:
    drawCommands[].add DrawCommand(kind: SaveState)
    return
  windowRelays.saveState()

proc restoreState*() =
  if drawCommands != nil:
    drawCommands[].add DrawCommand(kind: RestoreState)
    return
  windowRelays.restoreState()

proc setClipRect*(r: Rect) =
  if drawCommands != nil:
    drawCommands[].add DrawCommand(kind: SetClipRect, rect: r)
    return
  windowRelays.setClipRect(r)

proc setCursor*(c: CursorKind) =
  windowRelays.setCursor(c)

proc setWindowTitle*(title: string) =
  windowRelays.setWindowTitle(title)

proc openFont*(path: string, size: int, metrics: var FontMetrics): Font =
  fontRelays.openFont(path, size, metrics)

proc closeFont*(f: Font) =
  fontRelays.closeFont(f)

proc getFontMetrics*(f: Font): FontMetrics =
  fontRelays.getFontMetrics(f)

proc fontLineSkip*(f: Font): int =
  fontRelays.getFontMetrics(f).lineHeight

proc measureText*(f: Font, text: string): TextExtent =
  let rendered = printableText(text)
  if drawCommands != nil and commandMeasureText != nil:
    return commandMeasureText(f, rendered)
  fontRelays.measureText(f, rendered)

proc drawText*(f: Font, x, y: int, text: string, fg, bg: Color): TextExtent =
  let rendered = printableText(text)
  if drawCommands != nil:
    result = fontRelays.measureText(f, rendered)
    drawCommands[].add DrawCommand(
      kind: DrawText, font: f, textX: x, textY: y, text: rendered, fg: fg, bg: bg
    )
    return
  fontRelays.drawText(f, x, y, rendered, fg, bg)

proc fillRect*(r: Rect, color: Color) =
  if drawCommands != nil:
    drawCommands[].add DrawCommand(kind: FillRect, rect: r, color: color)
    return
  drawRelays.fillRect(r, color)

proc lineRect*(r: Rect, color: Color) =
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

proc drawLine*(x1, y1, x2, y2: int, color: Color) =
  if drawCommands != nil:
    drawCommands[].add DrawCommand(
      kind: DrawLine, x1: x1, y1: y1, x2: x2, y2: y2, lineColor: color
    )
    return
  drawRelays.drawLine(x1, y1, x2, y2, color)

proc drawPoint*(x, y: int, color: Color) =
  if drawCommands != nil:
    drawCommands[].add DrawCommand(kind: DrawPoint, x: x, y: y, pointColor: color)
    return
  drawRelays.drawPoint(x, y, color)

proc loadImage*(path: string): Image =
  drawRelays.loadImage(path)

proc freeImage*(img: Image) =
  drawRelays.freeImage(img)

proc drawImage*(img: Image, src, dst: Rect) =
  if drawCommands != nil:
    drawCommands[].add DrawCommand(kind: DrawImage, image: img, src: src, dst: dst)
    return
  drawRelays.drawImage(img, src, dst)

proc imageSize*(img: Image): TextExtent =
  drawRelays.imageSize(img)

proc measureImage*(path: string): TextExtent =
  if drawCommands != nil and commandMeasureImage != nil:
    return commandMeasureImage(path)
  let image = loadImage(path)
  if image.int == 0:
    return TextExtent()
  result = imageSize(image)
  freeImage(image)

proc drawImage*(path: string, src, dst: Rect) =
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

proc color*(r, g, b: uint8, a: uint8 = 255): Color =
  Color(r: r, g: g, b: b, a: a)
