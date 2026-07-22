import std/[math, strutils]

import ../[resources, widgets2]
import component
import nest/[coords, screen]

const
  EditorPaddingX* = 8
  EditorPaddingY* = 4
  EditorMinWidth* = 80
  EditorMinHeight* = 28

type
  EditorScrollAxis = enum
    NoEditorScroll
    EditorScrollX
    EditorScrollY

  EditorCursor* = object
    index*: int

  EditorState* = ref object
    text*: string
    cursor*: int
    preferredColumn*: int
    scrollX*, scrollY*: float64
    targetX*, targetY*: float64
    maxX*, maxY*: float64
    contentWidth*, contentHeight*: float64
    dragging*: EditorScrollAxis
    dragStartMouse*: float64
    dragStartScroll*: float64
    ensureCursorVisible*: bool

  Editor* = ref object of Interactive
    state*: EditorState
    fontName*: string
    singleLine*: bool
    lineNumbers*: bool
    scrollbars*: bool

proc new*(T: typedesc[EditorState], text = ""): T =
  T(text: text, cursor: text.len, preferredColumn: -1)

proc clampCursor*(state: EditorState) =
  state.cursor = clamp(state.cursor, 0, state.text.len)

proc new*(
    T: typedesc[Editor],
    state: EditorState,
    fontName = "font",
    singleLine = false,
    lineNumbers = false,
    scrollbars = true,
): T =
  state.clampCursor()
  T(
    state: state,
    fontName: fontName,
    singleLine: singleLine,
    lineNumbers: lineNumbers and not singleLine,
    scrollbars: scrollbars and not singleLine,
  )

proc lineStart(text: string, index: int): int =
  result = clamp(index, 0, text.len)
  while result > 0 and text[result - 1] != '\n':
    dec result

proc lineEnd(text: string, index: int): int =
  result = clamp(index, 0, text.len)
  while result < text.len and text[result] != '\n':
    inc result

proc cursorColumn(state: EditorState): int =
  state.cursor - state.text.lineStart(state.cursor)

proc lineBoundsAt(text: string, index: int): tuple[start, stop: int] =
  result.start = text.lineStart(index)
  result.stop = text.lineEnd(index)

proc previousLineCursor(state: EditorState): int =
  let current = state.text.lineBoundsAt(state.cursor)
  if current.start == 0:
    return state.cursor
  let previousEnd = current.start - 1
  let previousStart = state.text.lineStart(previousEnd)
  let column =
    if state.preferredColumn >= 0:
      state.preferredColumn
    else:
      state.cursorColumn()
  previousStart + min(column, previousEnd - previousStart)

proc nextLineCursor(state: EditorState): int =
  let current = state.text.lineBoundsAt(state.cursor)
  if current.stop >= state.text.len:
    return state.cursor
  let nextStart = current.stop + 1
  let nextEnd = state.text.lineEnd(nextStart)
  let column =
    if state.preferredColumn >= 0:
      state.preferredColumn
    else:
      state.cursorColumn()
  nextStart + min(column, nextEnd - nextStart)

proc resetPreferredColumn(state: EditorState) =
  state.preferredColumn = -1

proc insertText*(state: EditorState, text: string, singleLine = false) =
  state.clampCursor()
  let inserted =
    if singleLine:
      text.replace("\n", "").replace("\r", "")
    else:
      text.replace("\r\n", "\n").replace("\r", "\n")
  if inserted.len == 0:
    return
  state.text.insert(inserted, state.cursor)
  inc state.cursor, inserted.len
  state.resetPreferredColumn()

proc deleteBackward*(state: EditorState) =
  state.clampCursor()
  if state.cursor > 0:
    state.text.delete(state.cursor - 1 .. state.cursor - 1)
    dec state.cursor
    state.resetPreferredColumn()

proc deleteForward*(state: EditorState) =
  state.clampCursor()
  if state.cursor < state.text.len:
    state.text.delete(state.cursor .. state.cursor)
    state.resetPreferredColumn()

proc killToStart*(state: EditorState) =
  state.clampCursor()
  let start = state.text.lineStart(state.cursor)
  if state.cursor > start:
    state.text.delete(start .. state.cursor - 1)
    state.cursor = start
    state.resetPreferredColumn()

proc killToEnd*(state: EditorState) =
  state.clampCursor()
  let stop = state.text.lineEnd(state.cursor)
  if state.cursor < stop:
    state.text.delete(state.cursor .. stop - 1)
    state.resetPreferredColumn()

