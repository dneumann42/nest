## Native Wayland facilities for headless and multi-surface Nest clients.
##
## Unlike Nest's SDL application backend, this API does not create a desktop
## window or run an application loop. The caller owns dispatch and can create
## one layer-shell overlay per output. Captures stay on the Wayland/EGL side of
## the API so uploading a frame never round-trips through Nim-managed memory.

import std/options
import nest/wayland/protocols

{.compile: "wayland/generated/ext-foreign-toplevel-list-v1-protocol.c".}
{.compile: "wayland/generated/ext-image-capture-source-v1-protocol.c".}
{.compile: "wayland/generated/ext-image-copy-capture-v1-protocol.c".}
{.compile: "wayland/generated/fractional-scale-v1-protocol.c".}
{.compile: "wayland/generated/viewporter-protocol.c".}
{.compile: "wayland/headless_shim.c".}
{.passL: "-lwayland-client -lwayland-egl -lEGL -lGLESv2".}

type
  WaylandError* = object of CatchableError

  OutputId* = distinct uint32
  ToplevelId* = distinct uint32
  OverlayId* = distinct uint32
  CaptureId* = distinct uint32

  WaylandEventKind* = enum
    weNone = 0
    weOutputAdded
    weOutputRemoved
    weToplevelChanged
    weToplevelClosed
    weOverlayConfigured
    weFrame
    wePointerEnter
    wePointerLeave
    wePointerMotion
    wePointerButton
    weCaptureReady
    weCaptureFailed

  WaylandEvent* = object
    kind*: WaylandEventKind
    objectId*: uint32
    serial*, time*, detail*, state*: uint32
    x*, y*: float64

  WaylandOutput* = object
    id*: OutputId
    name*: string
    x*, y*, width*, height*: int
    scale*: int

  ForeignToplevel* = object
    id*: ToplevelId
    identifier*, title*, appId*: string
    closed*: bool

  CaptureInfo* = object
    width*, height*, format*, generation*: uint32
    ready*: bool

  CWaylandEvent {.bycopy.} = object
    kind, objectId, serial, time, detail, state: uint32
    x, y: float64

  COutputInfo {.bycopy.} = object
    id: uint32
    x, y, width, height, scale: int32
    name: array[128, char]

  CToplevelInfo {.bycopy.} = object
    id, closed: uint32
    identifier: array[40, char]
    title, appId: array[256, char]

  CCaptureInfo {.bycopy.} = object
    width, height, format, generation, ready: uint32

  WaylandClient* {.requiresInit.} = object
    handle: pointer

proc cConnect(name: cstring): pointer {.importc: "nest_wl_connect".}
proc cDisconnect(client: pointer) {.importc: "nest_wl_disconnect".}
proc cDispatch(client: pointer, timeoutMs: cint): cint {.importc: "nest_wl_dispatch".}
proc cFlush(client: pointer): cint {.importc: "nest_wl_flush".}
proc cNextEvent(client: pointer, event: ptr CWaylandEvent): cint {.importc: "nest_wl_next_event".}
proc cLastError(client: pointer): cstring {.importc: "nest_wl_last_error".}
proc cOutputCount(client: pointer): uint32 {.importc: "nest_wl_output_count".}
proc cOutputInfo(client: pointer, index: uint32, info: ptr COutputInfo): cint {.importc: "nest_wl_output_info".}
proc cToplevelCount(client: pointer): uint32 {.importc: "nest_wl_toplevel_count".}
proc cToplevelInfo(client: pointer, index: uint32, info: ptr CToplevelInfo): cint {.importc: "nest_wl_toplevel_info".}
proc cCreateOverlay(client: pointer, output: uint32, name: cstring): uint32 {.importc: "nest_wl_create_overlay".}
proc cDestroyOverlay(client: pointer, overlay: uint32) {.importc: "nest_wl_destroy_overlay".}
proc cOverlayPointer(client: pointer, overlay: uint32, enabled: cint) {.importc: "nest_wl_overlay_set_pointer".}
proc cOverlayFrame(client: pointer, overlay: uint32) {.importc: "nest_wl_overlay_request_frame".}
proc cOverlayBegin(client: pointer, overlay: uint32): cint {.importc: "nest_wl_overlay_begin".}
proc cOverlayDraw(client: pointer, overlay, capture: uint32,
                  x, y, width, height, opacity: cfloat) {.importc: "nest_wl_overlay_draw".}
proc cOverlayEnd(client: pointer, overlay: uint32) {.importc: "nest_wl_overlay_end".}
proc cCreateCapture(client: pointer, top: uint32): uint32 {.importc: "nest_wl_create_capture".}
proc cDestroyCapture(client: pointer, capture: uint32) {.importc: "nest_wl_destroy_capture".}
proc cCaptureFrame(client: pointer, capture: uint32): cint {.importc: "nest_wl_capture_frame".}
proc cCaptureInfo(client: pointer, capture: uint32, info: ptr CCaptureInfo): cint {.importc: "nest_wl_capture_info".}

proc `=copy`(dest: var WaylandClient; source: WaylandClient) {.error.}
proc `=destroy`(client: WaylandClient) =
  if client.handle != nil:
    cDisconnect(client.handle)

