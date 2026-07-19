# SDL3 + Wayland layer-shell backend driver.

import sdl3
import sdl3_ttf
import std/[hashes, os, tables]
import uirelays/[coords, input, screen]

{.compile: "wayland/wlr-layer-shell-unstable-v1-protocol.c".}
{.compile: "wayland/xdg-shell-protocol.c".}
{.compile: "wayland/layer_shell_shim.c".}
{.passL: "-lwayland-client".}

# --- Font handle management ---

type
  LayerShellLayer* = enum
    LayerBackground = 0
    LayerBottom = 1
    LayerTop = 2
    LayerOverlay = 3

  LayerShellEdge* = enum
    EdgeTop
    EdgeBottom
    EdgeLeft
    EdgeRight

  LayerShellKeyboardMode* = enum
    KeyboardNone = 0
    KeyboardExclusive = 1
    KeyboardOnDemand = 2

  LayerShellConfig* = object
    namespace*: string
    layer*: LayerShellLayer
    anchors*: set[LayerShellEdge]
    exclusiveZone*: int32
    marginTop*, marginRight*, marginBottom*, marginLeft*: int32
    keyboard*: LayerShellKeyboardMode

  FontSlot = object
    ttfFont: sdl3_ttf.Font
    metrics: FontMetrics

  ImageSlot = object
    texture: sdl3.Texture
    w, h: int

  MeasureCacheKey = object
    fontId: int
    text: string

  TextCacheKey = object
    fontId: int
    fg: screen.Color
    text: string

  TextCacheEntry = object
    texture: sdl3.Texture
    extent: TextExtent
    lastUsed: int

  ClipState = object
    enabled: bool
    rect: sdl3.Rect

var fonts: seq[FontSlot]

const MaxTextCacheEntries = 64

var layerShellConfig* = LayerShellConfig(
  namespace: "nest",
  layer: LayerTop,
  anchors: {EdgeTop, EdgeLeft, EdgeRight},
  exclusiveZone: -1,
  keyboard: KeyboardNone,
)

proc dockTop*(height: Positive, namespace = "nest"): LayerShellConfig =
  LayerShellConfig(
    namespace: namespace,
    layer: LayerTop,
    anchors: {EdgeTop, EdgeLeft, EdgeRight},
    exclusiveZone: height.int32,
    keyboard: KeyboardNone,
  )

proc dockBottom*(height: Positive, namespace = "nest"): LayerShellConfig =
  LayerShellConfig(
    namespace: namespace,
    layer: LayerTop,
    anchors: {EdgeBottom, EdgeLeft, EdgeRight},
    exclusiveZone: height.int32,
    keyboard: KeyboardNone,
  )

proc dockLeft*(width: Positive, namespace = "nest"): LayerShellConfig =
  LayerShellConfig(
    namespace: namespace,
    layer: LayerTop,
    anchors: {EdgeTop, EdgeBottom, EdgeLeft},
    exclusiveZone: width.int32,
    keyboard: KeyboardNone,
  )

proc dockRight*(width: Positive, namespace = "nest"): LayerShellConfig =
  LayerShellConfig(
    namespace: namespace,
    layer: LayerTop,
    anchors: {EdgeTop, EdgeBottom, EdgeRight},
    exclusiveZone: width.int32,
    keyboard: KeyboardNone,
  )

proc anchorMask(config: LayerShellConfig): uint32 =
  if EdgeTop in config.anchors:
    result = result or 1'u32
  if EdgeBottom in config.anchors:
    result = result or 2'u32
  if EdgeLeft in config.anchors:
    result = result or 4'u32
  if EdgeRight in config.anchors:
    result = result or 8'u32

proc layerSurfaceWidth(config: LayerShellConfig, width: int): uint32 =
  if EdgeLeft in config.anchors and EdgeRight in config.anchors:
    0'u32
  else:
    width.uint32

proc layerSurfaceHeight(config: LayerShellConfig, height: int): uint32 =
  if EdgeTop in config.anchors and EdgeBottom in config.anchors:
    0'u32
  else:
    height.uint32