proc handleKey*(state: EditorState, input: KeyInput, widget: Widget,
    ctx: var UpdateContext, singleLine = false) =
  let ctrl = CtrlPressed in input.mods
  case input.key
  of KeyEsc:
    ctx.clearFocus()
  of KeyEnter:
    if singleLine:
      ctx.submit(widget.id)
      ctx.clearFocus()
    else:
      state.insertText("\n")
  of KeyLeft:
    if state.cursor > 0:
      dec state.cursor
      state.resetPreferredColumn()
  of KeyRight:
    if state.cursor < state.text.len:
      inc state.cursor
      state.resetPreferredColumn()
  of KeyUp:
    state.preferredColumn =
      if state.preferredColumn >= 0: state.preferredColumn else: state.cursorColumn()
    state.cursor = state.previousLineCursor()
  of KeyDown:
    state.preferredColumn =
      if state.preferredColumn >= 0: state.preferredColumn else: state.cursorColumn()
    state.cursor = state.nextLineCursor()
  of KeyHome:
    state.cursor = state.text.lineStart(state.cursor)
    state.resetPreferredColumn()
  of KeyEnd:
    state.cursor = state.text.lineEnd(state.cursor)
    state.resetPreferredColumn()
  of KeyBackspace:
    state.deleteBackward()
  of KeyDelete:
    state.deleteForward()
  of KeyA:
    if ctrl:
      state.cursor = state.text.lineStart(state.cursor)
      state.resetPreferredColumn()
  of KeyE:
    if ctrl:
      state.cursor = state.text.lineEnd(state.cursor)
      state.resetPreferredColumn()
  of KeyB:
    if ctrl and state.cursor > 0:
      dec state.cursor
      state.resetPreferredColumn()
  of KeyF:
    if ctrl and state.cursor < state.text.len:
      inc state.cursor
      state.resetPreferredColumn()
  of KeyD:
    if ctrl:
      state.deleteForward()
  of KeyH:
    if ctrl:
      state.deleteBackward()
  of KeyK:
    if ctrl:
      state.killToEnd()
  of KeyU:
    if ctrl:
      state.killToStart()
  else:
    discard

proc frameContains(f: Frame, x, y: int): bool =
  x.float64 >= f.x and x.float64 < f.x + f.width and
    y.float64 >= f.y and y.float64 < f.y + f.height

proc editorScrollWheelStep(): float64 =
  42.0

proc editorScrollLerpFactor(): float64 =
  0.35

proc editorSnapBackLerpFactor(): float64 =
  0.22

proc editorScrollbarSize(): float64 =
  10.0

proc editorOverscrollLimit(viewport: float64): float64 =
  min(72.0, max(viewport * 0.35, 16.0))

proc editorSnapTarget(value, lo, hi: float64): float64 =
  let target = value.clamp(lo, hi)
  result = value.lerp(target, editorSnapBackLerpFactor())
  if abs(result - target) < 0.25:
    result = target

proc expandTabs(text: string): string =
  text.replace("\t", "    ")

proc nearlyEqual(a, b: float64): bool =
  abs(a - b) < 0.5

proc contains(frame: Frame, x, y: int): bool =
  x.toFloat >= frame.x and x.toFloat < frame.x + frame.width and y.toFloat >= frame.y and
    y.toFloat < frame.y + frame.height

proc horizontalTrack(f: Frame): Frame =
  Frame(
    x: f.x,
    y: f.y + max(f.height - editorScrollbarSize(), 0.0),
    width: max(f.width - editorScrollbarSize(), 0.0),
    height: min(editorScrollbarSize(), f.height),
  )

proc verticalTrack(f: Frame): Frame =
  Frame(
    x: f.x + max(f.width - editorScrollbarSize(), 0.0),
    y: f.y,
    width: min(editorScrollbarSize(), f.width),
    height: max(f.height - editorScrollbarSize(), 0.0),
  )

proc horizontalThumb(f: Frame, state: EditorState): Frame =
  let track = horizontalTrack(f)
  if state.maxX <= 0 or track.width <= 0:
    return Frame(x: track.x, y: track.y, width: track.width, height: track.height)
  let contentWidth = state.maxX + f.width
  let thumbWidth = max(24.0, track.width * min(f.width / contentWidth, 1.0))
  let travel = max(track.width - thumbWidth, 0.0)
  Frame(
    x: track.x + travel * (state.scrollX / state.maxX),
    y: track.y,
    width: thumbWidth,
    height: track.height,
  )

