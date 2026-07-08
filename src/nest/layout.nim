import std/[math, strformat]

import kiwiberry
export kiwiberry

type
  SizePolicyKind* = enum
    Fill
    Fixed
    Hug
    Prefer

  SizePolicy* = object
    kind*: SizePolicyKind
    value*: float64
    min*: float64
    max*: float64

  Frame* = object
    x*, y*, width*, height*: float64

  LayoutBox* = ref object
    name*: string
    xv, yv, wv, hv: Variable

  ConstraintGroup* = object
    constraints*: seq[Constraint]

  Layout* = ref object
    solver*: SolverRef
    rootBox*: LayoutBox
    boxes*: seq[LayoutBox]

proc `$`*(frame: Frame): string =
  &"Frame(x: {frame.x}, y: {frame.y}, width: {frame.width}, height: {frame.height})"

proc fill*(min = 0.0, max = Inf): SizePolicy =
  SizePolicy(kind: Fill, min: min, max: max)

proc fixed*(value: float64): SizePolicy =
  SizePolicy(kind: Fixed, value: value, min: value, max: value)

proc hug*(preferred: float64, min = 0.0, max = Inf): SizePolicy =
  SizePolicy(kind: Hug, value: preferred, min: min, max: max)

proc prefer*(value: float64, min = 0.0, max = Inf): SizePolicy =
  SizePolicy(kind: Prefer, value: value, min: min, max: max)

proc newLayout*(): Layout =
  Layout(solver: newSolver())

proc x*(box: LayoutBox): Variable =
  box.xv

proc y*(box: LayoutBox): Variable =
  box.yv

proc width*(box: LayoutBox): Variable =
  box.wv

proc height*(box: LayoutBox): Variable =
  box.hv

proc left*(box: LayoutBox): Expression =
  box.xv.toExpression

proc top*(box: LayoutBox): Expression =
  box.yv.toExpression

proc right*(box: LayoutBox): Expression =
  box.xv + box.wv

proc bottom*(box: LayoutBox): Expression =
  box.yv + box.hv

proc centerX*(box: LayoutBox): Expression =
  box.xv + box.wv / 2.0

proc centerY*(box: LayoutBox): Expression =
  box.yv + box.hv / 2.0

proc applyPolicy(ui: Layout, variable: Variable, policy: SizePolicy) =
  discard ui.solver.constraint(variable >= policy.min)

  if policy.max < Inf:
    discard ui.solver.constraint(variable <= policy.max)

  case policy.kind
  of Fill:
    discard
  of Fixed:
    discard ui.solver.constraint(variable == policy.value)
  of Hug, Prefer:
    discard ui.solver.constraint((variable == policy.value) | Strong)

proc box*(ui: Layout, name: string, width = fill(), height = fill()): LayoutBox =
  result = LayoutBox(
    name: name,
    xv: newVariable(name & ".x"),
    yv: newVariable(name & ".y"),
    wv: newVariable(name & ".width"),
    hv: newVariable(name & ".height"),
  )
  ui.boxes.add result
  ui.applyPolicy(result.wv, width)
  ui.applyPolicy(result.hv, height)

proc root*(ui: Layout, box: LayoutBox) =
  ui.rootBox = box
  discard ui.solver.constraint(box.x == 0.0)
  discard ui.solver.constraint(box.y == 0.0)
  ui.solver[box.width] = Strong
  ui.solver[box.height] = Strong

proc resize*(ui: Layout, width, height: float64) =
  if ui.rootBox.isNil:
    raise newException(ValueError, "layout has no root box")

  ui.solver.suggest(ui.rootBox.width, width)
  ui.solver.suggest(ui.rootBox.height, height)

proc solve*(ui: Layout) =
  ui.solver.update()

proc frame*(box: LayoutBox): Frame =
  Frame(
    x: box.x.value.float64,
    y: box.y.value.float64,
    width: box.width.value.float64,
    height: box.height.value.float64,
  )

