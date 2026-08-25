import std/[math, re, sets, strutils, tables]

import ../../[resources, widgets2]
import nest/[coords, screen]

import model

var regexCache: Table[string, Regex]

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

proc ensureLineCache(state: EditorState) =
  if state.cachedTextVersion == state.textVersion and
      state.cachedTextLen == state.text.len and state.cachedLines.len > 0:
    return
  state.cachedLines.setLen(0)
  state.cachedLineStarts.setLen(0)
  var start = 0
  for index, ch in state.text:
    if ch == '\n':
      state.cachedLineStarts.add start
      state.cachedLines.add state.text[start ..< index]
      start = index + 1
  state.cachedLineStarts.add start
  state.cachedLines.add state.text[start ..< state.text.len]
  state.cachedLineWidths.setLen(state.cachedLines.len)
  state.cachedHighlights.setLen(state.cachedLines.len)
  for width in state.cachedLineWidths.mitems:
    width = -1
  state.cachedWidestLine = -1
  state.cachedTextVersion = state.textVersion
  state.cachedTextLen = state.text.len

proc editorLineCount(state: EditorState): int =
  state.ensureLineCache()
  state.cachedLines.len

proc editorLine(state: EditorState, index: int): string =
  state.ensureLineCache()
  if index >= 0 and index < state.cachedLines.len:
    state.cachedLines[index]
  else:
    ""

proc editorLineStart(state: EditorState, index: int): int =
  state.ensureLineCache()
  if index >= 0 and index < state.cachedLineStarts.len:
    state.cachedLineStarts[index]
  else:
    state.text.len

proc resetWidthCache(state: EditorState, fontName: string) =
  state.cachedWidthFont = fontName
  state.cachedLineWidths.setLen(state.cachedLines.len)
  for width in state.cachedLineWidths.mitems:
    width = -1
  state.cachedWidestLine = -1

proc measuredLineWidth(state: EditorState, resources: Resources, fontName: string,
    index: int): int =
  state.ensureLineCache()
  if state.cachedWidthFont != fontName or state.cachedLineWidths.len !=
      state.cachedLines.len:
    state.resetWidthCache(fontName)
  if index < 0 or index >= state.cachedLines.len:
    return 0
  if state.cachedLineWidths[index] < 0:
    state.cachedLineWidths[index] =
      resources.measureText(fontName, state.cachedLines[index].expandTabs).width
  state.cachedLineWidths[index]

proc widestLineWidth(state: EditorState, resources: Resources,
    fontName: string): int =
  state.ensureLineCache()
  if state.cachedWidthFont != fontName or state.cachedLineWidths.len !=
      state.cachedLines.len:
    state.resetWidthCache(fontName)
  if state.cachedWidestLine >= 0:
    return state.cachedWidestLine
  result = 0
  for index in 0 ..< state.cachedLines.len:
    result = max(result, state.measuredLineWidth(resources, fontName, index))
  state.cachedWidestLine = result

proc visibleLineRange(
    lineCount, lineHeight, textTop: int, scrollY: float64, f: Frame
): tuple[first, last: int] =
  if lineCount <= 0 or lineHeight <= 0:
    return (0, -1)
  let
    top = f.y.toInt
    bottom = (f.y + f.height).toInt
    firstLine = floor(((top - textTop).float64 + scrollY) /
        lineHeight.float64).toInt
    lastLine = ceil(((bottom - textTop).float64 + scrollY) /
        lineHeight.float64).toInt
  result.first = clamp(firstLine - 1, 0, lineCount - 1)
  result.last = clamp(lastLine + 1, 0, lineCount - 1)

proc isIdentPart(ch: char): bool =
  ch == '_' or ch.isAlphaNumeric