proc verticalThumb(f: Frame, state: EditorState): Frame =
  let track = verticalTrack(f)
  if state.maxY <= 0 or track.height <= 0:
    return Frame(x: track.x, y: track.y, width: track.width, height: track.height)
  let contentHeight = state.maxY + f.height
  let thumbHeight = max(24.0, track.height * min(f.height / contentHeight, 1.0))
  let travel = max(track.height - thumbHeight, 0.0)
  Frame(
    x: track.x,
    y: track.y + travel * (state.scrollY / state.maxY),
    width: track.width,
    height: thumbHeight,
  )

proc editorLineNumberWidth(
    self: Editor, resources: Resources, lineCount: int
): int =
  if not self.lineNumbers:
    return 0
  let digits = max(2, ($max(lineCount, 1)).len)
  resources.measureText(self.fontName, repeat("9", digits)).width + EditorPaddingX * 2

proc editorLines(text: string): seq[string] =
  result = text.split('\n')
  if result.len == 0:
    result = @[""]

proc editorContentSize(
    self: Editor, resources: Resources
): tuple[width, height: float64] =
  let lines =
    if self.singleLine:
      @[self.state.text]
    else:
      editorLines(self.state.text)
  var width = 0
  var height = 0
  let (_, metrics) = resources.get(self.fontName)
  for line in lines:
    let measurement = resources.measureText(self.fontName, line.expandTabs)
    width = max(width, measurement.width)
    height += max(metrics.lineHeight, measurement.height)
  width += self.editorLineNumberWidth(resources, lines.len)
  (
    max(width + EditorPaddingX * 2, EditorMinWidth).toFloat,
    max(height + EditorPaddingY * 2, EditorMinHeight).toFloat,
  )

proc columnAtContentX(resources: Resources, fontName, line: string, x: float64): int =
  if x <= 0:
    return 0
  var previousWidth = 0
  for column in 1 .. line.len:
    let width = resources.measureText(fontName, line[0 ..< column].expandTabs).width
    if x < (previousWidth + width).toFloat / 2.0:
      return column - 1
    previousWidth = width
  line.len

proc cursorAtMouse(
    self: Editor, resources: Resources, f: Frame, mouseX, mouseY: int
): int =
  let
    (_, metrics) = resources.get(self.fontName)
    lineHeight = max(metrics.lineHeight, resources.measureText(self.fontName, "M").height)
    lines =
      if self.singleLine:
        @[self.state.text]
      else:
        editorLines(self.state.text)
    gutterWidth = self.editorLineNumberWidth(resources, lines.len)
    textLeft = f.x.toInt + EditorPaddingX + gutterWidth
    textTop = f.y.toInt + EditorPaddingY
    contentY = mouseY.toFloat - textTop.toFloat + self.state.scrollY
    lineIndex = floor(contentY / lineHeight.toFloat).toInt.clamp(0, lines.len - 1)
    contentX = mouseX.toFloat - textLeft.toFloat + self.state.scrollX
    column = resources.columnAtContentX(self.fontName, lines[lineIndex], contentX)

  for index in 0 ..< lineIndex:
    result += lines[index].len
    if not self.singleLine:
      inc result
  result + column

proc updateScrollBounds(state: EditorState, f: Frame) =
  state.maxX = max(state.contentWidth - f.width, 0.0)
  state.maxY = max(state.contentHeight - f.height, 0.0)
  let
    overscrollX = editorOverscrollLimit(f.width)
    overscrollY = editorOverscrollLimit(f.height)
  state.targetX = state.targetX.clamp(-overscrollX, state.maxX + overscrollX)
  state.targetY = state.targetY.clamp(-overscrollY, state.maxY + overscrollY)
  if state.dragging != EditorScrollX:
    state.targetX = state.targetX.editorSnapTarget(0.0, state.maxX)
  if state.dragging != EditorScrollY:
    state.targetY = state.targetY.editorSnapTarget(0.0, state.maxY)
  if state.maxX <= 0 and state.dragging == EditorScrollX:
    state.dragging = NoEditorScroll
  if state.maxY <= 0 and state.dragging == EditorScrollY:
    state.dragging = NoEditorScroll

