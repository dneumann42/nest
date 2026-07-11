import std/[math, strformat]

import kiwiberry
export kiwiberry
import widgets2
export widgets2

const
  WindowResizeStrength = createStrength(999'ks, 0'ks, 0'ks)
  FillRemainingStrength = createStrength(2'ks, 0'ks, 0'ks)

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

  Justification* = enum
    JustifyStart
    JustifyCenter
    JustifyEnd

  LayoutBox* = Widget
  LayoutBoxID* = uint64

  ConstraintGroup* = object
    constraints*: seq[Constraint]

  Layout* = ref object
    solver*: SolverRef
    rootBox*: Widget
    boxes*: seq[Widget]

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

proc x*(box: Widget): Variable =
  box.x

proc y*(box: Widget): Variable =
  box.y

proc width*(box: Widget): Variable =
  box.w

proc height*(box: Widget): Variable =
  box.h

proc left*(box: Widget): Expression =
  box.x.toExpression

proc top*(box: Widget): Expression =
  box.y.toExpression

proc right*(box: Widget): Expression =
  box.x + box.w

proc bottom*(box: Widget): Expression =
  box.y + box.h

proc centerX*(box: Widget): Expression =
  box.x + box.w / 2.0

proc centerY*(box: Widget): Expression =
  box.y + box.h / 2.0

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

proc initBox(
    ui: Layout, id: WidgetID, name: string, width, height: SizePolicy
): Widget =
  result = Widget(
    id: id,
    x: newVariable(name & ".x"),
    y: newVariable(name & ".y"),
    w: newVariable(name & ".width"),
    h: newVariable(name & ".height"),
  )
  result.setStretch(width.kind != Fixed, height.kind != Fixed)
  ui.boxes.add result
  ui.applyPolicy(result.w, width)
  ui.applyPolicy(result.h, height)

proc box*(ui: Layout, id: LayoutBoxID, width = fill(), height = fill()): Widget =
  ui.initBox(WidgetID(id), $id, width, height)

proc box*(ui: Layout, id: string, width = fill(), height = fill()): Widget =
  ui.initBox(nextWidgetID(), id, width, height)

proc root*(ui: Layout, box: Widget) =
  ui.rootBox = box
  discard ui.solver.constraint(box.x == 0.0)
  discard ui.solver.constraint(box.y == 0.0)
  ui.solver[box.w] = WindowResizeStrength
  ui.solver[box.h] = WindowResizeStrength

proc resize*(ui: Layout, width, height: float64) =
  if ui.rootBox.w.isNil or ui.rootBox.h.isNil:
    raise newException(ValueError, "layout root must be set before resize")

  ui.solver.suggest(ui.rootBox.w, width)
  ui.solver.suggest(ui.rootBox.h, height)

proc solve*(ui: Layout) =
  ui.solver.update()

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

proc pin*(ui: Layout, child, parent: Widget, inset = 0.0) =
  discard ui.solver.constraint(child.left == parent.left + inset)
  discard ui.solver.constraint(child.top == parent.top + inset)
  discard ui.solver.constraint(child.right == parent.right - inset)
  discard ui.solver.constraint(child.bottom == parent.bottom - inset)

proc effectiveAlignment(child: Widget, parentAlignment: Alignment): Alignment =
  if child.alignSelf == AlignAuto: parentAlignment else: child.alignSelf

proc alignRowChild(
    ui: Layout, parent, child: Widget, alignment: Alignment, padding: float64
) =
  case alignment
  of AlignAuto:
    ui.alignRowChild(parent, child, AlignStretch, padding)
  of AlignStart:
    discard ui.solver.constraint(child.top == parent.top + padding)
    discard ui.solver.constraint(child.bottom <= parent.bottom - padding)
  of AlignCenter:
    discard ui.solver.constraint(child.top >= parent.top + padding)
    discard ui.solver.constraint(child.bottom <= parent.bottom - padding)
    discard ui.solver.constraint(child.centerY == parent.centerY)
  of AlignEnd:
    discard ui.solver.constraint(child.top >= parent.top + padding)
    discard ui.solver.constraint(child.bottom == parent.bottom - padding)
  of AlignStretch:
    discard ui.solver.constraint(child.top == parent.top + padding)
    if child.stretchHeight:
      discard ui.solver.constraint(child.bottom <= parent.bottom - padding)
      discard ui.solver.constraint(child.bottom == parent.bottom - padding)

proc alignColumnChild(
    ui: Layout, parent, child: Widget, alignment: Alignment, padding: float64
) =
  case alignment
  of AlignAuto:
    ui.alignColumnChild(parent, child, AlignStretch, padding)
  of AlignStart:
    discard ui.solver.constraint(child.left == parent.left + padding)
    discard ui.solver.constraint(child.right <= parent.right - padding)
  of AlignCenter:
    discard ui.solver.constraint(child.left >= parent.left + padding)
    discard ui.solver.constraint(child.right <= parent.right - padding)
    discard ui.solver.constraint(child.centerX == parent.centerX)
  of AlignEnd:
    discard ui.solver.constraint(child.left >= parent.left + padding)
    discard ui.solver.constraint(child.right == parent.right - padding)
  of AlignStretch:
    discard ui.solver.constraint(child.left == parent.left + padding)
    if child.stretchWidth:
      discard ui.solver.constraint(child.width == parent.width - padding * 2.0)

proc row*(
    ui: Layout,
    parent: Widget,
    children: openArray[Widget],
    gap = 0.0,
    padding = 0.0,
    alignItems = AlignStretch,
    justifyContent = JustifyStart,
) =
  if children.len == 0:
    return

  for child in children:
    ui.alignRowChild(parent, child, child.effectiveAlignment(alignItems), padding)

  discard ui.solver.constraint(children[0].left >= parent.left + padding)

  for i in 1 ..< children.len:
    discard ui.solver.constraint(children[i].left == children[i - 1].right + gap)

  discard ui.solver.constraint(children[^1].right <= parent.right - padding)

  case justifyContent
  of JustifyStart:
    discard ui.solver.constraint(children[0].left == parent.left + padding)
    discard ui.solver.constraint(
      (children[^1].right == parent.right - padding) | FillRemainingStrength
    )
  of JustifyCenter:
    discard ui.solver.constraint(
      (children[0].left + children[^1].right) / 2.0 == parent.centerX
    )
  of JustifyEnd:
    discard ui.solver.constraint(children[^1].right == parent.right - padding)

proc column*(
    ui: Layout,
    parent: Widget,
    children: openArray[Widget],
    gap = 0.0,
    padding = 0.0,
    alignItems = AlignStretch,
    justifyContent = JustifyStart,
) =
  if children.len == 0:
    return

  for child in children:
    ui.alignColumnChild(parent, child, child.effectiveAlignment(alignItems), padding)

  discard ui.solver.constraint(children[0].top >= parent.top + padding)

  for i in 1 ..< children.len:
    discard ui.solver.constraint(children[i].top == children[i - 1].bottom + gap)

  discard ui.solver.constraint(children[^1].bottom <= parent.bottom - padding)

  case justifyContent
  of JustifyStart:
    discard ui.solver.constraint(children[0].top == parent.top + padding)
    discard ui.solver.constraint(
      (children[^1].bottom == parent.bottom - padding) | FillRemainingStrength
    )
  of JustifyCenter:
    discard ui.solver.constraint(
      (children[0].top + children[^1].bottom) / 2.0 == parent.centerY
    )
  of JustifyEnd:
    discard ui.solver.constraint(children[^1].bottom == parent.bottom - padding)

proc alignLeft*(ui: Layout, a, b: Widget, offset = 0.0) =
  discard ui.solver.constraint(a.left == b.left + offset)

proc alignRight*(ui: Layout, a, b: Widget, offset = 0.0) =
  discard ui.solver.constraint(a.right == b.right + offset)

proc alignTop*(ui: Layout, a, b: Widget, offset = 0.0) =
  discard ui.solver.constraint(a.top == b.top + offset)

proc alignBottom*(ui: Layout, a, b: Widget, offset = 0.0) =
  discard ui.solver.constraint(a.bottom == b.bottom + offset)

proc alignCenterX*(ui: Layout, a, b: Widget, offset = 0.0) =
  discard ui.solver.constraint(a.centerX == b.centerX + offset)

proc alignCenterY*(ui: Layout, a, b: Widget, offset = 0.0) =
  discard ui.solver.constraint(a.centerY == b.centerY + offset)

proc after*(ui: Layout, a, b: Widget, gap = 0.0) =
  discard ui.solver.constraint(a.left == b.right + gap)

proc below*(ui: Layout, a, b: Widget, gap = 0.0) =
  discard ui.solver.constraint(a.top == b.bottom + gap)

proc equalWidth*(ui: Layout, boxes: varargs[Widget]) =
  if boxes.len < 2:
    return

  for i in 1 ..< boxes.len:
    discard ui.solver.constraint(boxes[i].width == boxes[0].width)

proc equalHeight*(ui: Layout, boxes: varargs[Widget]) =
  if boxes.len < 2:
    return

  for i in 1 ..< boxes.len:
    discard ui.solver.constraint(boxes[i].height == boxes[0].height)
