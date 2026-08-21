import std/[hashes, math, sets]
import sdl3

import ../[coords, resources, widgets2]
import component
import nest/screen

type
  Mesh2DPoint* = object
    x*, y*: float64

  Mesh2DEdge* = object
    a*, b*: int

  Mesh2DDragKind* = enum
    Mesh2DNoDrag, Mesh2DPointDrag, Mesh2DEdgeDrag, Mesh2DIslandDrag

  Mesh2DState* = object
    points*: seq[Mesh2DPoint]
    triangles*: seq[array[3, int]]
    selectedPoints*: HashSet[int]
    selectedEdges*: HashSet[Mesh2DEdge]
    dragKind*: Mesh2DDragKind
    dragPoint*: int
    dragEdge*: Mesh2DEdge
    lastMouseX*, lastMouseY*: int
    changed*: bool
    ## Optional Alt-drag controls. A zero snap step disables snapping.
    altDragSensitivity*: float64
    altDragSnapStep*: float64
    viewZoom*: float64
    viewCenterX*, viewCenterY*: float64
    panning*: bool
    lastPanMouseX*, lastPanMouseY*: int

  Mesh2DEditor* = ref object of Interactive
    state: ptr Mesh2DState
    imagePath: string

const
  PointPickRadius = 14.0
  EdgePickRadius = 7.0
  HandleRadius = 5.0

proc hash*(edge: Mesh2DEdge): Hash =
  ## Hash an edge independently of the order of its endpoints.
  hash((min(edge.a, edge.b), max(edge.a, edge.b)))

proc `==`*(a, b: Mesh2DEdge): bool =
  ## Compare two edges, treating an edge and its reverse as equal.
  (a.a == b.a and a.b == b.b) or (a.a == b.b and a.b == b.a)

proc new*(T: typedesc[Mesh2DEditor], state: var Mesh2DState,
    imagePath = ""): T =
  ## Create a mesh editor that edits `state` over the image at `imagePath`.
  ##
  ## The editor keeps a reference to `state`, so the caller owns it across
  ## frames. A zoom of zero or less is initialised to a centred default view.
  if state.viewZoom <= 0:
    state.viewZoom = 1
    state.viewCenterX = 0.5
    state.viewCenterY = 0.5
  T(state: addr state, imagePath: imagePath)

method measure*(self: Mesh2DEditor, resources: Resources): IntrinsicSize =
  ## Return the editor's default size; the mesh itself imposes none.
  discard self
  discard resources
  intrinsicSize(240, 240)

proc contains(f: Frame, x, y: int): bool =
  x.float64 >= f.x and x.float64 < f.x + f.width and y.float64 >= f.y and
    y.float64 < f.y + f.height

proc viewRect(widget: Widget): Frame =
  let f = widget.frame
  let size = min(f.width, f.height)
  Frame(
    x: f.x + (f.width - size) * 0.5,
    y: f.y + (f.height - size) * 0.5,
    width: size,
    height: size,
  )

proc viewScale(state: Mesh2DState, view: Frame): float64 =
  view.width * max(state.viewZoom, 0.25)

proc toScreen(point: Mesh2DPoint, state: Mesh2DState,
    view: Frame): tuple[x, y: float64] =
  let scale = state.viewScale(view)
  (
    view.x + view.width * 0.5 + (point.x - state.viewCenterX) * scale,
    view.y + view.height * 0.5 + (point.y - state.viewCenterY) * scale,
  )

proc fromDelta(dx, dy: float64, state: Mesh2DState, view: Frame): Mesh2DPoint =
  let scale = max(state.viewScale(view), 0.000001)
  Mesh2DPoint(x: dx / scale, y: dy / scale)

proc pointAt(x, y: int, state: Mesh2DState, view: Frame): Mesh2DPoint =
  let scale = max(state.viewScale(view), 0.000001)
  Mesh2DPoint(
    x: state.viewCenterX + (x.float64 - view.x - view.width * 0.5) / scale,
    y: state.viewCenterY + (y.float64 - view.y - view.height * 0.5) / scale,
  )

proc add(point: var Mesh2DPoint, delta: Mesh2DPoint) =
  point.x += delta.x
  point.y += delta.y

proc altModifierDown(): bool =
  if (getModState().uint32 and KMOD_ALT) != 0:
    return true
  var keyCount: cint
  let keyboard = getKeyboardState(keyCount)
  not keyboard.isNil and keyCount > SCANCODE_RALT.int and
    (keyboard[SCANCODE_LALT.int] or keyboard[SCANCODE_RALT.int])

proc snap(point: var Mesh2DPoint, step: float64) =
  if step <= 0:
    return
  point.x = round(point.x / step) * step
  point.y = round(point.y / step) * step

proc movePoint(point: var Mesh2DPoint, delta: Mesh2DPoint, snapStep: float64) =
  point.add delta
  point.snap(snapStep)

proc distancePoint(px, py, ax, ay: float64): float64 =
  hypot(px - ax, py - ay)