proc constrain*(ui: Layout, constraint: Constraint): Constraint {.discardable.} =
  ui.solver.constraint(constraint)

proc add*(group: var ConstraintGroup, constraint: Constraint) =
  group.constraints.add constraint

template collect*(ui: Layout, body: untyped): ConstraintGroup =
  block:
    var collected {.gensym.}: ConstraintGroup
    template keep(constraint: Constraint) =
      collected.add constraint

    body
    collected

proc remove*(ui: Layout, group: ConstraintGroup) =
  for constraint in group.constraints:
    ui.solver.remove constraint

proc pin*(ui: Layout, child, parent: LayoutBox, inset = 0.0) =
  discard ui.solver.constraint(child.left == parent.left + inset)
  discard ui.solver.constraint(child.top == parent.top + inset)
  discard ui.solver.constraint(child.right == parent.right - inset)
  discard ui.solver.constraint(child.bottom == parent.bottom - inset)

proc row*(
    ui: Layout,
    parent: LayoutBox,
    children: openArray[LayoutBox],
    gap = 0.0,
    padding = 0.0,
) =
  if children.len == 0:
    return

  for child in children:
    discard ui.solver.constraint(child.top == parent.top + padding)
    discard ui.solver.constraint(child.bottom == parent.bottom - padding)

  discard ui.solver.constraint(children[0].left == parent.left + padding)

  for i in 1 ..< children.len:
    discard ui.solver.constraint(children[i].left == children[i - 1].right + gap)

  discard ui.solver.constraint(children[^1].right == parent.right - padding)

proc column*(
    ui: Layout,
    parent: LayoutBox,
    children: openArray[LayoutBox],
    gap = 0.0,
    padding = 0.0,
) =
  if children.len == 0:
    return

  for child in children:
    discard ui.solver.constraint(child.left == parent.left + padding)
    discard ui.solver.constraint(child.right == parent.right - padding)

  discard ui.solver.constraint(children[0].top == parent.top + padding)

  for i in 1 ..< children.len:
    discard ui.solver.constraint(children[i].top == children[i - 1].bottom + gap)

  discard ui.solver.constraint(children[^1].bottom == parent.bottom - padding)

proc alignLeft*(ui: Layout, a, b: LayoutBox, offset = 0.0) =
  discard ui.solver.constraint(a.left == b.left + offset)

proc alignRight*(ui: Layout, a, b: LayoutBox, offset = 0.0) =
  discard ui.solver.constraint(a.right == b.right + offset)

proc alignTop*(ui: Layout, a, b: LayoutBox, offset = 0.0) =
  discard ui.solver.constraint(a.top == b.top + offset)

proc alignBottom*(ui: Layout, a, b: LayoutBox, offset = 0.0) =
  discard ui.solver.constraint(a.bottom == b.bottom + offset)

proc alignCenterX*(ui: Layout, a, b: LayoutBox, offset = 0.0) =
  discard ui.solver.constraint(a.centerX == b.centerX + offset)

proc alignCenterY*(ui: Layout, a, b: LayoutBox, offset = 0.0) =
  discard ui.solver.constraint(a.centerY == b.centerY + offset)

proc after*(ui: Layout, a, b: LayoutBox, gap = 0.0) =
  discard ui.solver.constraint(a.left == b.right + gap)

proc below*(ui: Layout, a, b: LayoutBox, gap = 0.0) =
  discard ui.solver.constraint(a.top == b.bottom + gap)

proc equalWidth*(ui: Layout, boxes: varargs[LayoutBox]) =
  if boxes.len < 2:
    return

  for i in 1 ..< boxes.len:
    discard ui.solver.constraint(boxes[i].width == boxes[0].width)

proc equalHeight*(ui: Layout, boxes: varargs[LayoutBox]) =
  if boxes.len < 2:
    return

  for i in 1 ..< boxes.len:
    discard ui.solver.constraint(boxes[i].height == boxes[0].height)