method update*(self: Editor, widget: Widget, ctx: var UpdateContext) =
  let isHot = widget.frame.frameContains(ctx.mouseX, ctx.mouseY)
  let handlesWheel = isHot or ctx.focused(widget.id)
  let f = widget.frame
  var clickedScrollbar = false
  if not self.singleLine and ctx.resources.ready:
    let (contentWidth, contentHeight) = self.editorContentSize(ctx.resources)
    self.state.contentWidth = contentWidth
    self.state.contentHeight = contentHeight
  self.state.updateScrollBounds(f)
  if isHot:
    ctx.setHot(widget.id)
  if handlesWheel and not self.singleLine:
    let
      overscrollX = editorOverscrollLimit(f.width)
      overscrollY = editorOverscrollLimit(f.height)
    if ctx.mouseWheelY != 0 and self.state.maxY > 0:
      self.state.targetY = (
        self.state.targetY - ctx.mouseWheelY * editorScrollWheelStep()
      ).clamp(-overscrollY, self.state.maxY + overscrollY)
      ctx.setActive(widget.id)
    if ctx.mouseWheelX != 0 and self.state.maxX > 0:
      self.state.targetX = (
        self.state.targetX - ctx.mouseWheelX * editorScrollWheelStep()
      ).clamp(-overscrollX, self.state.maxX + overscrollX)
      ctx.setActive(widget.id)
  if not self.singleLine and self.scrollbars:
    let
      overscrollX = editorOverscrollLimit(f.width)
      overscrollY = editorOverscrollLimit(f.height)
    if not ctx.mouseLeftDown:
      self.state.dragging = NoEditorScroll
    if ctx.mouseLeftPressed:
      clickedScrollbar =
        (self.state.maxY > 0 and verticalTrack(f).contains(ctx.mouseX, ctx.mouseY)) or
        (self.state.maxX > 0 and horizontalTrack(f).contains(ctx.mouseX, ctx.mouseY))
      if self.state.maxY > 0 and verticalThumb(f, self.state).contains(ctx.mouseX, ctx.mouseY):
        self.state.dragging = EditorScrollY
        self.state.dragStartMouse = ctx.mouseY.toFloat
        self.state.dragStartScroll = self.state.targetY
        ctx.setActive(widget.id)
      elif self.state.maxX > 0 and
          horizontalThumb(f, self.state).contains(ctx.mouseX, ctx.mouseY):
        self.state.dragging = EditorScrollX
        self.state.dragStartMouse = ctx.mouseX.toFloat
        self.state.dragStartScroll = self.state.targetX
        ctx.setActive(widget.id)
    case self.state.dragging
    of EditorScrollY:
      let
        track = verticalTrack(f)
        thumb = verticalThumb(f, self.state)
        travel = max(track.height - thumb.height, 1.0)
      self.state.targetY = (
        self.state.dragStartScroll +
        (ctx.mouseY.toFloat - self.state.dragStartMouse) * self.state.maxY / travel
      ).clamp(-overscrollY, self.state.maxY + overscrollY)
      ctx.setActive(widget.id)
    of EditorScrollX:
      let
        track = horizontalTrack(f)
        thumb = horizontalThumb(f, self.state)
        travel = max(track.width - thumb.width, 1.0)
      self.state.targetX = (
        self.state.dragStartScroll +
        (ctx.mouseX.toFloat - self.state.dragStartMouse) * self.state.maxX / travel
      ).clamp(-overscrollX, self.state.maxX + overscrollX)
      ctx.setActive(widget.id)
    of NoEditorScroll:
      discard
  if ctx.mouseLeftPressed:
    if isHot:
      ctx.setFocus(widget.id)
      if not clickedScrollbar and ctx.resources.ready:
        let
          lines =
            if self.singleLine:
              @[self.state.text]
            else:
              editorLines(self.state.text)
          gutterWidth = self.editorLineNumberWidth(ctx.resources, lines.len)
          textLeft = f.x.toInt + EditorPaddingX + gutterWidth
        if ctx.mouseX >= textLeft:
          self.state.cursor = self.cursorAtMouse(ctx.resources, f, ctx.mouseX, ctx.mouseY)
          self.state.resetPreferredColumn()
          self.state.ensureCursorVisible = true
      elif not clickedScrollbar:
        self.state.ensureCursorVisible = true
    elif ctx.focused(widget.id):
      ctx.clearFocus()

  if not ctx.focused(widget.id):
    return

  ctx.setActive(widget.id)
  let previousCursor = self.state.cursor
  let previousTextLen = self.state.text.len
  for input in ctx.keyInputs:
    self.state.handleKey(input, widget, ctx, self.singleLine)
  if ctx.focused(widget.id):
    for text in ctx.textInputs:
      if text.len > 0 and (text[0] >= ' ' or (not self.singleLine and text[0] == '\n')):
        self.state.insertText(text, self.singleLine)
  if self.state.cursor != previousCursor or self.state.text.len != previousTextLen:
    self.state.ensureCursorVisible = true