proc wordMatch(line: string, cursor: int, word: string): bool =
  if word.len == 0 or cursor + word.len > line.len:
    return false
  if line[cursor ..< cursor + word.len] != word:
    return false
  let beforeOk = cursor == 0 or not line[cursor - 1].isIdentPart
  let after = cursor + word.len
  let afterOk = after >= line.len or not line[after].isIdentPart
  beforeOk and afterOk

proc compiledRegex(pattern: string): Regex =
  if pattern in regexCache:
    return regexCache[pattern]
  result = re(pattern)
  regexCache[pattern] = result

proc matchRule(line: string, cursor: int, rule: SyntaxRule): int =
  case rule.kind
  of SyntaxRegex:
    try:
      result = line.matchLen(compiledRegex(rule.pattern), cursor)
      if result < 0:
        result = 0
    except CatchableError:
      result = 0
  of SyntaxWord:
    if line.wordMatch(cursor, rule.pattern):
      result = rule.pattern.len
  of SyntaxStartsWith:
    if rule.pattern.len > 0 and cursor + rule.pattern.len <= line.len and
        line[cursor ..< cursor + rule.pattern.len] == rule.pattern:
      result = line.len - cursor
  of SyntaxContains:
    if rule.pattern.len > 0 and cursor + rule.pattern.len <= line.len and
        line[cursor ..< cursor + rule.pattern.len] == rule.pattern:
      result = rule.pattern.len
  of SyntaxSpan:
    if rule.pattern.len > 0 and cursor + rule.pattern.len <= line.len and
        line[cursor ..< cursor + rule.pattern.len] == rule.pattern:
      let contentStart = cursor + rule.pattern.len
      let stop =
        if rule.stopPattern.len == 0:
          -1
        else:
          line.find(rule.stopPattern, contentStart)
      result =
        if stop < 0:
          line.len - cursor
        else:
          stop + rule.stopPattern.len - cursor

proc firstSyntaxMatch(
    syntax: SyntaxDefinition,
    line: string,
    cursor: int,
): tuple[length: int, color: Color] =
  for rule in syntax.rules:
    let length = line.matchRule(cursor, rule)
    if length > 0:
      return (length, rule.color)
  (0, Color())

proc highlightedLineSegments(
    self: Editor,
    lineIndex: int,
    line: string,
): seq[HighlightSegment] =
  if lineIndex < 0 or lineIndex >= self.state.cachedHighlights.len:
    return
  let cache = self.state.cachedHighlights[lineIndex]
  if cache.textVersion == self.state.textVersion and
      cache.syntaxVersion == self.state.syntaxVersion and cache.lineText == line:
    return cache.segments

  var
    cursor = 0
    plainStart = 0
    segments: seq[HighlightSegment]
  template addPlain(stopIndex: int) =
    block:
      if plainStart < stopIndex:
        segments.add HighlightSegment(start: plainStart, stop: stopIndex)

  while cursor < line.len:
    let matched = self.state.syntax.firstSyntaxMatch(line, cursor)
    if matched.length > 0:
      addPlain(cursor)
      let stop = min(cursor + matched.length, line.len)
      segments.add HighlightSegment(start: cursor, stop: stop,
          highlighted: true, color: matched.color)
      cursor = stop
      plainStart = cursor
    else:
      inc cursor
  addPlain(line.len)

  self.state.cachedHighlights[lineIndex] = LineHighlightCache(
    textVersion: self.state.textVersion,
    syntaxVersion: self.state.syntaxVersion,
    lineText: line,
    segments: segments,
  )
  segments

proc drawHighlightedLine(
    self: Editor,
    ctx: var DrawContext,
    font: Font,
    x, y: int,
    lineIndex: int,
    line: string,
    bg: Color,
) =
  if self.state.syntax.rules.len == 0:
    discard drawText(font, x, y, line.expandTabs, ctx.palette.textColor, bg)
    return

  var drawX = x
  for segment in self.highlightedLineSegments(lineIndex, line):
    if segment.stop <= segment.start:
      continue
    let
      rendered = line[segment.start ..< segment.stop].expandTabs
      fg =
        if segment.highlighted:
          segment.color
        else:
          ctx.palette.textColor
    if rendered.len > 0:
      let extent = drawText(font, drawX, y, rendered, fg, bg)
      drawX += extent.w