proc nestLayerShellConfigure(
    display, surface: pointer,
    width, height, layer, anchor: uint32,
    exclusiveZone, marginTop, marginRight, marginBottom, marginLeft: int32,
    keyboard: uint32,
    namespace: cstring,
    configuredWidth, configuredHeight: ptr uint32,
): cint {.importc: "nest_wayland_layer_shell_configure".}

proc nestLayerShellDestroy() {.importc: "nest_wayland_layer_shell_destroy".}

proc `==`(a, b: MeasureCacheKey): bool {.inline.} =
  a.fontId == b.fontId and a.text == b.text

proc hash(x: MeasureCacheKey): Hash {.inline.} =
  var h: Hash = 0
  h = h !& hash(x.fontId)
  h = h !& hash(x.text)
  !$h

proc `==`(a, b: TextCacheKey): bool {.inline.} =
  a.fontId == b.fontId and a.fg == b.fg and a.text == b.text

proc hash(x: TextCacheKey): Hash {.inline.} =
  var h: Hash = 0
  h = h !& hash(x.fontId)
  h = h !& hash(x.fg.r)
  h = h !& hash(x.fg.g)
  h = h !& hash(x.fg.b)
  h = h !& hash(x.fg.a)
  h = h !& hash(x.text)
  !$h

proc toColor(c: screen.Color): sdl3.Color {.inline.} =
  sdl3.Color(r: c.r, g: c.g, b: c.b, a: c.a)

proc getFontPtr(f: screen.Font): sdl3_ttf.Font {.inline.} =
  let idx = f.int - 1
  if idx >= 0 and idx < fonts.len: fonts[idx].ttfFont
  else: nil

# --- SDL driver state ---

var
  win: sdl3.Window
  ren: sdl3.Renderer
  images: seq[ImageSlot]
  measureCache: Table[MeasureCacheKey, TextExtent]
  textCache: Table[TextCacheKey, TextCacheEntry]
  textCacheGeneration: int
  cursors: array[CursorKind, sdl3.Cursor]
  currentCursor = curDefault
  drawColorValid: bool
  drawColor: screen.Color
  rendererWidth, rendererHeight: int
  clipStack: seq[ClipState]
  currentClip: ClipState

proc clearMeasureCache() =
  measureCache.clear()

proc clearTextCache() =
  for entry in textCache.values:
    if entry.texture != nil:
      destroyTexture(entry.texture)
  textCache.clear()
  textCacheGeneration = 0

proc clearCursorCache() =
  for cursor in mitems(cursors):
    if cursor != nil:
      destroyCursor(cursor)
      cursor = nil
  currentCursor = curDefault

proc clearImageCache() =
  for slot in mitems(images):
    if slot.texture != nil:
      destroyTexture(slot.texture)
      slot.texture = nil
    slot.w = 0
    slot.h = 0
  images.setLen(0)

proc closeAllFonts() =
  for slot in mitems(fonts):
    if slot.ttfFont != nil:
      sdl3_ttf.closeFont(slot.ttfFont)
      slot.ttfFont = nil
  fonts.setLen(0)

proc resetSdlState() =
  clearImageCache()
  clearTextCache()
  clearMeasureCache()
  clearCursorCache()
  closeAllFonts()
  clipStack.setLen(0)
  currentClip = ClipState()
  drawColorValid = false
  if ren != nil:
    destroyRenderer(ren)
    ren = nil
  if win != nil:
    nestLayerShellDestroy()
    destroyWindow(win)
    win = nil

proc ensureDrawColor(color: screen.Color) =
  if drawColorValid and drawColor == color:
    return
  discard setRenderDrawColor(ren, color.r, color.g, color.b, color.a)
  drawColor = color
  drawColorValid = true

proc applyClipState() =
  if ren == nil:
    return
  if currentClip.enabled:
    discard setRenderClipRect(ren, addr currentClip.rect)
  else:
    discard setRenderClipRect(ren, cast[ptr sdl3.Rect](nil))

proc nextTextCacheGeneration(): int =
  inc textCacheGeneration
  textCacheGeneration