method measure*(self: Editor, resources: Resources): IntrinsicSize =
  let (width, height) = self.editorContentSize(resources)
  self.state.contentWidth = width
  self.state.contentHeight = height
  intrinsicSize(
    width,
    height,
  )

proc getFrameStyle*(ctx: var DrawContext, hot, focused: bool): tuple[bg, border: Color] =
  let
    bg =
      if focused:
        ctx.palette.cardBackgroundHot
      elif hot:
        ctx.palette.panelMuted
      else:
        ctx.palette.cardBackground
    border = if focused: ctx.palette.cardAccent else: ctx.palette.cardBorder
  result = (bg, border)

proc cursorLineAndColumn(state: EditorState): tuple[line, column: int] =
  var lineStart = 0
  for index, ch in state.text:
    if index >= state.cursor:
      break
    if ch == '\n':
      inc result.line
      lineStart = index + 1
  result.column = state.cursor - lineStart

method draw*(self: Editor, widget: Widget, ctx: var DrawContext) =
  let
    f = widget.frame
    focused = ctx.focused(widget.id)
    hot = ctx.hot(widget.id)
    (bg, border) = ctx.getFrameStyle(hot, focused)
    (font, metrics) = ctx.resources.get(self.fontName)
    lineHeight = max(metrics.lineHeight, ctx.resources.measureText(self.fontName, "M").height)
    lines =
      if self.singleLine:
        @[self.state.text]
      else:
        editorLines(self.state.text)
    gutterWidth = self.editorLineNumberWidth(ctx.resources, lines.len)
    textLeft = f.x.toInt + EditorPaddingX + gutterWidth
    textTop = f.y.toInt + EditorPaddingY
    contentHeight = EditorPaddingY * 2 + lines.len * lineHeight
  var widestLine = 0
  for line in lines:
    widestLine = max(widestLine, ctx.resources.measureText(self.fontName, line.expandTabs).width)
  let contentWidth = gutterWidth + EditorPaddingX * 2 + widestLine

  fillRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), bg)
  lineRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), border)

  self.state.contentWidth = contentWidth.toFloat
  self.state.contentHeight = contentHeight.toFloat
  self.state.updateScrollBounds(f)

  saveState()
  setClipRect(ctx.clippedRect(rect(
    f.x.toInt + 1,
    f.y.toInt + 1,
    max(f.width.toInt - 2, 0),
    max(f.height.toInt - 2, 0),
  )))
  if focused and self.state.ensureCursorVisible:
    let cursor = self.state.cursorLineAndColumn()
    let lineText =
      if cursor.line >= 0 and cursor.line < lines.len:
        lines[cursor.line]
      else:
        ""
    let beforeCursor =
      if cursor.column > 0:
        lineText[0 ..< min(cursor.column, lineText.len)]
      else:
        ""
    let cursorX =
      textLeft + ctx.resources.measureText(self.fontName, beforeCursor.expandTabs).width
    let cursorY = textTop + cursor.line * lineHeight
    let visibleLeft = f.x.toInt + gutterWidth + EditorPaddingX
    let visibleRight = (f.x + f.width).toInt - EditorPaddingX
    let visibleTop = f.y.toInt + EditorPaddingY
    let visibleBottom = (f.y + f.height).toInt - EditorPaddingY
    if cursorX.toFloat - self.state.targetX < visibleLeft.toFloat:
      self.state.targetX = (cursorX - visibleLeft).toFloat.clamp(0.0, self.state.maxX)
    elif cursorX.toFloat - self.state.targetX > visibleRight.toFloat:
      self.state.targetX = (
        cursorX - visibleRight + EditorPaddingX
      ).toFloat.clamp(0.0, self.state.maxX)
    if cursorY.toFloat - self.state.targetY < visibleTop.toFloat:
      self.state.targetY = (cursorY - visibleTop).toFloat.clamp(0.0, self.state.maxY)
    elif (cursorY + lineHeight).toFloat - self.state.targetY > visibleBottom.toFloat:
      self.state.targetY = (
        cursorY + lineHeight - visibleBottom
      ).toFloat.clamp(0.0, self.state.maxY)
    self.state.ensureCursorVisible = false

  let
    overscrollX = editorOverscrollLimit(f.width)
    overscrollY = editorOverscrollLimit(f.height)
  self.state.scrollX = self.state.scrollX.clamp(
    -overscrollX, self.state.maxX + overscrollX
  ).lerp(self.state.targetX, editorScrollLerpFactor())
  self.state.scrollY = self.state.scrollY.clamp(
    -overscrollY, self.state.maxY + overscrollY
  ).lerp(self.state.targetY, editorScrollLerpFactor())
  if not self.state.scrollX.nearlyEqual(self.state.targetX) or
      not self.state.scrollY.nearlyEqual(self.state.targetY):
    ctx.requestRedrawAfter(16)

  var y = textTop - self.state.scrollY.toInt
  for index in 0 ..< lines.len:
    if y + lineHeight >= f.y.toInt and y <= (f.y + f.height).toInt:
      if self.lineNumbers:
        let number = $(index + 1)
        let numberWidth = ctx.resources.measureText(self.fontName, number).width
        discard drawText(
          Font(font),
          f.x.toInt + EditorPaddingX + gutterWidth - EditorPaddingX - numberWidth,
          y,
          number,
          ctx.palette.foreground,
          bg,
        )
    y += lineHeight

  if self.lineNumbers:
    drawLine(
      f.x.toInt + gutterWidth,
      f.y.toInt + 1,
      f.x.toInt + gutterWidth,
      (f.y + f.height).toInt - 1,
      border,
    )

  let
    textClipLeft = f.x.toInt + gutterWidth + 1
    textClipRight = (f.x + f.width).toInt - 1
  saveState()
  setClipRect(ctx.clippedRect(rect(
    textClipLeft,
    f.y.toInt + 1,
    max(textClipRight - textClipLeft, 0),
    max(f.height.toInt - 2, 0),
  )))
  y = textTop - self.state.scrollY.toInt
  for line in lines:
    if y + lineHeight >= f.y.toInt and y <= (f.y + f.height).toInt:
      discard drawText(
        Font(font),
        textLeft - self.state.scrollX.toInt,
        y,
        line.expandTabs,
        ctx.palette.textColor,
        bg,
      )
    y += lineHeight

  if focused:
    let cursor = self.state.cursorLineAndColumn()
    let lineText =
      if cursor.line >= 0 and cursor.line < lines.len:
        lines[cursor.line]
      else:
        ""
    let beforeCursor =
      if cursor.column > 0:
        lineText[0 ..< min(cursor.column, lineText.len)]
      else:
        ""
    let cursorX =
      textLeft - self.state.scrollX.toInt +
      ctx.resources.measureText(self.fontName, beforeCursor.expandTabs).width
    let cursorY = textTop - self.state.scrollY.toInt + cursor.line * lineHeight
    drawLine(
      cursorX,
      cursorY,
      cursorX,
      min(cursorY + lineHeight, (f.y + f.height).toInt - EditorPaddingY),
      ctx.palette.textColor,
    )
  restoreState()
  if self.scrollbars:
    if self.state.maxY > 0:
      let
        track = verticalTrack(f)
        thumb = verticalThumb(f, self.state)
      fillRect(
        rect(track.x.toInt, track.y.toInt, track.width.toInt, track.height.toInt),
        ctx.palette.panelMuted,
      )
      fillRect(
        rect(thumb.x.toInt, thumb.y.toInt, thumb.width.toInt, thumb.height.toInt),
        ctx.palette.cardAccent,
      )
    if self.state.maxX > 0:
      let
        track = horizontalTrack(f)
        thumb = horizontalThumb(f, self.state)
      fillRect(
        rect(track.x.toInt, track.y.toInt, track.width.toInt, track.height.toInt),
        ctx.palette.panelMuted,
      )
      fillRect(
        rect(thumb.x.toInt, thumb.y.toInt, thumb.width.toInt, thumb.height.toInt),
        ctx.palette.cardAccent,
      )
  restoreState()
