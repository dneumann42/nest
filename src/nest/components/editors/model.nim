import std/[math, sets, strutils]

import ../../screen
import ../../widgets2
import ../component

const
  EditorPaddingX* = 8
  EditorPaddingY* = 4
  EditorMinWidth* = 80
  EditorMinHeight* = 28

type
  EditorScrollAxis* = enum
    NoEditorScroll
    EditorScrollX
    EditorScrollY

  EditorCursor* = object
    index*: int

  SyntaxMatchKind* = enum
    SyntaxRegex
    SyntaxWord
    SyntaxStartsWith
    SyntaxContains
    SyntaxSpan

  SyntaxRule* = object
    kind*: SyntaxMatchKind
    pattern*: string
    stopPattern*: string
    color*: Color

  SyntaxDefinition* = object
    name*: string
    rules*: seq[SyntaxRule]

  HighlightSegment* = object
    start*, stop*: int
    highlighted*: bool
    color*: Color

  LineHighlightCache* = object
    textVersion*: int
    syntaxVersion*: int
    lineText*: string
    segments*: seq[HighlightSegment]

  EditorState* = ref object
    text*: string
    textVersion*: int
    syntaxVersion*: int
    cursor*: int
    selectionAnchor*: int
    undoStack*, redoStack*: seq[string]
    preferredColumn*: int
    scrollX*, scrollY*: float64
    targetX*, targetY*: float64
    maxX*, maxY*: float64
    contentWidth*, contentHeight*: float64
    cachedTextVersion*: int
    cachedTextLen*: int
    cachedLines*: seq[string]
    cachedLineStarts*: seq[int]
    cachedLineWidths*: seq[int]
    cachedWidthFont*: string
    cachedWidestLine*: int
    cachedHighlights*: seq[LineHighlightCache]
    dragging*: EditorScrollAxis
    dragStartMouse*: float64
    dragStartScroll*: float64
    ensureCursorVisible*: bool
    syntax*: SyntaxDefinition

  Editor* = ref object of Interactive
    state*: EditorState
    fontName*: string
    singleLine*: bool
    lineNumbers*: bool
    scrollbars*: bool
    syntax*: string
    gutterMarkers*: HashSet[int]
    activeLine*: int

proc new*(T: typedesc[EditorState], text = ""): T =
  ## Create editor state holding `text`, with the cursor at its end and
  ## nothing selected.
  T(text: text, textVersion: 1, cursor: text.len, selectionAnchor: -1,
      preferredColumn: -1, cachedTextVersion: -1, cachedTextLen: -1)

proc touchText*(state: EditorState) =
  ## Mark cached line and width data stale after changing `text`.
  inc state.textVersion
  state.cachedTextVersion = -1

proc replaceText*(state: EditorState, text: string) =
  ## Replace the whole buffer, keeping the cursor and selection valid.
  if state.text == text:
    return
  state.text = text
  state.cursor = min(state.cursor, state.text.len)
  state.selectionAnchor = -1
  state.preferredColumn = -1
  state.touchText()

proc clearSyntax*(state: EditorState) =
  ## Remove syntax highlighting from this editor state.
  state.syntax = SyntaxDefinition()
  inc state.syntaxVersion

proc setSyntax*(state: EditorState, syntax: SyntaxDefinition) =
  ## Replace this editor state's syntax highlighting definition.
  state.syntax = syntax
  inc state.syntaxVersion

proc clampCursor*(state: EditorState) =
  ## Pull the cursor, and the selection anchor when there is one, back inside
  ## the text.
  ##
  ## Call this after replacing `state.text` from outside the editor.
  state.cursor = clamp(state.cursor, 0, state.text.len)
  if state.selectionAnchor >= 0:
    state.selectionAnchor = clamp(state.selectionAnchor, 0, state.text.len)

proc clearSelection*(state: EditorState) =
  ## Drop the selection, leaving the cursor where it is.
  state.selectionAnchor = -1

proc hasSelection*(state: EditorState): bool =
  ## Test whether there is a selection covering at least one character.
  state.selectionAnchor >= 0 and state.selectionAnchor != state.cursor

proc selectionRange*(state: EditorState): tuple[first, last: int] =
  ## Return the selected range as `first ..< last` offsets into the text.
  ##
  ## Both ends are the cursor position when nothing is selected.
  if state.hasSelection:
    result.first = min(state.selectionAnchor, state.cursor)
    result.last = max(state.selectionAnchor, state.cursor)
  else:
    result.first = state.cursor
    result.last = state.cursor

proc selectedText*(state: EditorState): string =
  ## Return the selected text, or an empty string when nothing is selected.
  let r = state.selectionRange
  if r.last > r.first:
    state.text[r.first ..< r.last]
  else:
    ""

proc resetPreferredColumn*(state: EditorState) =
  ## Forget the column the cursor should return to when moving between lines.
  ##
  ## Vertical movement keeps the column of the line the cursor started on;
  ## any other edit or movement resets it.
  state.preferredColumn = -1

