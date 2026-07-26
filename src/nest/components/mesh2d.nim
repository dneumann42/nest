import std/[hashes, math, sets]

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

  Mesh2DEditor* = ref object of Interactive
    state: ptr Mesh2DState
    imagePath: string

proc hash*(edge: Mesh2DEdge): Hash =
  hash((min(edge.a, edge.b), max(edge.a, edge.b)))

proc `==`*(a, b: Mesh2DEdge): bool =
  (a.a == b.a and a.b == b.b) or (a.a == b.b and a.b == b.a)

proc new*(T: typedesc[Mesh2DEditor], state: var Mesh2DState,
    imagePath = ""): T =
  T(state: addr state, imagePath: imagePath)

method measure*(self: Mesh2DEditor, resources: Resources): IntrinsicSize =
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

proc toScreen(point: Mesh2DPoint, view: Frame): tuple[x, y: float64] =
  (view.x + point.x * view.width, view.y + point.y * view.height)

proc fromDelta(dx, dy: float64, view: Frame): Mesh2DPoint =
  Mesh2DPoint(x: dx / max(view.width, 1), y: dy / max(view.height, 1))

proc add(point: var Mesh2DPoint, delta: Mesh2DPoint) =
  point.x += delta.x
  point.y += delta.y

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
  var best = 9.0
  for i, point in state.points:
    let screenPoint = point.toScreen(view)
    let distance = distancePoint(x.float64, y.float64, screenPoint.x,
        screenPoint.y)
    if distance < best:
      best = distance
      result = i

proc pickEdge(state: Mesh2DState, view: Frame, x, y: int): Mesh2DEdge =
  result = Mesh2DEdge(a: -1, b: -1)
  var best = 7.0
  for triangle in state.triangles:
    for edge in [Mesh2DEdge(a: triangle[0], b: triangle[1]),
                 Mesh2DEdge(a: triangle[1], b: triangle[2]),
                 Mesh2DEdge(a: triangle[2], b: triangle[0])]:
      if edge.a < 0 or edge.b < 0 or edge.a >= state.points.len or
          edge.b >= state.points.len:
        continue
      let
        a = state.points[edge.a].toScreen(view)
        b = state.points[edge.b].toScreen(view)
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
      a = state.points[triangle[0]].toScreen(view)
      b = state.points[triangle[1]].toScreen(view)
      c = state.points[triangle[2]].toScreen(view)
    if pointInTriangle(x.float64, y.float64, a.x, a.y, b.x, b.y, c.x, c.y):
      return true

proc beginDrag(state: var Mesh2DState, view: Frame, x, y: int) =
  state.dragPoint = state.pickPoint(view, x, y)
  state.selectedPoints.clear()
  state.selectedEdges.clear()
  if state.dragPoint >= 0:
    state.dragKind = Mesh2DPointDrag
    state.selectedPoints.incl state.dragPoint
  else:
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
  let delta = fromDelta((x - state.lastMouseX).float64,
      (y - state.lastMouseY).float64, view)
  case state.dragKind
  of Mesh2DPointDrag:
    if state.dragPoint >= 0 and state.dragPoint < state.points.len:
      state.points[state.dragPoint].add delta
      state.changed = true
  of Mesh2DEdgeDrag, Mesh2DIslandDrag:
    for index in state.selectedPoints:
      if index >= 0 and index < state.points.len:
        state.points[index].add delta
        state.changed = true
  of Mesh2DNoDrag:
    discard
  state.lastMouseX = x
  state.lastMouseY = y

method update*(self: Mesh2DEditor, widget: Widget, ctx: var UpdateContext) =
  if self.state == nil:
    return
  let
    f = widget.frame
    view = widget.viewRect()
    hot = f.contains(ctx.mouseX, ctx.mouseY)
  if hot:
    ctx.setHot(widget.id)
  if hot and ctx.mouseLeftPressed:
    ctx.setActive(widget.id)
    self.state[].beginDrag(view, ctx.mouseX, ctx.mouseY)
  if ctx.active(widget.id) and ctx.mouseLeftDown:
    self.state[].drag(view, ctx.mouseX, ctx.mouseY)
    if self.state[].changed:
      ctx.submit(widget.id)
  if not ctx.mouseLeftDown:
    self.state[].dragKind = Mesh2DNoDrag

proc drawHandle(x, y: float64, selected: bool) =
  let color = if selected: color(240, 200, 86) else: color(226, 235, 236)
  fillRect(rect((x - 3).int, (y - 3).int, 7, 7), color)

method draw*(self: Mesh2DEditor, widget: Widget, ctx: var DrawContext) =
  if self.state == nil:
    return
  let
    f = widget.frame
    view = widget.viewRect()
  fillRect(rect(f.x.int, f.y.int, f.width.int, f.height.int),
      ctx.palette.panelMuted)
  if self.imagePath.len > 0:
    let
      image = ctx.resources.loadImage(self.imagePath)
      size = ctx.resources.measureImage(self.imagePath)
    if image.int != 0 and size.w > 0 and size.h > 0:
      drawImage(image, rect(0, 0, size.w, size.h), rect(view.x.int, view.y.int,
          view.width.int, view.height.int))
  lineRect(rect(view.x.int, view.y.int, view.width.int, view.height.int),
      color(88, 102, 105))

  for triangle in self.state[].triangles:
    if triangle[0] < 0 or triangle[1] < 0 or triangle[2] < 0 or
        triangle[0] >= self.state[].points.len or
        triangle[1] >= self.state[].points.len or
        triangle[2] >= self.state[].points.len:
      continue
    let
      a = self.state[].points[triangle[0]].toScreen(view)
      b = self.state[].points[triangle[1]].toScreen(view)
      c = self.state[].points[triangle[2]].toScreen(view)
      lineColor = color(71, 226, 184)
    drawLine(a.x.int, a.y.int, b.x.int, b.y.int, lineColor)
    drawLine(b.x.int, b.y.int, c.x.int, c.y.int, lineColor)
    drawLine(c.x.int, c.y.int, a.x.int, a.y.int, lineColor)

  for i, point in self.state[].points:
    let screenPoint = point.toScreen(view)
    drawHandle(screenPoint.x, screenPoint.y, i in self.state[].selectedPoints)
