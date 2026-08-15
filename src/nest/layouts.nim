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

  EdgeInsets* = object
    left*, top*, right*, bottom*: float64

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

proc insets*(all: float64): EdgeInsets =
  EdgeInsets(left: all, top: all, right: all, bottom: all)

proc insets*(left, top, right, bottom: float64): EdgeInsets =
  EdgeInsets(left: left, top: top, right: right, bottom: bottom)

proc resolveInsets(
    padding, paddingLeft, paddingTop, paddingRight, paddingBottom: float64
): EdgeInsets =
  result = insets(padding)
  if paddingLeft == paddingLeft:
    result.left = paddingLeft
  if paddingTop == paddingTop:
    result.top = paddingTop
  if paddingRight == paddingRight:
    result.right = paddingRight
  if paddingBottom == paddingBottom:
    result.bottom = paddingBottom

proc widgetPolicy(policy: SizePolicy): WidgetSizePolicy =
  let kind =
    case policy.kind
    of Fill: WidgetFill
    of Fixed: WidgetFixed
    of Fit: WidgetFit
    of Hug: WidgetHug
    of Prefer: WidgetPrefer
  WidgetSizePolicy(kind: kind, value: policy.value, min: policy.min,
      max: policy.max)

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
  case policy.kind
  of Fill:
    discard ui.constrain(variable >= policy.min)
    if policy.max < Inf:
      discard ui.constrain(variable <= policy.max)
    discard
  of Fit:
    discard ui.constrain(variable >= policy.min)
    if policy.max < Inf:
      discard ui.constrain(variable <= policy.max)
    discard
  of Fixed:
    discard ui.constrain(variable == policy.value)
  of Hug, Prefer:
    discard ui.constrain(variable >= policy.min)
    if policy.max < Inf:
      discard ui.constrain(variable <= policy.max)
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
    widthPolicy: width.widgetPolicy,
    heightPolicy: height.widgetPolicy,
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
  let pad = insets(inset)
  discard ui.constrain(child.left == parent.left + pad.left)
  discard ui.constrain(child.top == parent.top + pad.top)
  discard ui.constrain(child.right == parent.right - pad.right)
  discard ui.constrain(child.bottom == parent.bottom - pad.bottom)

proc effectiveAlignment(child: Widget, parentAlignment: Alignment): Alignment =
  if child.alignSelf == AlignAuto: parentAlignment else: child.alignSelf

proc overlay*(
    ui: Layout,
    parent: Widget,
    children: openArray[Widget],
    padding = 0.0,
    paddingLeft = NaN,
    paddingTop = NaN,
    paddingRight = NaN,
    paddingBottom = NaN,
    alignItems = AlignStretch,
    justifyContent = JustifyCenter,
) =
  let pad = resolveInsets(padding, paddingLeft, paddingTop, paddingRight,
      paddingBottom)
  for child in children:
    case child.effectiveAlignment(alignItems)
    of AlignAuto, AlignStretch:
      discard ui.constrain(child.left == parent.left + pad.left)
      if child.stretchWidth:
        discard ui.constrain(child.right == parent.right - pad.right)
    of AlignStart:
      discard ui.constrain(child.left == parent.left + pad.left)
      discard ui.constrain(child.right <= parent.right - pad.right)
    of AlignCenter:
      discard ui.constrain(child.left >= parent.left + pad.left)
      discard ui.constrain(child.right <= parent.right - pad.right)
      discard ui.constrain(child.centerX == parent.left + pad.left +
          (parent.width - pad.left - pad.right) / 2.0)
    of AlignEnd:
      discard ui.constrain(child.left >= parent.left + pad.left)
      discard ui.constrain(child.right == parent.right - pad.right)

    if child.stretchHeight:
      discard ui.constrain(child.top == parent.top + pad.top)
      discard ui.constrain(child.bottom == parent.bottom - pad.bottom)
    else:
      case justifyContent
      of JustifyStart:
        discard ui.constrain(child.top == parent.top + pad.top)
        discard ui.constrain(child.bottom <= parent.bottom - pad.bottom)
      of JustifyCenter:
        discard ui.constrain(child.top >= parent.top + pad.top)
        discard ui.constrain(child.bottom <= parent.bottom - pad.bottom)
        discard ui.constrain(child.centerY == parent.top + pad.top +
            (parent.height - pad.top - pad.bottom) / 2.0)
      of JustifyEnd:
        discard ui.constrain(child.top >= parent.top + pad.top)
        discard ui.constrain(child.bottom == parent.bottom - pad.bottom)