proc drawEditorCursor(
    self: Editor,
    ctx: var DrawContext,
    font: Font,
    x, y, lineHeight: int,
    lineText: string,
    column: int,
    bg: Color,
) =
  let cursorStyle =
    if self.state.cursorStyle == EditorBlockCursor: EditorBlockCursor else: self.cursorStyle
  case cursorStyle
  of EditorLineCursor:
    drawLine(
      x,
      y,
      x,
      y + lineHeight,
      ctx.palette.textColor,
    )
  of EditorBlockCursor:
    let
      ch =
        if column >= 0 and column < lineText.len:
          $lineText[column]
        else:
          " "
      rendered = ch.expandTabs
      width = max(ctx.resources.measureText(self.fontName, rendered).width,
          ctx.resources.measureText(self.fontName, "M").width)
      cursorRect = ctx.clippedRect(rect(x, y, width, lineHeight))
    fillRect(cursorRect, ctx.palette.textColor)
    discard drawText(font, x, y, rendered, bg, ctx.palette.textColor)

proc nearlyEqual(a, b: float64): bool =
  abs(a - b) < 0.5

proc contains(frame: Frame, x, y: int): bool =
  x.toFloat >= frame.x and x.toFloat < frame.x + frame.width and y.toFloat >=
      frame.y and
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
    return Frame(x: track.x, y: track.y, width: track.width,
        height: track.height)
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
    return Frame(x: track.x, y: track.y, width: track.width,
        height: track.height)
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
  resources.measureText(self.fontName, repeat("9", digits)).width +
      EditorPaddingX * 2

proc editorTextTop(self: Editor, f: Frame, lineHeight: int): int =
  ## Return the y the editor's first line of text starts at.
  ##
  ## A single-line editor centres its line in the frame, so a line input
  ## laid out at the standard control height does not look top-heavy; a
  ## multi-line one starts at its top padding.
  if self.singleLine:
    f.y.toInt + max((f.height.toInt - lineHeight) div 2, EditorPaddingY)
  else:
    f.y.toInt + EditorPaddingY

proc editorContentSize(
    self: Editor, resources: Resources
): tuple[width, height: float64] =
  self.state.ensureLineCache()
  let (_, metrics) = resources.get(self.fontName)
  let
    lineCount = if self.singleLine: 1 else: self.state.editorLineCount()
    lineHeight = max(metrics.lineHeight, resources.measureText(self.fontName, "M").height)
  var width = self.state.widestLineWidth(resources, self.fontName)
  width += self.editorLineNumberWidth(resources, lineCount)
  (
    max(width + EditorPaddingX * 2, EditorMinWidth).toFloat,
    max(lineCount * lineHeight + EditorPaddingY * 2, EditorMinHeight).toFloat,
  )

