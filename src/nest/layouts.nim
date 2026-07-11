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
    Fit
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

proc fit*(min = 0.0, max = Inf): SizePolicy =
  SizePolicy(kind: Fit, min: min, max: max)

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

proc constrain*(ui: Layout, constraint: Constraint): Constraint {.discardable.} =
  try:
    result = ui.solver.constraint(constraint)
  except InternalSolverError, UnsatisfiableConstraintError, DuplicateConstraintError:
    result = constraint

proc applyPolicy(ui: Layout, variable: Variable, policy: SizePolicy) =
  discard ui.constrain(variable >= policy.min)

  if policy.max < Inf:
    discard ui.constrain(variable <= policy.max)

  case policy.kind
  of Fill:
    discard
  of Fit:
    discard
  of Fixed:
    discard ui.constrain(variable == policy.value)
  of Hug, Prefer:
    discard ui.constrain((variable == policy.value) | Strong)

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
  result.setStretch(width.kind notin {Fixed, Fit}, height.kind notin {Fixed, Fit})
  result.setFit(width.kind == Fit, height.kind == Fit)
  ui.boxes.add result
  ui.applyPolicy(result.w, width)
  ui.applyPolicy(result.h, height)

proc box*(ui: Layout, id: LayoutBoxID, width = fill(), height = fill()): Widget =
  ui.initBox(WidgetID(id), $id, width, height)

proc box*(ui: Layout, id: string, width = fill(), height = fill()): Widget =
  ui.initBox(nextWidgetID(), id, width, height)

proc root*(ui: Layout, box: Widget) =
  ui.rootBox = box
  discard ui.constrain(box.x == 0.0)
  discard ui.constrain(box.y == 0.0)
  ui.solver[box.w] = WindowResizeStrength
  ui.solver[box.h] = WindowResizeStrength

proc resize*(ui: Layout, width, height: float64) =
  if ui.rootBox.w.isNil or ui.rootBox.h.isNil:
    raise newException(ValueError, "layout root must be set before resize")

  ui.solver.suggest(ui.rootBox.w, max(width, 0.0))
  ui.solver.suggest(ui.rootBox.h, max(height, 0.0))

proc solve*(ui: Layout): bool {.discardable.} =
  try:
    ui.solver.update()
    result = true
  except InternalSolverError, UnsatisfiableConstraintError:
    result = false

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
  discard ui.constrain(child.left == parent.left + inset)
  discard ui.constrain(child.top == parent.top + inset)
  discard ui.constrain(child.right == parent.right - inset)
  discard ui.constrain(child.bottom == parent.bottom - inset)

proc effectiveAlignment(child: Widget, parentAlignment: Alignment): Alignment =
  if child.alignSelf == AlignAuto: parentAlignment else: child.alignSelf

proc alignRowChild(
    ui: Layout,
    parent,
    child: Widget,
    alignment: Alignment,
    padding: float64,
    allowOverflowY = false,
) =
  case alignment
  of AlignAuto:
    ui.alignRowChild(parent, child, AlignStretch, padding, allowOverflowY)
  of AlignStart:
    discard ui.constrain(child.top == parent.top + padding)
    if not allowOverflowY:
      discard ui.constrain(child.bottom <= parent.bottom - padding)
  of AlignCenter:
    discard ui.constrain(child.top >= parent.top + padding)
    if not allowOverflowY:
      discard ui.constrain(child.bottom <= parent.bottom - padding)
    discard ui.constrain(child.centerY == parent.centerY)
  of AlignEnd:
    discard ui.constrain(child.top >= parent.top + padding)
    discard ui.constrain(child.bottom == parent.bottom - padding)
  of AlignStretch:
    discard ui.constrain(child.top == parent.top + padding)
    if child.stretchHeight:
      discard ui.constrain(child.bottom <= parent.bottom - padding)
      discard ui.constrain(child.bottom == parent.bottom - padding)

proc alignColumnChild(
    ui: Layout,
    parent,
    child: Widget,
    alignment: Alignment,
    padding: float64,
    allowOverflowX = false,
) =
  case alignment
  of AlignAuto:
    ui.alignColumnChild(parent, child, AlignStretch, padding, allowOverflowX)
  of AlignStart:
    discard ui.constrain(child.left == parent.left + padding)
    if not allowOverflowX:
      discard ui.constrain(child.right <= parent.right - padding)
  of AlignCenter:
    discard ui.constrain(child.left >= parent.left + padding)
    if not allowOverflowX:
      discard ui.constrain(child.right <= parent.right - padding)
    discard ui.constrain(child.centerX == parent.centerX)
  of AlignEnd:
    discard ui.constrain(child.left >= parent.left + padding)
    discard ui.constrain(child.right == parent.right - padding)
  of AlignStretch:
    discard ui.constrain(child.left == parent.left + padding)
    if child.stretchWidth:
      discard ui.constrain(child.width == parent.width - padding * 2.0)