proc connectWayland*(displayName = ""): WaylandClient =
  ## Connect and bind Nest's supported globals. An empty name uses
  ## `WAYLAND_DISPLAY` in the usual libwayland manner.
  result = WaylandClient(handle: cConnect(
    if displayName.len == 0: nil else: displayName.cstring))
  if result.handle == nil:
    raise newException(WaylandError, "could not connect to the Wayland display")
  let message = $cLastError(result.handle)
  if message.len > 0:
    raise newException(WaylandError, message)

proc close*(client: var WaylandClient) =
  ## Close all child protocol objects and disconnect.
  if client.handle != nil:
    cDisconnect(client.handle)
    client.handle = nil

proc dispatch*(client: var WaylandClient; timeoutMs = -1) =
  ## Read and dispatch Wayland events, waiting at most `timeoutMs`.
  if cDispatch(client.handle, timeoutMs.cint) < 0:
    raise newException(WaylandError, "Wayland dispatch failed")

proc flush*(client: WaylandClient) =
  ## Flush queued protocol requests without waiting for a reply.
  discard cFlush(client.handle)

proc pollEvent*(client: WaylandClient): Option[WaylandEvent] =
  ## Return the next translated event without blocking.
  var event: CWaylandEvent
  if cNextEvent(client.handle, addr event) == 0:
    return none(WaylandEvent)
  some(WaylandEvent(kind: WaylandEventKind(event.kind),
    objectId: event.objectId, serial: event.serial, time: event.time,
    detail: event.detail, state: event.state, x: event.x, y: event.y))

proc outputs*(client: WaylandClient): seq[WaylandOutput] =
  ## Return the current output registry snapshot in compositor coordinates.
  for index in 0'u32 ..< cOutputCount(client.handle):
    var info: COutputInfo
    if cOutputInfo(client.handle, index, addr info) != 0:
      result.add WaylandOutput(id: OutputId(info.id),
        name: $cast[cstring](addr info.name[0]), x: info.x, y: info.y,
        width: info.width, height: info.height, scale: max(1, info.scale))

proc toplevels*(client: WaylandClient): seq[ForeignToplevel] =
  ## Return the live and recently closed foreign-toplevel handles.
  for index in 0'u32 ..< cToplevelCount(client.handle):
    var info: CToplevelInfo
    if cToplevelInfo(client.handle, index, addr info) != 0:
      result.add ForeignToplevel(id: ToplevelId(info.id),
        identifier: $cast[cstring](addr info.identifier[0]),
        title: $cast[cstring](addr info.title[0]),
        appId: $cast[cstring](addr info.appId[0]), closed: info.closed != 0)

proc createOverlay*(client: var WaylandClient; output: OutputId;
                    namespace = "nest"): OverlayId =
  ## Create a fullscreen, transparent overlay-layer surface on `output`.
  ## It reserves no space, accepts no keyboard focus, and initially has an
  ## empty pointer input region.
  result = OverlayId(cCreateOverlay(client.handle, output.uint32, namespace))
  if result.uint32 == 0:
    raise newException(WaylandError, "could not create layer-shell overlay")

proc destroyOverlay*(client: var WaylandClient; overlay: OverlayId) =
  cDestroyOverlay(client.handle, overlay.uint32)

proc setPointerInput*(client: WaylandClient; overlay: OverlayId; enabled: bool) =
  ## Toggle the overlay between an empty and fullscreen input region.
  cOverlayPointer(client.handle, overlay.uint32, enabled.cint)

proc requestFrame*(client: WaylandClient; overlay: OverlayId) =
  ## Request one `wl_surface.frame` notification. Duplicate requests coalesce.
  cOverlayFrame(client.handle, overlay.uint32)

proc beginFrame*(client: WaylandClient; overlay: OverlayId): bool =
  ## Make the overlay current and clear it to transparent.
  cOverlayBegin(client.handle, overlay.uint32) != 0

proc drawCapture*(client: WaylandClient; overlay: OverlayId; capture: CaptureId;
                  x, y, width, height: float32; opacity = 1'f32) =
  ## Draw a captured toplevel texture in logical output coordinates.
  cOverlayDraw(client.handle, overlay.uint32, capture.uint32,
    x, y, width, height, opacity)

proc endFrame*(client: WaylandClient; overlay: OverlayId) =
  ## Present the current transparent overlay image through EGL.
  cOverlayEnd(client.handle, overlay.uint32)

proc createCapture*(client: var WaylandClient; top: ToplevelId): CaptureId =
  ## Create a persistent image-copy session for a foreign toplevel.
  result = CaptureId(cCreateCapture(client.handle, top.uint32))
  if result.uint32 == 0:
    raise newException(WaylandError, "could not create toplevel capture")

proc destroyCapture*(client: var WaylandClient; capture: CaptureId) =
  cDestroyCapture(client.handle, capture.uint32)

proc captureFrame*(client: WaylandClient; capture: CaptureId): bool =
  ## Request a single asynchronous frame. Completion is reported as an event.
  cCaptureFrame(client.handle, capture.uint32) != 0

proc captureInfo*(client: WaylandClient; capture: CaptureId): CaptureInfo =
  var info: CCaptureInfo
  if cCaptureInfo(client.handle, capture.uint32, addr info) == 0:
    raise newException(WaylandError, "unknown capture")
  CaptureInfo(width: info.width, height: info.height, format: info.format,
    generation: info.generation, ready: info.ready != 0)
