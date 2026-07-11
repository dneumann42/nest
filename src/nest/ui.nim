import std/sets

import layouts, components, widgets2
export layouts, components

type
  ComponentWidget = tuple[component: Component, widget: Widget]
  WidgetSlot* = seq[Widget]
  LayoutKind = enum
    RowLayout
    ColumnLayout

  UIPhase = enum
    LayoutPhase
    EventPhase

  LayoutFrame = object
    parent: Widget
    children: seq[Widget]

  PendingLayout = object
    kind: LayoutKind
    parent: Widget
    children: seq[Widget]
    gap, padding: float64
    alignItems: Alignment
    justifyContent: Justification

  UI* = object
    layout*: Layout
    root*, parent*: Widget
    frames*: seq[LayoutFrame]
    childrenWidgets*: seq[Widget]
    components*: seq[ComponentWidget]
    pendingLayouts: seq[PendingLayout]
    phase: UIPhase

proc init*(T: typedesc[UI]): T =
  var ui = newLayout()
  result = T(layout: ui, root: ui.box(nextWidgetID(), width = fill(), height = fill()))

proc reset*(self: var UI) =
  let rootID =
    if self.root.id == InvalidWidgetID:
      nextWidgetID()
    else:
      self.root.id
  self.layout = newLayout()
  self.root = self.layout.box(rootID, width = fill(), height = fill())
  self.parent = self.root
  self.frames.setLen(0)
  self.childrenWidgets.setLen(0)
  self.components.setLen(0)
  self.pendingLayouts.setLen(0)
  self.phase = LayoutPhase

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
      justifyContent: JustifyStart,
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
        justifyContent = pending.justifyContent,
      )
    of ColumnLayout:
      self.layout.column(
        pending.parent,
        pending.children,
        gap = pending.gap,
        padding = pending.padding,
        alignItems = pending.alignItems,
        justifyContent = pending.justifyContent,
      )
    self.layout.solve()

  self.layout.solve()

proc addChild(self: var UI, child: Widget) =
  if self.frames.len == 0:
    self.childrenWidgets.add(child)
  else:
    self.frames[^1].children.add(child)

proc addChildren(self: var UI, children: openArray[Widget]) =
  for child in children:
    self.addChild(child)

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

template slot*(self: var UI, body: untyped): WidgetSlot =
  block:
    if self.phase == EventPhase:
      body
      WidgetSlot(@[])
    else:
      self.frames.add LayoutFrame(parent: self.currentParent())
      body
      let captured {.gensym.} = self.frames[^1].children
      self.frames.setLen(self.frames.len - 1)
      self.parent = self.currentParent()
      captured

template singleSlot*(self: var UI, body: untyped): Widget =
  block:
    let captured {.gensym.} = self.slot:
      body
    if captured.len != 1:
      raise newException(
        ValueError, "expected exactly one widget in slot, got " & $captured.len
      )
    captured[0]

proc place*(self: var UI, slot: WidgetSlot) =
  if self.phase == EventPhase:
    return
  self.addChildren(slot)

proc place*(self: var UI, widget: Widget) =
  if self.phase == EventPhase:
    return
  self.addChild(widget)

proc attach*(self: var UI, widget: Widget, component: Component) =
  if self.phase == EventPhase:
    return
  self.components.add((component, widget))

template events*(self: var UI, body: untyped) =
  if self.phase == EventPhase:
    body

template layout*(
    ui: var UI,
    updateContext: var UpdateContext,
    drawContext: var DrawContext,
    blk: untyped,
): auto =
  ui.phase = EventPhase
  blk

  ui.phase = LayoutPhase
  ui.beginLayout(drawContext.windowWidth, drawContext.windowHeight)
  blk
  ui.endLayout()
  updateContext.hotWidgets.clear()
  updateContext.activeWidgets.clear()
  ui.update(updateContext)
  switchState(updateContext, drawContext)
  ui.draw(drawContext)
  ui.reset()

proc update*(self: UI, context: var UpdateContext) =
  for (component, widget) in self.components:
    component.update(widget, context)

proc draw*(self: UI, context: DrawContext) =
  for (component, widget) in self.components:
    component.draw(widget, context)

proc row*(
    self: var UI,
    gap = 0.0,
    padding = 0.0,
    alignItems = AlignStretch,
    justifyContent = JustifyStart,
) =
  if self.phase == EventPhase:
    return
  let components = self.takeChildren()
  self.pendingLayouts.add PendingLayout(
    kind: RowLayout,
    parent: self.currentParent(),
    children: components,
    gap: gap,
    padding: padding,
    alignItems: alignItems,
    justifyContent: justifyContent,
  )