proc row*(
    ui: Layout,
    parent: Widget,
    children: openArray[Widget],
    gap = 0.0,
    padding = 0.0,
    alignItems = AlignStretch,
    justifyContent = JustifyStart,
    scrollX = false,
    scrollY = false,
) =
  if children.len == 0:
    return

  for child in children:
    ui.alignRowChild(parent, child, child.effectiveAlignment(alignItems), padding, scrollY)

  if parent.fitWidth:
    discard ui.constrain(children[0].left == parent.left + padding)
  else:
    discard ui.constrain(children[0].left >= parent.left + padding)

  for i in 1 ..< children.len:
    discard ui.constrain(children[i].left == children[i - 1].right + gap)

  if not parent.fitWidth and not scrollX:
    discard ui.constrain(children[^1].right <= parent.right - padding)

  if parent.fitWidth:
    var contentWidth: Expression = children[0].width.toExpression
    for i in 1 ..< children.len:
      contentWidth = contentWidth + children[i].width + gap
    discard ui.constrain((parent.width == contentWidth + padding * 2.0) | Strong)

  if parent.fitHeight:
    for child in children:
      discard ui.constrain(parent.height >= child.height + padding * 2.0)
      discard ui.constrain(
        (parent.height == child.height + padding * 2.0) | FillRemainingStrength
      )

  case justifyContent
  of JustifyStart:
    discard ui.constrain(children[0].left == parent.left + padding)
    if not scrollX:
      discard ui.constrain(
        (children[^1].right == parent.right - padding) | FillRemainingStrength
      )
  of JustifyCenter:
    discard ui.constrain(
      (children[0].left + children[^1].right) / 2.0 == parent.centerX
    )
  of JustifyEnd:
    discard ui.constrain(children[^1].right == parent.right - padding)

proc column*(
    ui: Layout,
    parent: Widget,
    children: openArray[Widget],
    gap = 0.0,
    padding = 0.0,
    alignItems = AlignStretch,
    justifyContent = JustifyStart,
    scrollX = false,
    scrollY = false,
) =
  if children.len == 0:
    return

  for child in children:
    ui.alignColumnChild(parent, child, child.effectiveAlignment(alignItems), padding, scrollX)

  if parent.fitHeight:
    discard ui.constrain(children[0].top == parent.top + padding)
  else:
    discard ui.constrain(children[0].top >= parent.top + padding)

  for i in 1 ..< children.len:
    discard ui.constrain(children[i].top == children[i - 1].bottom + gap)

  if not parent.fitHeight and not scrollY:
    discard ui.constrain(children[^1].bottom <= parent.bottom - padding)

  if parent.fitHeight:
    var contentHeight: Expression = children[0].height.toExpression
    for i in 1 ..< children.len:
      contentHeight = contentHeight + children[i].height + gap
    discard ui.constrain((parent.height == contentHeight + padding * 2.0) | Strong)

  if parent.fitWidth:
    for child in children:
      discard ui.constrain(parent.width >= child.width + padding * 2.0)
      discard ui.constrain(
        (parent.width == child.width + padding * 2.0) | FillRemainingStrength
      )

  case justifyContent
  of JustifyStart:
    discard ui.constrain(children[0].top == parent.top + padding)
    if not scrollY:
      discard ui.constrain(
        (children[^1].bottom == parent.bottom - padding) | FillRemainingStrength
      )
  of JustifyCenter:
    discard ui.constrain(
      (children[0].top + children[^1].bottom) / 2.0 == parent.centerY
    )
  of JustifyEnd:
    discard ui.constrain(children[^1].bottom == parent.bottom - padding)

proc alignLeft*(ui: Layout, a, b: Widget, offset = 0.0) =
  discard ui.constrain(a.left == b.left + offset)

proc alignRight*(ui: Layout, a, b: Widget, offset = 0.0) =
  discard ui.constrain(a.right == b.right + offset)

proc alignTop*(ui: Layout, a, b: Widget, offset = 0.0) =
  discard ui.constrain(a.top == b.top + offset)

proc alignBottom*(ui: Layout, a, b: Widget, offset = 0.0) =
  discard ui.constrain(a.bottom == b.bottom + offset)

proc alignCenterX*(ui: Layout, a, b: Widget, offset = 0.0) =
  discard ui.constrain(a.centerX == b.centerX + offset)

proc alignCenterY*(ui: Layout, a, b: Widget, offset = 0.0) =
  discard ui.constrain(a.centerY == b.centerY + offset)

proc after*(ui: Layout, a, b: Widget, gap = 0.0) =
  discard ui.constrain(a.left == b.right + gap)

proc below*(ui: Layout, a, b: Widget, gap = 0.0) =
  discard ui.constrain(a.top == b.bottom + gap)

proc equalWidth*(ui: Layout, boxes: varargs[Widget]) =
  if boxes.len < 2:
    return

  for i in 1 ..< boxes.len:
    discard ui.constrain(boxes[i].width == boxes[0].width)

proc equalHeight*(ui: Layout, boxes: varargs[Widget]) =
  if boxes.len < 2:
    return

  for i in 1 ..< boxes.len:
    discard ui.constrain(boxes[i].height == boxes[0].height)