proc evictTextCacheIfNeeded() =
  while textCache.len > MaxTextCacheEntries:
    var oldestKey: TextCacheKey
    var oldestGen = high(int)
    var found = false
    for key, entry in textCache.pairs:
      if entry.lastUsed < oldestGen:
        oldestKey = key
        oldestGen = entry.lastUsed
        found = true
    if not found:
      break
    let entry = textCache[oldestKey]
    if entry.texture != nil:
      destroyTexture(entry.texture)
    textCache.del(oldestKey)

# --- Screen hook implementations ---

proc resolveFontPath(path: string): string =
  if path.len > 0:
    return path

  when defined(windows):
    let candidates = [
      r"C:\Windows\Fonts\segoeui.ttf",
      r"C:\Windows\Fonts\arial.ttf"
    ]
  elif defined(macosx):
    let candidates = [
      "/System/Library/Fonts/SFNS.ttf",
      "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
      "/System/Library/Fonts/Supplemental/Arial.ttf"
    ]
  else:
    let candidates = [
      "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
      "/usr/share/fonts/TTF/DejaVuSans.ttf",
      "/usr/share/fonts/noto/NotoSans-Regular.ttf",
      "/usr/share/fonts/google-noto-vf/NotoSans[wght].ttf",
      "/usr/share/fonts/liberation-sans-fonts/LiberationSans-Regular.ttf",
      "/usr/share/fonts/abattis-cantarell-vf-fonts/Cantarell-VF.otf"
    ]

  for candidate in candidates:
    if fileExists(candidate):
      return candidate

  ""

proc sdlCreateWindow(layout: var ScreenLayout) =
  if ren != nil or win != nil:
    resetSdlState()

  let driver = getCurrentVideoDriver()
  if driver == nil or $driver != "wayland":
    quit("Nest layer-shell apps require SDL's Wayland video driver")

  let props = createProperties()
  if props == 0:
    quit("Could not create SDL window properties for layer-shell window")

  let winFlags = WINDOW_BORDERLESS or WINDOW_TRANSPARENT
  discard setStringProperty(
    props, cstring(PROP_WINDOW_CREATE_TITLE_STRING), cstring"NimEdit")
  discard setNumberProperty(
    props, cstring(PROP_WINDOW_CREATE_WIDTH_NUMBER), layout.width.int64)
  discard setNumberProperty(
    props, cstring(PROP_WINDOW_CREATE_HEIGHT_NUMBER), layout.height.int64)
  discard setNumberProperty(
    props, cstring(PROP_WINDOW_CREATE_FLAGS_NUMBER), winFlags.int64)
  discard setBooleanProperty(
    props, cstring(PROP_WINDOW_CREATE_TRANSPARENT_BOOLEAN), true)
  discard setBooleanProperty(
    props, cstring(PROP_WINDOW_CREATE_WAYLAND_SURFACE_ROLE_CUSTOM_BOOLEAN), true)
  discard setBooleanProperty(
    props, cstring(PROP_WINDOW_CREATE_WAYLAND_CREATE_EGL_WINDOW_BOOLEAN), true)

  win = createWindowWithProperties(props)
  destroyProperties(props)
  if win == nil:
    quit("Could not create SDL layer-shell window")

  let windowProps = getWindowProperties(win)
  let display = getPointerProperty(
    windowProps, cstring(PROP_WINDOW_WAYLAND_DISPLAY_POINTER), nil)
  let surface = getPointerProperty(
    windowProps, cstring(PROP_WINDOW_WAYLAND_SURFACE_POINTER), nil)
  var configuredWidth, configuredHeight: uint32
  let layerResult = nestLayerShellConfigure(
    display,
    surface,
    layerSurfaceWidth(layerShellConfig, layout.width),
    layerSurfaceHeight(layerShellConfig, layout.height),
    layerShellConfig.layer.uint32,
    anchorMask(layerShellConfig),
    layerShellConfig.exclusiveZone,
    layerShellConfig.marginTop,
    layerShellConfig.marginRight,
    layerShellConfig.marginBottom,
    layerShellConfig.marginLeft,
    layerShellConfig.keyboard.uint32,
    cstring(layerShellConfig.namespace),
    addr configuredWidth,
    addr configuredHeight,
  )
  if layerResult != 0:
    quit("Could not configure Wayland layer-shell surface: " & $layerResult)

  if configuredWidth > 0:
    layout.width = configuredWidth.int
  if configuredHeight > 0:
    layout.height = configuredHeight.int
  discard setWindowSize(win, layout.width.cint, layout.height.cint)
  discard showWindow(win)

  ren = createRenderer(win, nil)
  if ren == nil:
    quit("Could not create SDL renderer for layer-shell window")
  discard setRenderDrawBlendMode(ren, BLENDMODE_BLEND)
  discard setRenderDrawColor(ren, 0, 0, 0, 0)
  discard renderClear(ren)
  drawColorValid = false

  discard startTextInput(win)
  var w, h: cint
  discard getWindowSize(win, w, h)
  layout.width = w
  layout.height = h
  rendererWidth = layout.width
  rendererHeight = layout.height
  layout.scaleX = 1
  layout.scaleY = 1
  currentClip = ClipState()
  applyClipState()