proc column*(
    self: var UI,
    gap = 0.0,
    padding = 0.0,
    alignItems = AlignStretch,
    justifyContent = JustifyStart,
) =
  if self.phase == EventPhase:
    return
  let components = self.takeChildren()
  self.pendingLayouts.add PendingLayout(
    kind: ColumnLayout,
    parent: self.currentParent(),
    children: components,
    gap: gap,
    padding: padding,
    alignItems: alignItems,
    justifyContent: justifyContent,
  )

template row*(self: var UI, gp = 0.0, pad = 0.0, body: untyped) =
  block:
    if self.phase == EventPhase:
      body
    else:
      body
      self.row(gp, pad)

template rowJustified*(
    self: var UI,
    gp: float64,
    pad: float64,
    justifyContent: Justification,
    body: untyped,
) =
  block:
    if self.phase == EventPhase:
      body
    else:
      body
      self.row(gp, pad, justifyContent = justifyContent)

template rowAligned*(
    self: var UI, gp = 0.0, pad = 0.0, alignItems: Alignment, body: untyped
) =
  block:
    if self.phase == EventPhase:
      body
    else:
      body
      self.row(gp, pad, alignItems)

template rowAlignedJustified*(
    self: var UI,
    gp: float64,
    pad: float64,
    alignItems: Alignment,
    justifyContent: Justification,
    body: untyped,
) =
  block:
    if self.phase == EventPhase:
      body
    else:
      body
      self.row(gp, pad, alignItems, justifyContent)

template column*(self: var UI, gp = 0.0, pad = 0.0, body: untyped) =
  block:
    if self.phase == EventPhase:
      body
    else:
      body
      self.column(gp, pad)

template columnJustified*(
    self: var UI,
    gp: float64,
    pad: float64,
    justifyContent: Justification,
    body: untyped,
) =
  block:
    if self.phase == EventPhase:
      body
    else:
      body
      self.column(gp, pad, justifyContent = justifyContent)

template columnAligned*(
    self: var UI, gp = 0.0, pad = 0.0, alignItems: Alignment, body: untyped
) =
  block:
    if self.phase == EventPhase:
      body
    else:
      body
      self.column(gp, pad, alignItems)

template columnAlignedJustified*(
    self: var UI,
    gp: float64,
    pad: float64,
    alignItems: Alignment,
    justifyContent: Justification,
    body: untyped,
) =
  block:
    if self.phase == EventPhase:
      body
    else:
      body
      self.column(gp, pad, alignItems, justifyContent)

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
    if self.phase == EventPhase:
      body
    else:
      let layoutParent = self.box(id, width = w, height = h)
      self.pushLayout(layoutParent)
      body
      self.row(gp, pad)
      discard self.popLayout()

template rowJustified*(
    self: var UI,
    id: WidgetID,
    w: SizePolicy,
    h: SizePolicy,
    gp: float64,
    pad: float64,
    justifyContent: Justification,
    body: untyped,
) =
  block:
    if self.phase == EventPhase:
      body
    else:
      let layoutParent = self.box(id, width = w, height = h)
      self.pushLayout(layoutParent)
      body
      self.row(gp, pad, justifyContent = justifyContent)
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
    if self.phase == EventPhase:
      body
    else:
      let layoutParent = self.box(id, width = w, height = h)
      self.pushLayout(layoutParent)
      body
      self.row(gp, pad, alignItems)
      discard self.popLayout()

template rowAlignedJustified*(
    self: var UI,
    id: WidgetID,
    w: SizePolicy,
    h: SizePolicy,
    gp: float64,
    pad: float64,
    alignItems: Alignment,
    justifyContent: Justification,
    body: untyped,
) =
  block:
    if self.phase == EventPhase:
      body
    else:
      let layoutParent = self.box(id, width = w, height = h)
      self.pushLayout(layoutParent)
      body
      self.row(gp, pad, alignItems, justifyContent)
      discard self.popLayout()

template rowAligned*(
    self: var UI, id: WidgetID, w, h: SizePolicy, alignItems: Alignment, body: untyped
) =
  block:
    if self.phase == EventPhase:
      body
    else:
      let layoutParent = self.box(id, width = w, height = h)
      self.pushLayout(layoutParent)
      body
      self.row(0.0, 0.0, alignItems)
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
    if self.phase == EventPhase:
      body
    else:
      let layoutParent = self.box(id, width = w, height = h)
      self.pushLayout(layoutParent)
      body
      self.column(gp, pad)
      discard self.popLayout()

template columnJustified*(
    self: var UI,
    id: WidgetID,
    w: SizePolicy,
    h: SizePolicy,
    gp: float64,
    pad: float64,
    justifyContent: Justification,
    body: untyped,
) =
  block:
    if self.phase == EventPhase:
      body
    else:
      let layoutParent = self.box(id, width = w, height = h)
      self.pushLayout(layoutParent)
      body
      self.column(gp, pad, justifyContent = justifyContent)
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
    if self.phase == EventPhase:
      body
    else:
      let layoutParent = self.box(id, width = w, height = h)
      self.pushLayout(layoutParent)
      body
      self.column(gp, pad, alignItems)
      discard self.popLayout()

