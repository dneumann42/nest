import std/[math, sets, strutils]

import ../../[resources, widgets2]
import nest/[coords, screen]

import model

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

type EditorTokenKind = enum
  EditorTokenPlain
  EditorTokenKeyword
  EditorTokenType
  EditorTokenString
  EditorTokenNumber
  EditorTokenComment
  EditorTokenOperator

proc isIdentStart(ch: char): bool =
  ch == '_' or ch.isAlphaAscii

proc isIdentPart(ch: char): bool =
  ch == '_' or ch.isAlphaNumeric

proc nimTokenKind(token: string): EditorTokenKind =
  case token
  of "addr", "and", "as", "asm", "bind", "block", "break", "case", "cast",
      "concept", "const", "continue", "converter", "defer", "discard",
          "distinct", "do", "elif",
      "else", "end", "enum", "except", "export", "finally", "for", "from",
          "func",
      "if", "import", "in", "include", "interface", "is", "isnot", "iterator",
          "let",
      "macro", "method", "mixin", "nil", "not", "notin", "object", "of", "or",
          "out",
      "proc", "ptr", "raise", "ref", "return", "shl", "shr", "static",
          "template",
      "try", "tuple", "type", "using", "var", "when", "while", "xor", "yield":
    EditorTokenKeyword
  of "bool", "char", "cstring", "float", "float32", "float64", "int", "int8",
      "int16", "int32", "int64", "string", "uint", "uint8", "uint16", "uint32", "uint64":
    EditorTokenType
  else:
    EditorTokenPlain

proc tokenColor(ctx: var DrawContext, kind: EditorTokenKind): Color =
  case kind
  of EditorTokenKeyword:
    ctx.palette.mauve
  of EditorTokenType:
    ctx.palette.sky
  of EditorTokenString:
    ctx.palette.butter
  of EditorTokenNumber:
    ctx.palette.peach
  of EditorTokenComment:
    ctx.palette.foreground
  of EditorTokenOperator:
    ctx.palette.rose
  of EditorTokenPlain:
    ctx.palette.textColor

proc drawHighlightedLine(
    self: Editor,
    ctx: var DrawContext,
    font: Font,
    x, y: int,
    line: string,
    bg: Color,
) =
  if self.syntax.len == 0:
    discard drawText(font, x, y, line.expandTabs, ctx.palette.textColor, bg)
    return

  var
    cursor = 0
    drawX = x
  template drawSegment(segment: string, kind: EditorTokenKind) =
    block:
      let rendered = segment.expandTabs
      if rendered.len > 0:
        let extent = drawText(font, drawX, y, rendered, ctx.tokenColor(kind), bg)
        drawX += extent.w

  while cursor < line.len:
    let ch = line[cursor]
    if ch == '#':
      drawSegment(line[cursor .. ^1], EditorTokenComment)
      return
    elif ch in {'"', '\''}:
      let quote = ch
      var stop = cursor + 1
      while stop < line.len:
        if line[stop] == quote and (stop == cursor + 1 or line[stop - 1] != '\\'):
          inc stop
          break
        inc stop
      drawSegment(line[cursor ..< min(stop, line.len)], EditorTokenString)
      cursor = min(stop, line.len)
    elif ch.isDigit:
      var stop = cursor + 1
      while stop < line.len and (line[stop].isAlphaNumeric or line[stop] in {
          '_', '.'}):
        inc stop
      drawSegment(line[cursor ..< stop], EditorTokenNumber)
      cursor = stop
    elif ch.isIdentStart:
      var stop = cursor + 1
      while stop < line.len and line[stop].isIdentPart:
        inc stop
      let token = line[cursor ..< stop]
      let kind =
        case self.syntax
        of "nim":
          nimTokenKind(token)
        else:
          EditorTokenPlain
      drawSegment(token, kind)
      cursor = stop
    elif ch in {'=', '+', '-', '*', '/', '<', '>', '!', '?', ':', '.', ',', ';',
        '|', '&', '^', '%', '@', '~'}:
      drawSegment($ch, EditorTokenOperator)
      inc cursor
    else:
      drawSegment($ch, EditorTokenPlain)
      inc cursor

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

  if manualScroll:
    self.state.ensureCursorVisible = false
  if abs(self.state.targetX - previousTargetX) > 0.01 or
      abs(self.state.targetY - previousTargetY) > 0.01:
    ctx.markDirty(widget.id)

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

proc getFrameStyle*(ctx: var DrawContext, hot, focused: bool): tuple[bg,
    border: Color] =
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
    lineHeight = max(metrics.lineHeight, ctx.resources.measureText(
        self.fontName, "M").height)
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
    widestLine = max(widestLine, ctx.resources.measureText(self.fontName,
        line.expandTabs).width)
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

  var y = textTop - self.state.scrollY.toInt
  for index in 0 ..< lines.len:
    if y + lineHeight >= f.y.toInt and y <= (f.y + f.height).toInt:
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
  if self.state.hasSelection:
    let selection = self.state.selectionRange
    var lineStartIndex = 0
    y = textTop - self.state.scrollY.toInt
    for index, line in lines:
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
      lineStartIndex = lineStopIndex + 1
      y += lineHeight

  y = textTop - self.state.scrollY.toInt
  for index, line in lines:
    if y + lineHeight >= f.y.toInt and y <= (f.y + f.height).toInt:
      let lineBg =
        if self.activeLine == index + 1:
          ctx.palette.panelMuted
        else:
          bg
      self.drawHighlightedLine(
        ctx,
        Font(font),
        textLeft - self.state.scrollX.toInt,
        y,
        line,
        lineBg,
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