proc sdlRefresh() =
  discard renderPresent(ren)

proc sdlSaveState() =
  clipStack.add currentClip

proc sdlRestoreState() =
  if clipStack.len == 0:
    return
  currentClip = clipStack[^1]
  clipStack.setLen(clipStack.len - 1)
  applyClipState()

proc sdlSetClipRect(r: coords.Rect) =
  currentClip = ClipState(
    enabled: true,
    rect: sdl3.Rect(x: r.x.cint, y: r.y.cint, w: r.w.cint, h: r.h.cint))
  applyClipState()

proc sdlOpenFont(path: string; size: int;
                 metrics: var FontMetrics): screen.Font =
  let resolvedPath = resolveFontPath(path)
  if resolvedPath.len == 0:
    return screen.Font(0)
  let f = sdl3_ttf.openFont(cstring(resolvedPath), size.cfloat)
  if f == nil: return screen.Font(0)
  sdl3_ttf.setFontHinting(f, sdl3_ttf.hintingLightSubpixel)
  metrics.ascent = sdl3_ttf.getFontAscent(f)
  metrics.descent = sdl3_ttf.getFontDescent(f)
  metrics.lineHeight = sdl3_ttf.getFontLineSkip(f)
  fonts.add FontSlot(ttfFont: f, metrics: metrics)
  clearMeasureCache()
  clearTextCache()
  result = screen.Font(fonts.len)

proc sdlCloseFont(f: screen.Font) =
  let idx = f.int - 1
  if idx >= 0 and idx < fonts.len and fonts[idx].ttfFont != nil:
    sdl3_ttf.closeFont(fonts[idx].ttfFont)
    fonts[idx].ttfFont = nil
    clearMeasureCache()
    clearTextCache()

proc getCachedExtent(f: screen.Font; text: string): TextExtent =
  let fp = getFontPtr(f)
  if fp == nil or text.len == 0:
    return TextExtent()
  let key = MeasureCacheKey(fontId: f.int, text: text)
  if key in measureCache:
    return measureCache[key]
  var w, h: cint
  discard sdl3_ttf.getStringSize(fp, cstring(text), 0, w, h)
  result = TextExtent(w: w, h: h)
  measureCache[key] = result

proc sdlMeasureText(f: screen.Font; text: string): TextExtent =
  getCachedExtent(f, text)

proc getCachedTextEntry(f: screen.Font; text: string;
                        fg: screen.Color): TextCacheEntry =
  let fp = getFontPtr(f)
  if fp == nil or text.len == 0 or ren == nil:
    return TextCacheEntry()
  let key = TextCacheKey(fontId: f.int, fg: fg, text: text)
  if key in textCache:
    textCache[key].lastUsed = nextTextCacheGeneration()
    return textCache[key]
  let surf = sdl3_ttf.renderTextBlended(fp, cstring(text), 0, toColor(fg))
  if surf == nil:
    return TextCacheEntry()
  let tex = createTextureFromSurface(ren, surf)
  if tex == nil:
    destroySurface(surf)
    return TextCacheEntry()
  discard setTextureBlendMode(tex, BLENDMODE_BLEND)
  let entry = TextCacheEntry(
    texture: tex,
    extent: getCachedExtent(f, text),
    lastUsed: nextTextCacheGeneration())
  destroySurface(surf)
  textCache[key] = entry
  evictTextCacheIfNeeded()
  entry