proc columnAtContentX(resources: Resources, fontName, line: string,
    x: float64): int =
  if x <= 0:
    return 0
  var previousWidth = 0
  for column in 1 .. line.len:
    let width = resources.measureText(fontName, line[0 ..<
        column].expandTabs).width
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
    lineCount = if self.singleLine: 1 else: self.state.editorLineCount()
    gutterWidth = self.editorLineNumberWidth(resources, lineCount)
    textLeft = f.x.toInt + EditorPaddingX + gutterWidth
    textTop = self.editorTextTop(f, lineHeight)
    contentY = mouseY.toFloat - textTop.toFloat + self.state.scrollY
    lineIndex = floor(contentY / lineHeight.toFloat).toInt.clamp(0, lineCount - 1)
    contentX = mouseX.toFloat - textLeft.toFloat + self.state.scrollX
    line = self.state.editorLine(lineIndex)
    column = resources.columnAtContentX(self.fontName, line, contentX)

  self.state.editorLineStart(lineIndex) + column

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
  ## Handle this frame's input for the editor: focus and caret placement by
  ## pointer, selection dragging, scrollbar dragging, wheel scrolling, and
  ## text and key input while focused.
  let isHot = widget.frame.frameContains(ctx.mouseX, ctx.mouseY)
  let handlesWheel = isHot or ctx.focused(widget.id)
  let f = widget.frame
  var
    clickedScrollbar = false
    manualScroll = false
    previousTargetX = self.state.targetX
    previousTargetY = self.state.targetY
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
      manualScroll = true
      ctx.setActive(widget.id)
    if ctx.mouseWheelX != 0 and self.state.maxX > 0:
      self.state.targetX = (
        self.state.targetX - ctx.mouseWheelX * editorScrollWheelStep()
      ).clamp(-overscrollX, self.state.maxX + overscrollX)
      manualScroll = true
      ctx.setActive(widget.id)
  if not self.singleLine and self.scrollbars:
    let
      overscrollX = editorOverscrollLimit(f.width)
      overscrollY = editorOverscrollLimit(f.height)
    if not ctx.mouseLeftDown:
      self.state.dragging = NoEditorScroll
    if ctx.mouseLeftPressed:
      clickedScrollbar =
        (self.state.maxY > 0 and verticalTrack(f).contains(ctx.mouseX,
            ctx.mouseY)) or
        (self.state.maxX > 0 and horizontalTrack(f).contains(ctx.mouseX, ctx.mouseY))
      if self.state.maxY > 0 and verticalThumb(f, self.state).contains(
          ctx.mouseX, ctx.mouseY):
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
      manualScroll = true
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
      manualScroll = true
      ctx.setActive(widget.id)
    of NoEditorScroll:
      discard
  if ctx.mouseLeftPressed:
    if isHot:
      ctx.setFocus(widget.id)
      if not clickedScrollbar and ctx.resources.ready:
        let
          lineCount = if self.singleLine: 1 else: self.state.editorLineCount()
          gutterWidth = self.editorLineNumberWidth(ctx.resources, lineCount)
          textLeft = f.x.toInt + EditorPaddingX + gutterWidth
        if ctx.mouseX >= textLeft:
          self.state.cursor = self.cursorAtMouse(ctx.resources, f, ctx.mouseX, ctx.mouseY)
          self.state.resetPreferredColumn()
          self.state.ensureCursorVisible = true
      elif not clickedScrollbar:
        self.state.ensureCursorVisible = true
    elif ctx.focused(widget.id):
      ctx.clearFocus()

  if manualScroll:
    self.state.ensureCursorVisible = false
  if abs(self.state.targetX - previousTargetX) > 0.01 or
      abs(self.state.targetY - previousTargetY) > 0.01:
    ctx.markDirty(widget.id)

  if not ctx.focused(widget.id):
    return

  ctx.setActive(widget.id)
  if self.readOnly:
    return
  let inputDriver =
    if self.inputDriver.len > 0: self.inputDriver else: self.state.inputDriver.normalize
  if inputDriver.len > 0 and inputDriver notin ["builtin", "native"]:
    return
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
  ## Return the size the editor's text needs, and cache the content size on
  ## the state for scrolling.
  ##
  ## A single-line editor reports one line's height; a multi-line one reports
  ## its full content, bounded by the editor's minimum size.
  let (width, height) = self.editorContentSize(resources)
  self.state.contentWidth = width
  self.state.contentHeight = height
  intrinsicSize(
    width,
    height,
  )