proc distanceSegment(px, py, ax, ay, bx, by: float64): float64 =
  let
    vx = bx - ax
    vy = by - ay
    lenSq = vx * vx + vy * vy
  if lenSq <= 0.000001:
    return distancePoint(px, py, ax, ay)
  let t = clamp(((px - ax) * vx + (py - ay) * vy) / lenSq, 0.0, 1.0)
  distancePoint(px, py, ax + vx * t, ay + vy * t)

proc pointInTriangle(px, py, ax, ay, bx, by, cx, cy: float64): bool =
  let
    d1 = (px - bx) * (ay - by) - (ax - bx) * (py - by)
    d2 = (px - cx) * (by - cy) - (bx - cx) * (py - cy)
    d3 = (px - ax) * (cy - ay) - (cx - ax) * (py - ay)
    hasNeg = d1 < 0 or d2 < 0 or d3 < 0
    hasPos = d1 > 0 or d2 > 0 or d3 > 0
  not (hasNeg and hasPos)

proc pickPoint(state: Mesh2DState, view: Frame, x, y: int): int =
  result = -1
  var best = PointPickRadius
  for i, point in state.points:
    let screenPoint = point.toScreen(state, view)
    let distance = distancePoint(x.float64, y.float64, screenPoint.x,
        screenPoint.y)
    if distance < best:
      best = distance
      result = i

proc pickEdge(state: Mesh2DState, view: Frame, x, y: int): Mesh2DEdge =
  result = Mesh2DEdge(a: -1, b: -1)
  var best = EdgePickRadius
  for triangle in state.triangles:
    for edge in [Mesh2DEdge(a: triangle[0], b: triangle[1]),
                 Mesh2DEdge(a: triangle[1], b: triangle[2]),
                 Mesh2DEdge(a: triangle[2], b: triangle[0])]:
      if edge.a < 0 or edge.b < 0 or edge.a >= state.points.len or
          edge.b >= state.points.len:
        continue
      let
        a = state.points[edge.a].toScreen(state, view)
        b = state.points[edge.b].toScreen(state, view)
        distance = distanceSegment(x.float64, y.float64, a.x, a.y, b.x, b.y)
      if distance < best:
        best = distance
        result = edge

proc pickIsland(state: Mesh2DState, view: Frame, x, y: int): bool =
  for triangle in state.triangles:
    if triangle[0] < 0 or triangle[1] < 0 or triangle[2] < 0 or
        triangle[0] >= state.points.len or triangle[1] >= state.points.len or
        triangle[2] >= state.points.len:
      continue
    let
      a = state.points[triangle[0]].toScreen(state, view)
      b = state.points[triangle[1]].toScreen(state, view)
      c = state.points[triangle[2]].toScreen(state, view)
    if pointInTriangle(x.float64, y.float64, a.x, a.y, b.x, b.y, c.x, c.y):
      return true

proc beginDrag(state: var Mesh2DState, view: Frame, x, y: int) =
  state.dragPoint = state.pickPoint(view, x, y)
  if state.dragPoint >= 0:
    if state.dragPoint in state.selectedPoints and state.selectedPoints.len > 1:
      state.dragKind = Mesh2DIslandDrag
    else:
      state.selectedPoints.clear()
      state.selectedEdges.clear()
      state.dragKind = Mesh2DPointDrag
      state.selectedPoints.incl state.dragPoint
  else:
    state.selectedPoints.clear()
    state.selectedEdges.clear()
    let edge = state.pickEdge(view, x, y)
    if edge.a >= 0:
      state.dragKind = Mesh2DEdgeDrag
      state.dragEdge = edge
      state.selectedEdges.incl edge
      state.selectedPoints.incl edge.a
      state.selectedPoints.incl edge.b
    elif state.pickIsland(view, x, y):
      state.dragKind = Mesh2DIslandDrag
      for i in 0 ..< state.points.len:
        state.selectedPoints.incl i
    else:
      state.dragKind = Mesh2DNoDrag
  state.lastMouseX = x
  state.lastMouseY = y

proc drag(state: var Mesh2DState, view: Frame, x, y: int) =
  if state.dragKind == Mesh2DNoDrag:
    return
  var delta = fromDelta((x - state.lastMouseX).float64,
      (y - state.lastMouseY).float64, state, view)
  let altDown = altModifierDown()
  if altDown and state.altDragSensitivity > 0:
    delta.x *= state.altDragSensitivity
    delta.y *= state.altDragSensitivity
  let snapStep = if altDown: state.altDragSnapStep else: 0.0

  case state.dragKind
  of Mesh2DPointDrag:
    if state.dragPoint >= 0 and state.dragPoint < state.points.len:
      state.points[state.dragPoint].movePoint(delta, snapStep)
      state.changed = true
  of Mesh2DEdgeDrag, Mesh2DIslandDrag:
    for index in state.selectedPoints:
      if index >= 0 and index < state.points.len:
        state.points[index].movePoint(delta, snapStep)
        state.changed = true
  of Mesh2DNoDrag:
    discard
  state.lastMouseX = x
  state.lastMouseY = y