proc sdlDrawText(f: screen.Font; x, y: int; text: string;
                 fg, bg: screen.Color): TextExtent =
  let entry = getCachedTextEntry(f, text, fg)
  if entry.texture == nil:
    return
  if bg.a != 0 and entry.extent.w > 0 and entry.extent.h > 0:
    var bgRect = FRect(x: x.cfloat, y: y.cfloat,
                       w: entry.extent.w.cfloat, h: entry.extent.h.cfloat)
    ensureDrawColor(bg)
    discard renderFillRect(ren, addr bgRect)
  var src = FRect(x: 0, y: 0, w: entry.extent.w.cfloat,
      h: entry.extent.h.cfloat)
  var dst = FRect(x: x.cfloat, y: y.cfloat,
                  w: entry.extent.w.cfloat, h: entry.extent.h.cfloat)
  discard renderTexture(ren, entry.texture, addr src, addr dst)
  result = entry.extent

proc sdlGetFontMetrics(f: screen.Font): FontMetrics =
  let idx = f.int - 1
  if idx >= 0 and idx < fonts.len: fonts[idx].metrics
  else: screen.FontMetrics()

proc sdlFillRect(r: coords.Rect; color: screen.Color) =
  if color.a == 0 and r.x == 0 and r.y == 0 and r.w >= rendererWidth and
      r.h >= rendererHeight:
    discard setRenderDrawColor(ren, color.r, color.g, color.b, color.a)
    discard renderClear(ren)
    drawColorValid = false
    return
  ensureDrawColor(color)
  var fr = FRect(x: r.x.cfloat, y: r.y.cfloat,
                 w: r.w.cfloat, h: r.h.cfloat)
  discard renderFillRect(ren, addr fr)

proc sdlDrawLine(x1, y1, x2, y2: int; color: screen.Color) =
  ensureDrawColor(color)
  discard renderLine(ren, x1.cfloat, y1.cfloat, x2.cfloat, y2.cfloat)

proc sdlDrawPoint(x, y: int; color: screen.Color) =
  ensureDrawColor(color)
  discard renderPoint(ren, x.cfloat, y.cfloat)

proc getImageSlot(img: screen.Image): ptr ImageSlot {.inline.} =
  let idx = img.int - 1
  if idx >= 0 and idx < images.len:
    addr images[idx]
  else:
    nil

proc sdlLoadImage(path: string): screen.Image =
  ## SDL3 core supports BMP loading without SDL_image.
  if ren == nil:
    return screen.Image(0)
  let surf = loadBMP(cstring(path))
  if surf == nil:
    return screen.Image(0)
  let tex = createTextureFromSurface(ren, surf)
  if tex == nil:
    destroySurface(surf)
    return screen.Image(0)
  discard setTextureBlendMode(tex, BLENDMODE_BLEND)
  images.add ImageSlot(texture: tex, w: surf.w.int, h: surf.h.int)
  destroySurface(surf)
  result = screen.Image(images.len)

proc sdlFreeImage(img: screen.Image) =
  let slot = getImageSlot(img)
  if slot == nil:
    return
  if slot[].texture != nil:
    destroyTexture(slot[].texture)
    slot[].texture = nil
  slot[].w = 0
  slot[].h = 0

proc sdlDrawImage(img: screen.Image; src, dst: coords.Rect) =
  let slot = getImageSlot(img)
  if slot == nil or slot[].texture == nil:
    return
  var srcRect = FRect(
    x: src.x.cfloat, y: src.y.cfloat,
    w: src.w.cfloat, h: src.h.cfloat)
  var dstRect = FRect(
    x: dst.x.cfloat, y: dst.y.cfloat,
    w: dst.w.cfloat, h: dst.h.cfloat)
  discard renderTexture(ren, slot[].texture, addr srcRect, addr dstRect)

