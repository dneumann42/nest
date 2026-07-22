import std/strutils

import ../[resources, widgets2]
import component
import nest/[coords, screen]

const
  EditorPaddingX* = 8
  EditorPaddingY* = 4
  EditorMinWidth* = 80
  EditorMinHeight* = 28

type
  EditorCursor* = object
    index*: int

  EditorState* = ref object
    text*: string
    cursor*: int
    preferredColumn*: int

  Editor* = ref object of Interactive
    state*: EditorState
    fontName*: string
    singleLine*: bool

proc new*(T: typedesc[EditorState], text = ""): T =
  T(text: text, cursor: text.len, preferredColumn: -1)

proc clampCursor*(state: EditorState) =
  state.cursor = clamp(state.cursor, 0, state.text.len)

proc new*(
    T: typedesc[Editor], state: EditorState, fontName = "font", singleLine = false
): T =
  state.clampCursor()
  T(state: state, fontName: fontName, singleLine: singleLine)

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
  x.float64 > f.x and x.float64 < f.x + f.width and
    y.float64 > f.y and y.float64 < f.y + f.height

method update*(self: Editor, widget: Widget, ctx: var UpdateContext) =
  let isHot = widget.frame.frameContains(ctx.mouseX, ctx.mouseY)
  if isHot:
    ctx.setHot(widget.id)
  if ctx.mouseLeftPressed:
    if isHot:
      ctx.setFocus(widget.id)
    elif ctx.focused(widget.id):
      ctx.clearFocus()

  if not ctx.focused(widget.id):
    return

  ctx.setActive(widget.id)
  for input in ctx.keyInputs:
    self.state.handleKey(input, widget, ctx, self.singleLine)
  if ctx.focused(widget.id):
    for text in ctx.textInputs:
      if text.len > 0 and (text[0] >= ' ' or (not self.singleLine and text[0] == '\n')):
        self.state.insertText(text, self.singleLine)

proc editorLines(text: string): seq[string] =
  result = text.split('\n')
  if result.len == 0:
    result = @[""]

method measure*(self: Editor, resources: Resources): IntrinsicSize =
  let lines =
    if self.singleLine:
      @[self.state.text]
    else:
      editorLines(self.state.text)
  var width = 0
  var height = 0
  let (_, metrics) = resources.get(self.fontName)
  for line in lines:
    let measurement = resources.measureText(self.fontName, line)
    width = max(width, measurement.width)
    height += max(metrics.lineHeight, measurement.height)
  intrinsicSize(
    max(width + EditorPaddingX * 2, EditorMinWidth).toFloat,
    max(height + EditorPaddingY * 2, EditorMinHeight).toFloat,
  )

proc getFrameStyle*(ctx: DrawContext, hot, focused: bool): tuple[bg, border: Color] =
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

method draw*(self: Editor, widget: Widget, ctx: DrawContext) =
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

  fillRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), bg)
  lineRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), border)

  saveState()
  setClipRect(ctx.clippedRect(rect(
    f.x.toInt + 1,
    f.y.toInt + 1,
    max(f.width.toInt - 2, 0),
    max(f.height.toInt - 2, 0),
  )))
  var y = f.y.toInt + EditorPaddingY
  for line in lines:
    discard drawText(
      Font(font),
      f.x.toInt + EditorPaddingX,
      y,
      line,
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
      f.x.toInt + EditorPaddingX + ctx.resources.measureText(self.fontName, beforeCursor).width
    let cursorY = f.y.toInt + EditorPaddingY + cursor.line * lineHeight
    drawLine(
      cursorX,
      cursorY,
      cursorX,
      min(cursorY + lineHeight, (f.y + f.height).toInt - EditorPaddingY),
      ctx.palette.textColor,
    )
  restoreState()