proc alignRowChild(
    ui: Layout,
    parent, child: Widget,
    alignment: Alignment,
    padding: EdgeInsets,
    allowOverflowY = false,
) =
  let pad = padding
  case alignment
  of AlignAuto:
    ui.alignRowChild(parent, child, AlignStretch, padding, allowOverflowY)
  of AlignStart:
    discard ui.constrain(child.top == parent.top + pad.top)
    if not allowOverflowY:
      discard ui.constrain(child.bottom <= parent.bottom - pad.bottom)
  of AlignCenter:
    discard ui.constrain(child.top >= parent.top + pad.top)
    if not allowOverflowY:
      discard ui.constrain(child.bottom <= parent.bottom - pad.bottom)
    discard ui.constrain(child.centerY == parent.top + pad.top +
        (parent.height - pad.top - pad.bottom) / 2.0)
  of AlignEnd:
    discard ui.constrain(child.top >= parent.top + pad.top)
    discard ui.constrain(child.bottom == parent.bottom - pad.bottom)
  of AlignStretch:
    discard ui.constrain(child.top == parent.top + pad.top)
    if child.stretchHeight:
      discard ui.constrain(child.bottom <= parent.bottom - pad.bottom)
      discard ui.constrain(child.bottom == parent.bottom - pad.bottom)

proc alignColumnChild(
    ui: Layout,
    parent, child: Widget,
    alignment: Alignment,
    padding: EdgeInsets,
    allowOverflowX = false,
) =
  let pad = padding
  case alignment
  of AlignAuto:
    ui.alignColumnChild(parent, child, AlignStretch, padding, allowOverflowX)
  of AlignStart:
    discard ui.constrain(child.left == parent.left + pad.left)
    if not allowOverflowX:
      discard ui.constrain(child.right <= parent.right - pad.right)
  of AlignCenter:
    discard ui.constrain(child.left >= parent.left + pad.left)
    if not allowOverflowX:
      discard ui.constrain(child.right <= parent.right - pad.right)
    discard ui.constrain(child.centerX == parent.left + pad.left +
        (parent.width - pad.left - pad.right) / 2.0)
  of AlignEnd:
    discard ui.constrain(child.left >= parent.left + pad.left)
    discard ui.constrain(child.right == parent.right - pad.right)
  of AlignStretch:
    discard ui.constrain(child.left == parent.left + pad.left)
    if child.stretchWidth:
      discard ui.constrain(child.width == parent.width - pad.left -
          pad.right)