proc sdlImageSize(img: screen.Image): TextExtent =
  let slot = getImageSlot(img)
  if slot == nil:
    return TextExtent()
  TextExtent(w: slot[].w, h: slot[].h)

proc sdlSetCursor(c: CursorKind) =
  if cursors[c] == nil:
    let sc = case c
      of curDefault, curArrow: SYSTEM_CURSOR_DEFAULT
      of curIbeam: SYSTEM_CURSOR_TEXT
      of curWait: SYSTEM_CURSOR_WAIT
      of curCrosshair: SYSTEM_CURSOR_CROSSHAIR
      of curHand: SYSTEM_CURSOR_POINTER
      of curSizeNS: SYSTEM_CURSOR_NS_RESIZE
      of curSizeWE: SYSTEM_CURSOR_EW_RESIZE
    cursors[c] = sdl3.createSystemCursor(sc)
  if cursors[c] == nil:
    return
  if c == currentCursor:
    return
  discard sdl3.setCursor(cursors[c])
  currentCursor = c

proc sdlSetWindowTitle(title: string) =
  if win != nil:
    discard setWindowTitle(win, cstring(title))

# --- Input hook implementations ---

proc sdlGetClipboardText(): string =
  let t = sdl3.getClipboardText()
  if t != nil:
    result = $t
    sdlFree(t)
  else:
    result = ""

proc sdlPutClipboardText(text: string) =
  discard setClipboardText(cstring(text))

proc translateScancode(sc: Scancode): input.KeyCode =
  case sc
  of SCANCODE_A: KeyA
  of SCANCODE_B: KeyB
  of SCANCODE_C: KeyC
  of SCANCODE_D: KeyD
  of SCANCODE_E: KeyE
  of SCANCODE_F: KeyF
  of SCANCODE_G: KeyG
  of SCANCODE_H: KeyH
  of SCANCODE_I: KeyI
  of SCANCODE_J: KeyJ
  of SCANCODE_K: KeyK
  of SCANCODE_L: KeyL
  of SCANCODE_M: KeyM
  of SCANCODE_N: KeyN
  of SCANCODE_O: KeyO
  of SCANCODE_P: KeyP
  of SCANCODE_Q: KeyQ
  of SCANCODE_R: KeyR
  of SCANCODE_S: KeyS
  of SCANCODE_T: KeyT
  of SCANCODE_U: KeyU
  of SCANCODE_V: KeyV
  of SCANCODE_W: KeyW
  of SCANCODE_X: KeyX
  of SCANCODE_Y: KeyY
  of SCANCODE_Z: KeyZ
  of SCANCODE_1: Key1
  of SCANCODE_2: Key2
  of SCANCODE_3: Key3
  of SCANCODE_4: Key4
  of SCANCODE_5: Key5
  of SCANCODE_6: Key6
  of SCANCODE_7: Key7
  of SCANCODE_8: Key8
  of SCANCODE_9: Key9
  of SCANCODE_0: Key0
  of SCANCODE_F1: KeyF1
  of SCANCODE_F2: KeyF2
  of SCANCODE_F3: KeyF3
  of SCANCODE_F4: KeyF4
  of SCANCODE_F5: KeyF5
  of SCANCODE_F6: KeyF6
  of SCANCODE_F7: KeyF7
  of SCANCODE_F8: KeyF8
  of SCANCODE_F9: KeyF9
  of SCANCODE_F10: KeyF10
  of SCANCODE_F11: KeyF11
  of SCANCODE_F12: KeyF12
  of SCANCODE_RETURN: KeyEnter
  of SCANCODE_SPACE: KeySpace
  of SCANCODE_ESCAPE: KeyEsc
  of SCANCODE_TAB: KeyTab
  of SCANCODE_BACKSPACE: KeyBackspace
  of SCANCODE_DELETE: KeyDelete
  of SCANCODE_INSERT: KeyInsert
  of SCANCODE_LEFT: KeyLeft
  of SCANCODE_RIGHT: KeyRight
  of SCANCODE_UP: KeyUp
  of SCANCODE_DOWN: KeyDown
  of SCANCODE_PAGEUP: KeyPageUp
  of SCANCODE_PAGEDOWN: KeyPageDown
  of SCANCODE_HOME: KeyHome
  of SCANCODE_END: KeyEnd
  of SCANCODE_CAPSLOCK: KeyCapslock
  of SCANCODE_COMMA: KeyComma
  of SCANCODE_PERIOD: KeyPeriod
  of SCANCODE_SLASH: KeySlash
  of SCANCODE_MINUS: KeyMinus
  of SCANCODE_EQUALS: KeyEqual
  of SCANCODE_KP_MINUS: KeyMinus
  of SCANCODE_KP_PLUS: KeyPlus
  of SCANCODE_KP_EQUALS: KeyEqual
  else: KeyNone