proc getFrameStyle*(ctx: var DrawContext, hot, focused: bool): tuple[bg,
    border: Color] =
  ## Return the background and border colours a text field should use for its
  ## `hot` and `focused` state.
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
  state.ensureLineCache()
  let cursor = state.cursor.clamp(0, state.text.len)
  var
    lo = 0
    hi = state.cachedLineStarts.len - 1
  while lo <= hi:
    let mid = (lo + hi) div 2
    if state.cachedLineStarts[mid] <= cursor:
      result.line = mid
      lo = mid + 1
    else:
      hi = mid - 1
  result.column = cursor - state.cachedLineStarts[result.line]

method draw*(self: Editor, widget: Widget, ctx: var DrawContext) =
  ## Draw the editor: its frame, the gutter and line numbers, highlighted
  ## text, the selection, the caret and any scrollbars.
  let
    f = widget.frame
    focused = ctx.focused(widget.id)
    hot = ctx.hot(widget.id)
    (bg, border) = ctx.getFrameStyle(hot, focused)
    (font, metrics) = ctx.resources.get(self.fontName)
    lineHeight = max(metrics.lineHeight, ctx.resources.measureText(
        self.fontName, "M").height)
    lineCount = if self.singleLine: 1 else: self.state.editorLineCount()
    gutterWidth = self.editorLineNumberWidth(ctx.resources, lineCount)
    textLeft = f.x.toInt + EditorPaddingX + gutterWidth
    textTop = self.editorTextTop(f, lineHeight)
    contentHeight = EditorPaddingY * 2 + lineCount * lineHeight
    widestLine = self.state.widestLineWidth(ctx.resources, self.fontName)
    contentWidth = gutterWidth + EditorPaddingX * 2 + widestLine

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
      if cursor.line >= 0 and cursor.line < lineCount:
        self.state.editorLine(cursor.line)
      else:
        ""
    let beforeCursor =
      if cursor.column > 0:
        lineText[0 ..< min(cursor.column, lineText.len)]
      else:
        ""
    let cursorX =
      textLeft + ctx.resources.measureText(self.fontName,
          beforeCursor.expandTabs).width
    let cursorY = textTop + cursor.line * lineHeight
    let visibleLeft = f.x.toInt + gutterWidth + EditorPaddingX
    let visibleRight = (f.x + f.width).toInt - EditorPaddingX
    let visibleTop = f.y.toInt + EditorPaddingY
    let visibleBottom = (f.y + f.height).toInt - EditorPaddingY
    if cursorX.toFloat - self.state.targetX < visibleLeft.toFloat:
      self.state.targetX = (cursorX - visibleLeft).toFloat.clamp(0.0,
          self.state.maxX)
    elif cursorX.toFloat - self.state.targetX > visibleRight.toFloat:
      self.state.targetX = (
        cursorX - visibleRight + EditorPaddingX
      ).toFloat.clamp(0.0, self.state.maxX)
    if cursorY.toFloat - self.state.targetY < visibleTop.toFloat:
      self.state.targetY = (cursorY - visibleTop).toFloat.clamp(0.0,
          self.state.maxY)
    elif (cursorY + lineHeight).toFloat - self.state.targetY >
        visibleBottom.toFloat:
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

  let visible = visibleLineRange(lineCount, lineHeight, textTop,
      self.state.scrollY, f)
  for index in visible.first .. visible.last:
    let y = textTop - self.state.scrollY.toInt + index * lineHeight
    if self.activeLine == index + 1:
      fillRect(
        rect(
          f.x.toInt + 1,
          y,
          max(f.width.toInt - 2, 0),
          lineHeight,
        ),
        ctx.palette.panelMuted,
      )
      fillRect(
        rect(
          f.x.toInt + 1,
          y,
          max(gutterWidth, 8),
          lineHeight,
        ),
        ctx.palette.sky,
      )
    if self.lineNumbers:
      let number = $(index + 1)
      let numberWidth = ctx.resources.measureText(self.fontName, number).width
      if (index + 1) in self.gutterMarkers:
        let
          markerSize = min(8, max(lineHeight div 2, 5))
          markerX = f.x.toInt + max((EditorPaddingX - markerSize) div 2, 1)
          markerY = y + max((lineHeight - markerSize) div 2, 0)
        fillRect(rect(markerX, markerY, markerSize, markerSize),
            ctx.palette.rose)
      discard drawText(
        Font(font),
        f.x.toInt + EditorPaddingX + gutterWidth - EditorPaddingX -
            numberWidth,
        y,
        number,
        ctx.palette.foreground,
        bg,
      )
      if self.activeLine == index + 1:
        discard drawText(
          Font(font),
          f.x.toInt + 2,
          y,
          ">",
          ctx.palette.textColor,
          ctx.palette.sky,
        )

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
  if self.state.hasSelection:
    let selection = self.state.selectionRange
    for index in visible.first .. visible.last:
      let
        line = self.state.editorLine(index)
        lineStartIndex = self.state.editorLineStart(index)
        y = textTop - self.state.scrollY.toInt + index * lineHeight
      let lineStopIndex = lineStartIndex + line.len
      let lineSelectionStart = max(selection.first, lineStartIndex)
      let lineSelectionStop = min(selection.last, lineStopIndex)
      if lineSelectionStop > lineSelectionStart and y + lineHeight >= f.y.toInt and
          y <= (f.y + f.height).toInt:
        let
          startColumn = lineSelectionStart - lineStartIndex
          stopColumn = lineSelectionStop - lineStartIndex
          beforeStart =
            if startColumn > 0:
              line[0 ..< min(startColumn, line.len)]
            else:
              ""
          selectedPrefix =
            if stopColumn > 0:
              line[0 ..< min(stopColumn, line.len)]
            else:
              ""
          startX =
            textLeft - self.state.scrollX.toInt +
            ctx.resources.measureText(self.fontName,
                beforeStart.expandTabs).width
          stopX =
            textLeft - self.state.scrollX.toInt +
            ctx.resources.measureText(self.fontName,
                selectedPrefix.expandTabs).width
        fillRect(
          rect(startX, y, max(stopX - startX, 2), lineHeight),
          ctx.palette.backgroundActive,
        )

  for index in visible.first .. visible.last:
    let
      line = self.state.editorLine(index)
      y = textTop - self.state.scrollY.toInt + index * lineHeight
      lineBg =
        if self.activeLine == index + 1:
          ctx.palette.panelMuted
        else:
          bg
    self.drawHighlightedLine(
      ctx,
      Font(font),
      textLeft - self.state.scrollX.toInt,
      y,
      index,
      line,
      lineBg,
    )

  if focused:
    let cursor = self.state.cursorLineAndColumn()
    let lineText =
      if cursor.line >= 0 and cursor.line < lineCount:
        self.state.editorLine(cursor.line)
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
    self.drawEditorCursor(
      ctx,
      Font(font),
      cursorX,
      cursorY,
      lineHeight,
      lineText,
      cursor.column,
      bg,
    )
  restoreState()
  if self.scrollbars:
    if self.state.maxY > 0:
      let
        track = verticalTrack(f)
        thumb = verticalThumb(f, self.state)
      fillRect(
        rect(track.x.toInt, track.y.toInt, track.width.toInt,
            track.height.toInt),
        ctx.palette.panelMuted,
      )
      fillRect(
        rect(thumb.x.toInt, thumb.y.toInt, thumb.width.toInt,
            thumb.height.toInt),
        ctx.palette.cardAccent,
      )
    if self.state.maxX > 0:
      let
        track = horizontalTrack(f)
        thumb = horizontalThumb(f, self.state)
      fillRect(
        rect(track.x.toInt, track.y.toInt, track.width.toInt,
            track.height.toInt),
        ctx.palette.panelMuted,
      )
      fillRect(
        rect(thumb.x.toInt, thumb.y.toInt, thumb.width.toInt,
            thumb.height.toInt),
        ctx.palette.cardAccent,
      )
  restoreState()
