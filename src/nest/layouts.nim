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
  ## Render a frame as text, for debugging and test failures.
  &"Frame(x: {frame.x}, y: {frame.y}, width: {frame.width}, height: {frame.height})"

proc fill*(min = 0.0, max = Inf): SizePolicy =
  ## Size policy that takes as much space as the parent can give. `min` and `max` bound the result.
  SizePolicy(kind: Fill, min: min, max: max)

proc fixed*(value: float64): SizePolicy =
  ## Size policy that pins the box to exactly `value` pixels.
  SizePolicy(kind: Fixed, value: value, min: value, max: value)

proc fit*(min = 0.0, max = Inf): SizePolicy =
  ## Size policy that shrinks the box to its content's intrinsic size.
  ##
  ## `min` and `max` bound the result. A box with no intrinsic size falls back to `min`.
  SizePolicy(kind: Fit, min: min, max: max)

proc hug*(preferred: float64, min = 0.0, max = Inf): SizePolicy =
  ## Size policy that asks for `preferred` pixels but yields when the
  ## surrounding constraints require another size. `min` and `max` bound the result.
  SizePolicy(kind: Hug, value: preferred, min: min, max: max)

proc prefer*(value: float64, min = 0.0, max = Inf): SizePolicy =
  ## Size policy that asks for `value` pixels but yields when the
  ## surrounding constraints require another size. `min` and `max` bound the result.
  ##
  ## Behaves like `hug`.
  SizePolicy(kind: Prefer, value: value, min: min, max: max)

proc insets*(all: float64): EdgeInsets =
  ## Return insets with the same padding on all four edges.
  EdgeInsets(left: all, top: all, right: all, bottom: all)

proc insets*(left, top, right, bottom: float64): EdgeInsets =
  ## Return insets with a separate value per edge.
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
  ## Create an empty layout with a fresh constraint solver.
  Layout(solver: newSolver())

proc x*(box: Widget): Variable =
  ## Return the solver variable holding the box's left edge.
  box.x

proc y*(box: Widget): Variable =
  ## Return the solver variable holding the box's top edge.
  box.y

proc width*(box: Widget): Variable =
  ## Return the solver variable holding the box's width.
  box.w

proc height*(box: Widget): Variable =
  ## Return the solver variable holding the box's height.
  box.h

proc left*(box: Widget): Expression =
  ## Return the box's left edge as a constraint expression.
  box.x.toExpression

proc top*(box: Widget): Expression =
  ## Return the box's top edge as a constraint expression.
  box.y.toExpression

proc right*(box: Widget): Expression =
  ## Return the box's right edge as a constraint expression.
  box.x + box.w

proc bottom*(box: Widget): Expression =
  ## Return the box's bottom edge as a constraint expression.
  box.y + box.h

proc centerX*(box: Widget): Expression =
  ## Return the box's horizontal centre as a constraint expression.
  box.x + box.w / 2.0

proc centerY*(box: Widget): Expression =
  ## Return the box's vertical centre as a constraint expression.
  box.y + box.h / 2.0

proc constrain*(ui: Layout, constraint: Constraint): Constraint {.discardable.} =
  ## Add `constraint` to the layout's solver and return it, so it can be
  ## removed again later.
  ##
  ## A constraint the solver rejects as unsatisfiable or duplicate is
  ## dropped rather than raised, which keeps one bad constraint from taking
  ## down a frame.
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
  ## Create a box with the numeric id `id` and register it with the layout.
  ui.initBox(WidgetID(id), $id, width, height)

proc box*(ui: Layout, id: string, width = fill(), height = fill()): Widget =
  ## Create a box with a fresh widget id, labelled `id` for debugging.
  ui.initBox(nextWidgetID(), id, width, height)

proc root*(ui: Layout, box: Widget) =
  ## Make `box` the layout's root, pinning it to the origin.
  ##
  ## The root's size is what `resize` suggests, so it must be set before the
  ## first resize.
  ui.rootBox = box
  discard ui.constrain(box.x == 0.0)
  discard ui.constrain(box.y == 0.0)
  ui.solver[box.w] = WindowResizeStrength
  ui.solver[box.h] = WindowResizeStrength

proc resize*(ui: Layout, width, height: float64) =
  ## Suggest a new size for the root box, normally the window size.
  ##
  ## Negative values are clamped to zero. Raises `ValueError` when no root
  ## has been set yet.
  if ui.rootBox.w.isNil or ui.rootBox.h.isNil:
    raise newException(ValueError, "layout root must be set before resize")

  ui.solver.suggest(ui.rootBox.w, max(width, 0.0))
  ui.solver.suggest(ui.rootBox.h, max(height, 0.0))