proc translateKeycode(k: sdl3.Keycode): input.KeyCode =
  case k
  of SDLK_MINUS, SDLK_KP_MINUS: KeyMinus
  of SDLK_EQUALS, SDLK_KP_EQUALS: KeyEqual
  of SDLK_PLUS, SDLK_KP_PLUS: KeyPlus
  else: KeyNone

proc translateMods(m: Keymod): set[Modifier] =
  let m = m.uint32
  if (m and KMOD_SHIFT) != 0: result.incl ShiftPressed
  if (m and KMOD_CTRL) != 0: result.incl CtrlPressed
  if (m and KMOD_ALT) != 0: result.incl AltPressed
  if (m and KMOD_GUI) != 0: result.incl GuiPressed

proc translateEvent(sdlEvent: sdl3.Event; e: var input.Event) =
  e = input.Event(kind: NoEvent)
  let evType = uint32(sdlEvent.common.`type`)
  if evType == uint32(EVENT_QUIT):
    e.kind = QuitEvent
  elif evType == uint32(EVENT_WINDOW_RESIZED):
    e.kind = WindowResizeEvent
    e.x = sdlEvent.window.data1
    e.y = sdlEvent.window.data2
    rendererWidth = e.x
    rendererHeight = e.y
  elif evType == uint32(EVENT_WINDOW_CLOSE_REQUESTED):
    e.kind = WindowCloseEvent
  elif evType == uint32(EVENT_WINDOW_FOCUS_GAINED):
    e.kind = WindowFocusGainedEvent
  elif evType == uint32(EVENT_WINDOW_FOCUS_LOST):
    e.kind = WindowFocusLostEvent
  elif evType == uint32(EVENT_KEY_DOWN):
    e.kind = KeyDownEvent
    e.key = translateScancode(sdlEvent.key.scancode)
    if e.key == KeyNone:
      e.key = translateKeycode(sdlEvent.key.key)
    e.mods = translateMods(sdlEvent.key.`mod`)
  elif evType == uint32(EVENT_KEY_UP):
    e.kind = KeyUpEvent
    e.key = translateScancode(sdlEvent.key.scancode)
    if e.key == KeyNone:
      e.key = translateKeycode(sdlEvent.key.key)
    e.mods = translateMods(sdlEvent.key.`mod`)
  elif evType == uint32(EVENT_TEXT_INPUT):
    e.kind = TextInputEvent
    if sdlEvent.text.text != nil:
      for i in 0..3:
        if sdlEvent.text.text[i] == '\0':
          e.text[i] = '\0'
          break
        e.text[i] = sdlEvent.text.text[i]
  elif evType == uint32(EVENT_MOUSE_BUTTON_DOWN):
    e.kind = MouseDownEvent
    e.x = sdlEvent.button.x.int
    e.y = sdlEvent.button.y.int
    e.clicks = sdlEvent.button.clicks.int
    case sdlEvent.button.button
    of BUTTON_LEFT: e.button = LeftButton
    of BUTTON_RIGHT: e.button = RightButton
    of BUTTON_MIDDLE: e.button = MiddleButton
    else: e.button = LeftButton
  elif evType == uint32(EVENT_MOUSE_BUTTON_UP):
    e.kind = MouseUpEvent
    e.x = sdlEvent.button.x.int
    e.y = sdlEvent.button.y.int
    case sdlEvent.button.button
    of BUTTON_LEFT: e.button = LeftButton
    of BUTTON_RIGHT: e.button = RightButton
    of BUTTON_MIDDLE: e.button = MiddleButton
    else: e.button = LeftButton
  elif evType == uint32(EVENT_MOUSE_MOTION):
    e.kind = MouseMoveEvent
    e.x = sdlEvent.motion.x.int
    e.y = sdlEvent.motion.y.int
  elif evType == uint32(EVENT_MOUSE_WHEEL):
    e.kind = MouseWheelEvent
    e.x = sdlEvent.wheel.x.int
    e.y = sdlEvent.wheel.y.int