method update*(self: Mesh2DEditor, widget: Widget, ctx: var UpdateContext) =
  ## Handle this frame's input: pick, select and drag points, edges and
  ## islands, pan and zoom the view, and set `state.changed` when the mesh
  ## was edited.
  ##
  ## Holding Alt drags at `altDragSensitivity`, snapped to
  ## `altDragSnapStep` when that is non-zero. Does nothing without state.
  if self.state == nil:
    return
  let
    f = widget.frame
    view = widget.viewRect()
    hot = f.contains(ctx.mouseX, ctx.mouseY)
  if hot:
    ctx.setHot(widget.id)
  if hot and ctx.mouseWheelY != 0:
    let anchor = pointAt(ctx.mouseX, ctx.mouseY, self.state[], view)
    self.state[].viewZoom = clamp(
      self.state[].viewZoom * pow(1.2, ctx.mouseWheelY), 0.25, 32.0
    )
    let scale = self.state[].viewScale(view)
    self.state[].viewCenterX = anchor.x -
      (ctx.mouseX.float64 - view.x - view.width * 0.5) / scale
    self.state[].viewCenterY = anchor.y -
      (ctx.mouseY.float64 - view.y - view.height * 0.5) / scale
    ctx.markDirty(widget.id)
  if hot and ctx.mouseMiddlePressed:
    self.state[].panning = true
    self.state[].lastPanMouseX = ctx.mouseX
    self.state[].lastPanMouseY = ctx.mouseY
    ctx.setActive(widget.id)
  if self.state[].panning and ctx.mouseMiddleDown:
    let scale = max(self.state[].viewScale(view), 0.000001)
    self.state[].viewCenterX -=
      (ctx.mouseX - self.state[].lastPanMouseX).float64 / scale
    self.state[].viewCenterY -=
      (ctx.mouseY - self.state[].lastPanMouseY).float64 / scale
    self.state[].lastPanMouseX = ctx.mouseX
    self.state[].lastPanMouseY = ctx.mouseY
    ctx.setActive(widget.id)
    ctx.markDirty(widget.id)
  if not ctx.mouseMiddleDown:
    self.state[].panning = false
  if hot and ctx.mouseLeftPressed:
    ctx.setActive(widget.id)
    self.state[].beginDrag(view, ctx.mouseX, ctx.mouseY)
  if self.state[].dragKind != Mesh2DNoDrag and ctx.mouseLeftDown:
    ctx.setActive(widget.id)
    self.state[].drag(view, ctx.mouseX, ctx.mouseY)
    if self.state[].changed:
      ctx.submit(widget.id)
  if not ctx.mouseLeftDown:
    self.state[].dragKind = Mesh2DNoDrag

proc drawHandle(x, y: float64, selected: bool) =
  let color = if selected: color(240, 200, 86) else: color(226, 235, 236)
  fillRect(rect((x - HandleRadius).int, (y - HandleRadius).int,
      (HandleRadius * 2 + 1).int, (HandleRadius * 2 + 1).int), color)

method draw*(self: Mesh2DEditor, widget: Widget, ctx: var DrawContext) =
  ## Draw the backing image, the mesh's triangles and edges, and the handles
  ## of its points, with selected geometry highlighted.
  if self.state == nil:
    return
  let
    f = widget.frame
    view = widget.viewRect()
  fillRect(rect(f.x.int, f.y.int, f.width.int, f.height.int),
      ctx.palette.panelMuted)
  let zoom = max(self.state[].viewZoom, 0.25)
  let scaledWidth = view.width * zoom
  let scaledHeight = view.height * zoom
  let imageX = view.x + view.width * 0.5 - self.state[].viewCenterX * scaledWidth
  let imageY = view.y + view.height * 0.5 - self.state[].viewCenterY * scaledHeight
  saveState()
  setClipRect(rect(view.x.int, view.y.int, view.width.int, view.height.int))
  if self.imagePath.len > 0:
    let size = ctx.resources.measureImage(self.imagePath)
    if size.w > 0 and size.h > 0:
      drawImage(self.imagePath, rect(0, 0, size.w, size.h), rect(imageX.int,
          imageY.int, scaledWidth.int, scaledHeight.int))

  for triangle in self.state[].triangles:
    if triangle[0] < 0 or triangle[1] < 0 or triangle[2] < 0 or
        triangle[0] >= self.state[].points.len or
        triangle[1] >= self.state[].points.len or
        triangle[2] >= self.state[].points.len:
      continue
    let
      a = self.state[].points[triangle[0]].toScreen(self.state[], view)
      b = self.state[].points[triangle[1]].toScreen(self.state[], view)
      c = self.state[].points[triangle[2]].toScreen(self.state[], view)
      lineColor = color(71, 226, 184)
    drawLine(a.x.int, a.y.int, b.x.int, b.y.int, lineColor)
    drawLine(b.x.int, b.y.int, c.x.int, c.y.int, lineColor)
    drawLine(c.x.int, c.y.int, a.x.int, a.y.int, lineColor)

  for i, point in self.state[].points:
    let screenPoint = point.toScreen(self.state[], view)
    drawHandle(screenPoint.x, screenPoint.y, i in self.state[].selectedPoints)
  restoreState()
  lineRect(rect(view.x.int, view.y.int, view.width.int, view.height.int),
      color(88, 102, 105))