proc row*(
    ui: Layout,
    parent: Widget,
    children: openArray[Widget],
    gap = 0.0,
    padding = 0.0,
    paddingLeft = NaN,
    paddingTop = NaN,
    paddingRight = NaN,
    paddingBottom = NaN,
    alignItems = AlignStretch,
    justifyContent = JustifyStart,
    scrollX = false,
    scrollY = false,
) =
  if children.len == 0:
    return
  let pad = resolveInsets(padding, paddingLeft, paddingTop, paddingRight,
      paddingBottom)

  for child in children:
    ui.alignRowChild(
      parent, child, child.effectiveAlignment(alignItems), pad, scrollY
    )

  if parent.fitWidth:
    discard ui.constrain(children[0].left == parent.left + pad.left)
  else:
    discard ui.constrain(children[0].left >= parent.left + pad.left)

  for i in 1 ..< children.len:
    discard ui.constrain(children[i].left == children[i - 1].right + gap)

  if not scrollX:
    var fillChildren: seq[Widget]
    for child in children:
      if child.widthPolicy.kind == WidgetFill:
        fillChildren.add child
    for i in 1 ..< fillChildren.len:
      discard ui.constrain(
        (fillChildren[i].width == fillChildren[0].width) | FillRemainingStrength
      )

  if not parent.fitWidth and not scrollX:
    discard ui.constrain(children[^1].right <= parent.right - pad.right)

  if parent.fitWidth:
    var contentWidth: Expression = children[0].width.toExpression
    for i in 1 ..< children.len:
      contentWidth = contentWidth + children[i].width + gap
    discard ui.constrain((parent.width == contentWidth + pad.left +
        pad.right) | Strong)

  if parent.fitHeight:
    for child in children:
      discard ui.constrain(parent.height >= child.height + pad.top +
          pad.bottom)
      discard ui.constrain(
        (parent.height == child.height + pad.top + pad.bottom) |
            FillRemainingStrength
      )

  case justifyContent
  of JustifyStart:
    discard ui.constrain(children[0].left == parent.left + pad.left)
    if not scrollX:
      discard ui.constrain(
        (children[^1].right == parent.right - pad.right) |
            FillRemainingStrength
      )
  of JustifyCenter:
    discard
      ui.constrain((children[0].left + children[^1].right) / 2.0 ==
          parent.left + pad.left + (parent.width - pad.left - pad.right) / 2.0)
  of JustifyEnd:
    discard ui.constrain(children[^1].right == parent.right - pad.right)

proc column*(
    ui: Layout,
    parent: Widget,
    children: openArray[Widget],
    gap = 0.0,
    padding = 0.0,
    paddingLeft = NaN,
    paddingTop = NaN,
    paddingRight = NaN,
    paddingBottom = NaN,
    alignItems = AlignStretch,
    justifyContent = JustifyStart,
    scrollX = false,
    scrollY = false,
) =
  if children.len == 0:
    return
  let pad = resolveInsets(padding, paddingLeft, paddingTop, paddingRight,
      paddingBottom)

  for child in children:
    ui.alignColumnChild(
      parent, child, child.effectiveAlignment(alignItems), pad, scrollX
    )

  if parent.fitHeight:
    discard ui.constrain(children[0].top == parent.top + pad.top)
  else:
    discard ui.constrain(children[0].top >= parent.top + pad.top)

  for i in 1 ..< children.len:
    discard ui.constrain(children[i].top == children[i - 1].bottom + gap)

  if not scrollY:
    var fillChildren: seq[Widget]
    for child in children:
      if child.heightPolicy.kind == WidgetFill:
        fillChildren.add child
    for i in 1 ..< fillChildren.len:
      discard ui.constrain(
        (fillChildren[i].height == fillChildren[0].height) | FillRemainingStrength
      )

  if not parent.fitHeight and not scrollY:
    discard ui.constrain(children[^1].bottom <= parent.bottom - pad.bottom)

  if parent.fitHeight:
    var contentHeight: Expression = children[0].height.toExpression
    for i in 1 ..< children.len:
      contentHeight = contentHeight + children[i].height + gap
    discard ui.constrain((parent.height == contentHeight + pad.top +
        pad.bottom) | Strong)

  if parent.fitWidth:
    for child in children:
      discard ui.constrain(parent.width >= child.width + pad.left +
          pad.right)
      discard ui.constrain(
        (parent.width == child.width + pad.left + pad.right) |
            FillRemainingStrength
      )

  case justifyContent
  of JustifyStart:
    discard ui.constrain(children[0].top == parent.top + pad.top)
    if not scrollY:
      discard ui.constrain(
        (children[^1].bottom == parent.bottom - pad.bottom) |
            FillRemainingStrength
      )
  of JustifyCenter:
    discard
      ui.constrain((children[0].top + children[^1].bottom) / 2.0 ==
          parent.top + pad.top + (parent.height - pad.top - pad.bottom) / 2.0)
  of JustifyEnd:
    discard ui.constrain(children[^1].bottom == parent.bottom - pad.bottom)

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