template columnAlignedJustified*(
    self: var UI,
    id: WidgetID,
    w: SizePolicy,
    h: SizePolicy,
    gp: float64,
    pad: float64,
    alignItems: Alignment,
    justifyContent: Justification,
    body: untyped,
) =
  block:
    if self.phase == EventPhase:
      body
    else:
      let layoutParent = self.box(id, width = w, height = h)
      self.pushLayout(layoutParent)
      body
      self.column(gp, pad, alignItems, justifyContent)
      discard self.popLayout()

template columnAligned*(
    self: var UI, id: WidgetID, w, h: SizePolicy, alignItems: Alignment, body: untyped
) =
  block:
    if self.phase == EventPhase:
      body
    else:
      let layoutParent = self.box(id, width = w, height = h)
      self.pushLayout(layoutParent)
      body
      self.column(0.0, 0.0, alignItems)
      discard self.popLayout()

template center*(self: var UI, id: WidgetID, w = fill(), h = fill(), body: untyped) =
  block:
    if self.phase == EventPhase:
      body
    else:
      let layoutParent = self.box(id, width = w, height = h)
      self.pushLayout(layoutParent)
      body
      let captured = self.takeChildren()
      if captured.len != 1:
        raise newException(
          ValueError, "expected exactly one centered widget, got " & $captured.len
        )
      let child = captured[0]
      discard self.layout.constrain(child.left >= layoutParent.left)
      discard self.layout.constrain(child.top >= layoutParent.top)
      discard self.layout.constrain(child.right <= layoutParent.right)
      discard self.layout.constrain(child.bottom <= layoutParent.bottom)
      self.layout.alignCenterX(child, layoutParent)
      self.layout.alignCenterY(child, layoutParent)
      discard self.popLayout()

template panel*(
    self: var UI,
    id: WidgetID,
    w = fill(),
    h = fill(),
    gp = 0.0,
    pad = 0.0,
    alignItems = AlignStretch,
    body: untyped,
) =
  block:
    if self.phase == EventPhase:
      body
    else:
      let layoutParent = self.box(id, width = w, height = h)
      let component = Panel.new()
      self.attach(layoutParent, Component(component))
      self.pushLayout(layoutParent)
      body
      self.column(gp, pad, alignItems)
      discard self.popLayout()

template panelJustified*(
    self: var UI,
    id: WidgetID,
    w: SizePolicy,
    h: SizePolicy,
    gp: float64,
    pad: float64,
    alignItems: Alignment,
    justifyContent: Justification,
    body: untyped,
) =
  block:
    if self.phase == EventPhase:
      body
    else:
      let layoutParent = self.box(id, width = w, height = h)
      let component = Panel.new()
      self.attach(layoutParent, Component(component))
      self.pushLayout(layoutParent)
      body
      self.column(gp, pad, alignItems, justifyContent)
      discard self.popLayout()

proc box*(
    self: var UI, id: WidgetID, width, height: SizePolicy, alignSelf = AlignAuto
): Widget =
  self.layout.box(id, width = width, height = height).withAlignSelf(alignSelf)

proc container*(
    self: var UI,
    id: WidgetID,
    component: Container,
    width, height: SizePolicy,
    alignSelf = AlignAuto,
): Widget {.discardable.} =
  if self.phase == EventPhase:
    return
  result = self.box(id, width = width, height = height, alignSelf = alignSelf)
  self.attach(result, Component(component))
  self.addChild(result)

proc spacer*(
    self: var UI, id: WidgetID, width, height: SizePolicy, alignSelf = AlignAuto
): Widget {.discardable.} =
  if self.phase == EventPhase:
    return
  result = self.box(id, width = width, height = height, alignSelf = alignSelf)
  self.addChild(result)

proc button*(
    ui: var UI,
    id: WidgetID,
    label: string,
    width, height: SizePolicy,
    alignSelf = AlignAuto,
) =
  if ui.phase == EventPhase:
    return
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  let btn = Button.new(label)
  ui.attach(box, Component(btn))
  ui.addChild(box)

proc label*(
    ui: var UI,
    id: WidgetID,
    text: string,
    width, height: SizePolicy,
    alignSelf = AlignAuto,
) =
  if ui.phase == EventPhase:
    return
  let box = ui.box(id, width = width, height = height, alignSelf = alignSelf)
  let lbl = Label.new(text)
  ui.attach(box, Component(lbl))
  ui.addChild(box)
