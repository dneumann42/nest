import layouts, components, widgets2
export layouts

type
  ComponentWidget = tuple[component: Component, widget: Widget]
  LayoutKind = enum
    RowLayout
    ColumnLayout

  LayoutFrame = object
    parent: Widget
    children: seq[Widget]

  PendingLayout = object
    kind: LayoutKind
    parent: Widget
    children: seq[Widget]
    gap, padding: float64
    alignItems: Alignment

  UI* = object
    layout*: Layout
    root*, parent*: Widget
    frames*: seq[LayoutFrame]
    childrenWidgets*: seq[Widget]
    components*: seq[ComponentWidget]
    pendingLayouts: seq[PendingLayout]

proc init*(T: typedesc[UI]): T =
  var ui = newLayout()
  result = T(layout: ui, root: ui.box(nextWidgetID(), width = fill(), height = fill()))

proc beginLayout*(self: var UI, windowWidth, windowHeight: int) =
  self.layout.root(self.root)
  self.parent = self.root
  self.frames = @[LayoutFrame(parent: self.root)]
  self.childrenWidgets.setLen(0)
  self.pendingLayouts.setLen(0)
  self.layout.resize(windowWidth.toFloat, windowHeight.toFloat)

proc endLayout*(self: var UI) =
  if self.frames.len == 1 and self.frames[0].children.len > 0:
    let children = self.frames[0].children
    self.pendingLayouts.add PendingLayout(
      kind: ColumnLayout,
      parent: self.root,
      children: children,
      gap: 0.0,
      padding: 0.0,
      alignItems: AlignStretch,
    )
    self.frames[0].children.setLen(0)

  for i in countdown(self.pendingLayouts.high, 0):
    let pending = self.pendingLayouts[i]
    case pending.kind
    of RowLayout:
      self.layout.row(
        pending.parent,
        pending.children,
        gap = pending.gap,
        padding = pending.padding,
        alignItems = pending.alignItems,
      )
    of ColumnLayout:
      self.layout.column(
        pending.parent,
        pending.children,
        gap = pending.gap,
        padding = pending.padding,
        alignItems = pending.alignItems,
      )
    self.layout.solve()

  self.layout.solve()

proc addChild(self: var UI, child: Widget) =
  if self.frames.len == 0:
    self.childrenWidgets.add(child)
  else:
    self.frames[^1].children.add(child)

proc currentParent(self: UI): Widget =
  if self.frames.len == 0:
    self.parent
  else:
    self.frames[^1].parent

proc takeChildren(self: var UI): seq[Widget] =
  if self.frames.len == 0:
    result = self.childrenWidgets
    self.childrenWidgets.setLen(0)
  else:
    result = self.frames[^1].children
    self.frames[^1].children.setLen(0)

proc pushLayout(self: var UI, parent: Widget) =
  self.frames.add LayoutFrame(parent: parent)
  self.parent = parent

proc popLayout(self: var UI): Widget =
  result = self.frames[^1].parent
  self.frames.setLen(self.frames.len - 1)
  self.parent = self.currentParent()
  self.addChild(result)

proc update*(self: UI, context: UpdateContext) =
  for (component, widget) in self.components:
    component.update(widget, context)

proc draw*(self: UI, context: DrawContext) =
  for (component, widget) in self.components:
    component.draw(widget, context)

proc row*(self: var UI, gap = 0.0, padding = 0.0, alignItems = AlignStretch) =
  let components = self.takeChildren()
  self.pendingLayouts.add PendingLayout(
    kind: RowLayout,
    parent: self.currentParent(),
    children: components,
    gap: gap,
    padding: padding,
    alignItems: alignItems,
  )

proc column*(self: var UI, gap = 0.0, padding = 0.0, alignItems = AlignStretch) =
  let components = self.takeChildren()
  self.pendingLayouts.add PendingLayout(
    kind: ColumnLayout,
    parent: self.currentParent(),
    children: components,
    gap: gap,
    padding: padding,
    alignItems: alignItems,
  )

template row*(self: var UI, gp = 0.0, pad = 0.0, body: untyped) =
  block:
    body
    self.row(gp, pad)

template rowAligned*(self: var UI, gp = 0.0, pad = 0.0, alignItems: Alignment, body: untyped) =
  block:
    body
    self.row(gp, pad, alignItems)

template column*(self: var UI, gp = 0.0, pad = 0.0, body: untyped) =
  block:
    body
    self.column(gp, pad)

template columnAligned*(
    self: var UI, gp = 0.0, pad = 0.0, alignItems: Alignment, body: untyped
) =
  block:
    body
    self.column(gp, pad, alignItems)

template row*(
    self: var UI,
    id: WidgetID,
    w = fill(),
    h = fill(),
    gp = 0.0,
    pad = 0.0,
    body: untyped,
) =
  block:
    let layoutParent = self.box(id, width = w, height = h)
    self.pushLayout(layoutParent)
    body
    self.row(gp, pad)
    discard self.popLayout()

template rowAligned*(
    self: var UI,
    id: WidgetID,
    w = fill(),
    h = fill(),
    gp = 0.0,
    pad = 0.0,
    alignItems: Alignment,
    body: untyped,
) =
  block:
    let layoutParent = self.box(id, width = w, height = h)
    self.pushLayout(layoutParent)
    body
    self.row(gp, pad, alignItems)
    discard self.popLayout()

template column*(
    self: var UI,
    id: WidgetID,
    w = fill(),
    h = fill(),
    gp = 0.0,
    pad = 0.0,
    body: untyped,
) =
  block:
    let layoutParent = self.box(id, width = w, height = h)
    self.pushLayout(layoutParent)
    body
    self.column(gp, pad)
    discard self.popLayout()

template columnAligned*(
    self: var UI,
    id: WidgetID,
    w = fill(),
    h = fill(),
    gp = 0.0,
    pad = 0.0,
    alignItems: Alignment,
    body: untyped,
) =
  block:
    let layoutParent = self.box(id, width = w, height = h)
    self.pushLayout(layoutParent)
    body
    self.column(gp, pad, alignItems)
    discard self.popLayout()

proc box*(
    self: var UI, id: WidgetID, width, height: SizePolicy, alignSelf = AlignAuto
): Widget =
  self.layout.box(id, width = width, height = height).withAlignSelf(alignSelf)

proc spacer*(
    self: var UI, id: WidgetID, width, height: SizePolicy, alignSelf = AlignAuto
): Widget {.discardable.} =
  result = self.box(id, width = width, height = height, alignSelf = alignSelf)
  self.addChild(result)

proc button*(
    ui: var UI,
    id: WidgetID,
    label: string,
    width,
    height: SizePolicy,
    alignSelf = AlignAuto,
) =
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  let btn = Button.new(label)
  ui.components.add((Component(btn), box))
  ui.addChild(box)