proc sdlPollEvent(e: var input.Event; flags: set[InputFlag]): bool =
  var sdlEvent: sdl3.Event
  if not pollEvent(sdlEvent):
    return false
  translateEvent(sdlEvent, e)
  result = true

proc sdlWaitEvent(e: var input.Event; timeoutMs: int;
                  flags: set[InputFlag]): bool =
  var sdlEvent: sdl3.Event
  let ok = if timeoutMs < 0: waitEvent(sdlEvent)
           else: waitEventTimeout(sdlEvent, timeoutMs.int32)
  if not ok: return false
  translateEvent(sdlEvent, e)
  result = true

proc sdlGetTicks(): int = sdl3.getTicks().int
proc sdlDelay(ms: int) = sdl3.delay(ms.uint32)
proc wakeEventLoop*() {.gcsafe, raises: [].} =
  var event: sdl3.Event
  event.user.`type` = uint32(EVENT_USER)
  discard pushEvent(event)

proc sdlQuitRequest() =
  if win != nil:
    discard stopTextInput(win)
  resetSdlState()
  sdl3_ttf.quit()
  sdl3.quit()

# --- Init ---

proc selectWaylandVideoDriver() =
  putEnv("SDL_VIDEO_DRIVER", "wayland")
  putEnv("SDL_VIDEODRIVER", "wayland")
  discard setenvUnsafe(cstring"SDL_VIDEO_DRIVER", cstring"wayland", 1)
  discard setenvUnsafe(cstring"SDL_VIDEODRIVER", cstring"wayland", 1)
  discard setHintWithPriority(
    cstring(HINT_VIDEO_DRIVER), cstring"wayland", HINT_OVERRIDE
  )

proc initLayerShellSdl3Driver*() =
  selectWaylandVideoDriver()
  if not sdl3.init(INIT_VIDEO or INIT_EVENTS):
    quit("SDL3 init failed")
  if not sdl3_ttf.init():
    quit("TTF3 init failed")
  windowRelays = WindowRelays(
    createWindow: sdlCreateWindow, refresh: sdlRefresh,
    saveState: sdlSaveState, restoreState: sdlRestoreState,
    setClipRect: sdlSetClipRect, setCursor: sdlSetCursor,
    setWindowTitle: sdlSetWindowTitle)
  fontRelays = FontRelays(
    openFont: sdlOpenFont, closeFont: sdlCloseFont,
    getFontMetrics: sdlGetFontMetrics, measureText: sdlMeasureText,
    drawText: sdlDrawText)
  drawRelays = DrawRelays(
    fillRect: sdlFillRect, drawLine: sdlDrawLine, drawPoint: sdlDrawPoint,
    loadImage: sdlLoadImage, freeImage: sdlFreeImage, drawImage: sdlDrawImage,
    imageSize: sdlImageSize)
  inputRelays = InputRelays(
    pollEvent: sdlPollEvent, waitEvent: sdlWaitEvent,
    getTicks: sdlGetTicks, sleep: sdlDelay,
    shutdown: sdlQuitRequest)
  clipboardRelays = ClipboardRelays(
    getText: sdlGetClipboardText, putText: sdlPutClipboardText)