proc rememberUndo(state: EditorState) =
  if state.undoStack.len == 0 or state.undoStack[^1] != state.text:
    state.undoStack.add state.text
    if state.undoStack.len > 100:
      state.undoStack.delete(0)
  state.redoStack.setLen(0)

proc undo*(state: EditorState) =
  ## Undo the last edit, pushing the current text onto the redo stack.
  if state.undoStack.len == 0:
    return
  state.redoStack.add state.text
  state.text = state.undoStack[^1]
  state.touchText()
  state.undoStack.setLen(state.undoStack.len - 1)
  state.cursor = min(state.cursor, state.text.len)
  state.clearSelection()
  state.resetPreferredColumn()

proc redo*(state: EditorState) =
  ## Redo the last undone edit, pushing the current text onto the undo stack.
  if state.redoStack.len == 0:
    return
  state.undoStack.add state.text
  state.text = state.redoStack[^1]
  state.touchText()
  state.redoStack.setLen(state.redoStack.len - 1)
  state.cursor = min(state.cursor, state.text.len)
  state.clearSelection()
  state.resetPreferredColumn()

proc new*(
    T: typedesc[Editor],
    state: EditorState,
    fontName = "font",
    singleLine = false,
    lineNumbers = false,
    scrollbars = true,
    syntax = "",
    gutterMarkers: HashSet[int] = initHashSet[int](),
    activeLine = 0,
): T =
  ## Create an editor component over `state`.
  ##
  ## `singleLine` restricts it to one line, so Enter submits instead of
  ## inserting a newline. `lineNumbers` shows a gutter, `scrollbars` shows
  ## scrollbars when the content overflows, `syntax` names the highlighter to
  ## run, `gutterMarkers` are the lines to mark in the gutter, and
  ## `activeLine` is the line to highlight, counted from one.
  state.clampCursor()
  T(
    state: state,
    fontName: fontName,
    singleLine: singleLine,
    lineNumbers: lineNumbers and not singleLine,
    scrollbars: scrollbars and not singleLine,
    syntax: syntax.normalize,
    gutterMarkers: gutterMarkers,
    activeLine: activeLine,
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

proc setCursor*(state: EditorState, cursor: int, selecting = false) =
  ## Move the cursor to `cursor`.
  ##
  ## With `selecting`, the selection is extended from where the cursor was,
  ## starting a selection if there was none; without it the selection is
  ## dropped.
  let previous = state.cursor
  if selecting and state.selectionAnchor < 0:
    state.selectionAnchor = previous
  state.cursor = cursor.clamp(0, state.text.len)
  if not selecting:
    state.clearSelection()
  state.resetPreferredColumn()

proc deleteSelection*(state: EditorState): bool {.discardable.} =
  ## Delete the selected text and report whether anything was deleted.
  ##
  ## The edit is recorded on the undo stack.
  if not state.hasSelection:
    return false
  state.rememberUndo()
  let r = state.selectionRange
  state.text.delete(r.first .. r.last - 1)
  state.touchText()
  state.cursor = r.first
  state.clearSelection()
  state.resetPreferredColumn()
  true

proc selectAll*(state: EditorState) =
  ## Select the whole text, leaving the cursor at its end.
  state.selectionAnchor = 0
  state.cursor = state.text.len
  state.resetPreferredColumn()

proc insertText*(state: EditorState, text: string, singleLine = false) =
  ## Insert `text` at the cursor, replacing the selection when there is one.
  ##
  ## With `singleLine`, newlines in `text` are stripped so pasted
  ## multi-line text stays on one line. The edit is recorded on the undo
  ## stack.
  state.clampCursor()
  let inserted =
    if singleLine:
      text.replace("\n", "").replace("\r", "")
    else:
      text.replace("\r\n", "\n").replace("\r", "\n")
  if inserted.len == 0:
    return
  state.rememberUndo()
  if state.hasSelection:
    let r = state.selectionRange
    state.text.delete(r.first .. r.last - 1)
    state.cursor = r.first
  state.text.insert(inserted, state.cursor)
  state.touchText()
  inc state.cursor, inserted.len
  state.clearSelection()
  state.resetPreferredColumn()

proc deleteBackward*(state: EditorState) =
  ## Delete the selection, or the character before the cursor when nothing is
  ## selected.
  state.clampCursor()
  if state.deleteSelection():
    return
  if state.cursor > 0:
    state.rememberUndo()
    state.text.delete(state.cursor - 1 .. state.cursor - 1)
    state.touchText()
    dec state.cursor
    state.clearSelection()
    state.resetPreferredColumn()

proc deleteForward*(state: EditorState) =
  ## Delete the selection, or the character after the cursor when nothing is
  ## selected.
  state.clampCursor()
  if state.deleteSelection():
    return
  if state.cursor < state.text.len:
    state.rememberUndo()
    state.text.delete(state.cursor .. state.cursor)
    state.touchText()
    state.clearSelection()
    state.resetPreferredColumn()

proc killToStart*(state: EditorState) =
  ## Delete from the start of the current line up to the cursor.
  state.clampCursor()
  let start = state.text.lineStart(state.cursor)
  if state.cursor > start:
    state.rememberUndo()
    state.text.delete(start .. state.cursor - 1)
    state.touchText()
    state.cursor = start
    state.clearSelection()
    state.resetPreferredColumn()

proc killToEnd*(state: EditorState) =
  ## Delete from the cursor to the end of the current line.
  state.clampCursor()
  let stop = state.text.lineEnd(state.cursor)
  if state.cursor < stop:
    state.rememberUndo()
    state.text.delete(state.cursor .. stop - 1)
    state.touchText()
    state.clearSelection()
    state.resetPreferredColumn()

proc copySelection*(state: EditorState): string {.raises: [].} =
  ## Copy the selection to the system clipboard and return it.
  ##
  ## Returns an empty string, and leaves the clipboard alone, when nothing is
  ## selected.
  result = state.selectedText()
  if result.len > 0:
    try:
      putClipboardText(result)
    except Exception:
      discard

proc cutSelection*(state: EditorState): string {.raises: [].} =
  ## Cut the selection to the system clipboard and return it.
  result = state.copySelection()
  if result.len > 0:
    try:
      discard state.deleteSelection()
    except Exception:
      discard

proc pasteClipboard*(state: EditorState, singleLine = false) {.raises: [].} =
  ## Insert the clipboard contents at the cursor.
  ##
  ## With `singleLine`, newlines are stripped from what is pasted. A
  ## clipboard that cannot be read is ignored.
  try:
    state.insertText(getClipboardText(), singleLine)
  except Exception:
    discard

proc lineColumn*(state: EditorState): tuple[line, column: int] =
  ## Return the cursor's one-based line and column.
  result.line = 1
  result.column = 1
  let stop = state.cursor.clamp(0, state.text.len)
  var lineStart = 0
  for index in 0 ..< stop:
    if state.text[index] == '\n':
      inc result.line
      lineStart = index + 1
  result.column = stop - lineStart + 1

proc cursorForLineColumn*(state: EditorState, line, column: int): int =
  ## Return the text offset of one-based `line` and `column`.
  ##
  ## Positions past the end of a line, or past the end of the text, clamp to
  ## the nearest valid offset.
  let wantedLine = max(line, 1)
  let wantedColumn = max(column, 1)
  var currentLine = 1
  var lineStart = 0
  var index = 0
  while index < state.text.len and currentLine < wantedLine:
    if state.text[index] == '\n':
      inc currentLine
      lineStart = index + 1
    inc index
  let lineStop = state.text.lineEnd(lineStart)
  lineStart + min(wantedColumn - 1, lineStop - lineStart)

proc handleKey*(state: EditorState, input: KeyInput, widget: Widget,
    ctx: var UpdateContext, singleLine = false) =
  ## Apply one key press to the editor state.
  ##
  ## Handles cursor movement, with Shift extending the selection, editing
  ## and deletion keys, undo and redo, select-all, and the clipboard
  ## shortcuts. Escape drops focus. In a `singleLine` editor Enter submits
  ## `widget` and drops focus instead of inserting a newline.
  let ctrl = CtrlPressed in input.mods
  let shift = ShiftPressed in input.mods
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
      state.setCursor(state.cursor - 1, shift)
  of KeyRight:
    if state.cursor < state.text.len:
      state.setCursor(state.cursor + 1, shift)
  of KeyUp:
    state.preferredColumn =
      if state.preferredColumn >= 0: state.preferredColumn else: state.cursorColumn()
    state.setCursor(state.previousLineCursor(), shift)
  of KeyDown:
    state.preferredColumn =
      if state.preferredColumn >= 0: state.preferredColumn else: state.cursorColumn()
    state.setCursor(state.nextLineCursor(), shift)
  of KeyHome:
    state.setCursor(state.text.lineStart(state.cursor), shift)
  of KeyEnd:
    state.setCursor(state.text.lineEnd(state.cursor), shift)
  of KeyBackspace:
    state.deleteBackward()
  of KeyDelete:
    state.deleteForward()
  of KeyA:
    if ctrl:
      if singleLine:
        state.setCursor(state.text.lineStart(state.cursor), shift)
      else:
        state.selectAll()
  of KeyE:
    if ctrl:
      state.setCursor(state.text.lineEnd(state.cursor), shift)
  of KeyB:
    if ctrl and state.cursor > 0:
      state.setCursor(state.cursor - 1, shift)
  of KeyC:
    if ctrl:
      discard state.copySelection()
  of KeyF:
    if ctrl and state.cursor < state.text.len:
      state.setCursor(state.cursor + 1, shift)
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
  of KeyV:
    if ctrl:
      state.pasteClipboard(singleLine)
  of KeyX:
    if ctrl:
      discard state.cutSelection()
  of KeyY:
    if ctrl:
      state.redo()
  of KeyZ:
    if ctrl:
      state.undo()
  else:
    discard