proc solve*(ui: Layout): bool {.discardable.} =
  ## Solve the layout and report whether it succeeded.
  ##
  ## Returns false, leaving the previous solution in place, when the
  ## constraints turned out to be unsatisfiable.
  try:
    ui.solver.update()
    result = true
  except InternalSolverError, UnsatisfiableConstraintError:
    result = false

proc add*(group: var ConstraintGroup, constraint: Constraint) =
  ## Append `constraint` to the group.
  group.constraints.add constraint

template collect*(ui: Layout, body: untyped): ConstraintGroup =
  ## Collect the constraints created in `body` into a `ConstraintGroup`.
  ##
  ## Inside `body`, pass each constraint to the injected `keep` template.
  ## The group can later be handed to `remove` to retract them all at once.
  block:
    var collected {.gensym.}: ConstraintGroup
    template keep(constraint: Constraint) =
      collected.add constraint

    body
    collected

proc remove*(ui: Layout, group: ConstraintGroup) =
  ## Retract every constraint in `group` from the solver.
  for constraint in group.constraints:
    ui.solver.remove constraint

proc pin*(ui: Layout, child, parent: Widget, inset = 0.0) =
  ## Constrain `child` to fill `parent`, leaving `inset` pixels on each side.
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
  ## Stack `children` on top of each other inside `parent`.
  ##
  ## Every child gets the same box: the parent's area less its padding, with
  ## `alignItems` and `justifyContent` deciding how a child that does not
  ## stretch is placed within it. A child's own `alignSelf` overrides
  ## `alignItems`.
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
  ## Lay `children` out left to right inside `parent`.
  ##
  ## `gap` separates neighbours and the padding arguments inset the content;
  ## a per-edge padding argument overrides `padding`. `alignItems` places
  ## the children on the cross axis and `justifyContent` distributes any
  ## leftover space along the row, both of which a child can override with
  ## its own `alignSelf`. `scrollX` and `scrollY` mark the row as scrollable,
  ## so it may size its content past the parent's bounds. Does nothing for an
  ## empty `children`.
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
  ## Lay `children` out top to bottom inside `parent`.
  ##
  ## `gap` separates neighbours and the padding arguments inset the content;
  ## a per-edge padding argument overrides `padding`. `alignItems` places
  ## the children on the cross axis and `justifyContent` distributes any
  ## leftover space along the column, both of which a child can override
  ## with its own `alignSelf`. `scrollX` and `scrollY` mark the column as
  ## scrollable, so it may size its content past the parent's bounds. Does
  ## nothing for an empty `children`.
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
  ## Constrain `a`'s left edge to `b`'s, plus `offset`.
  discard ui.constrain(a.left == b.left + offset)

proc alignRight*(ui: Layout, a, b: Widget, offset = 0.0) =
  ## Constrain `a`'s right edge to `b`'s, plus `offset`.
  discard ui.constrain(a.right == b.right + offset)

proc alignTop*(ui: Layout, a, b: Widget, offset = 0.0) =
  ## Constrain `a`'s top edge to `b`'s, plus `offset`.
  discard ui.constrain(a.top == b.top + offset)

proc alignBottom*(ui: Layout, a, b: Widget, offset = 0.0) =
  ## Constrain `a`'s bottom edge to `b`'s, plus `offset`.
  discard ui.constrain(a.bottom == b.bottom + offset)

proc alignCenterX*(ui: Layout, a, b: Widget, offset = 0.0) =
  ## Constrain `a`'s horizontal centre to `b`'s, plus `offset`.
  discard ui.constrain(a.centerX == b.centerX + offset)

proc alignCenterY*(ui: Layout, a, b: Widget, offset = 0.0) =
  ## Constrain `a`'s vertical centre to `b`'s, plus `offset`.
  discard ui.constrain(a.centerY == b.centerY + offset)

proc after*(ui: Layout, a, b: Widget, gap = 0.0) =
  ## Place `a` immediately to the right of `b`, `gap` pixels apart.
  discard ui.constrain(a.left == b.right + gap)

proc below*(ui: Layout, a, b: Widget, gap = 0.0) =
  ## Place `a` immediately below `b`, `gap` pixels apart.
  discard ui.constrain(a.top == b.bottom + gap)

proc equalWidth*(ui: Layout, boxes: varargs[Widget]) =
  ## Constrain every box in `boxes` to the same width. Needs at least two.
  if boxes.len < 2:
    return

  for i in 1 ..< boxes.len:
    discard ui.constrain(boxes[i].width == boxes[0].width)

proc equalHeight*(ui: Layout, boxes: varargs[Widget]) =
  ## Constrain every box in `boxes` to the same height. Needs at least two.
  if boxes.len < 2:
    return

  for i in 1 ..< boxes.len:
    discard ui.constrain(boxes[i].height == boxes[0].height)
