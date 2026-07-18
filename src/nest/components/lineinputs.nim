import std/strutils

import ../[resources, widgets2]
import component
import uirelays/[coords, screen]

const
  InputPaddingX = 8
  InputPaddingY = 4
  InputMinWidth = 80
  InputMinHeight = 28

type
  LineInputState* = ref object
    text*: string
    cursor*: int

  LineInput* = ref object of Interactive
    state: LineInputState
    fontName: string

proc new*(T: typedesc[LineInputState], text = ""): T =
  T(text: text, cursor: text.len)

proc clampCursor(state: LineInputState) =
  state.cursor = clamp(state.cursor, 0, state.text.len)

proc new*(T: typedesc[LineInput], state: LineInputState, fontName = "font"): T =
  state.clampCursor()
  T(state: state, fontName: fontName)

proc insertText(state: LineInputState, text: string) =
  state.clampCursor()
  state.text.insert(text, state.cursor)
  inc state.cursor, text.len

proc deleteBackward(state: LineInputState) =
  state.clampCursor()
  if state.cursor > 0:
    state.text.delete(state.cursor - 1 .. state.cursor - 1)
    dec state.cursor

proc deleteForward(state: LineInputState) =
  state.clampCursor()
  if state.cursor < state.text.len:
    state.text.delete(state.cursor .. state.cursor)

proc killToStart(state: LineInputState) =
  state.clampCursor()
  if state.cursor > 0:
    state.text.delete(0 .. state.cursor - 1)
    state.cursor = 0

proc killToEnd(state: LineInputState) =
  state.clampCursor()
  if state.cursor < state.text.len:
    state.text.setLen(state.cursor)

proc handleKey(state: LineInputState, input: KeyInput, widget: Widget, ctx: var UpdateContext) =
  let ctrl = CtrlPressed in input.mods
  case input.key
  of KeyEsc:
    ctx.clearFocus()
  of KeyEnter:
    ctx.submit(widget.id)
    ctx.clearFocus()
  of KeyLeft:
    if state.cursor > 0:
      dec state.cursor
  of KeyRight:
    if state.cursor < state.text.len:
      inc state.cursor
  of KeyHome:
    state.cursor = 0
  of KeyEnd:
    state.cursor = state.text.len
  of KeyBackspace:
    state.deleteBackward()
  of KeyDelete:
    state.deleteForward()
  of KeyA:
    if ctrl:
      state.cursor = 0
  of KeyE:
    if ctrl:
      state.cursor = state.text.len
  of KeyB:
    if ctrl and state.cursor > 0:
      dec state.cursor
  of KeyF:
    if ctrl and state.cursor < state.text.len:
      inc state.cursor
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

method update*(self: LineInput, widget: Widget, ctx: var UpdateContext) =
  let
    f = widget.frame
    isHot =
      ctx.mouseX > f.x.toInt and
      ctx.mouseX < (f.x + f.width).toInt and
      ctx.mouseY > f.y.toInt and
      ctx.mouseY < (f.y + f.height).toInt

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
    self.state.handleKey(input, widget, ctx)
  if ctx.focused(widget.id):
    for text in ctx.textInputs:
      if text.len > 0 and text[0] >= ' ':
        self.state.insertText(text)

method measure*(self: LineInput, resources: Resources): IntrinsicSize =
  let measurement = resources.measureText(self.fontName, self.state.text)
  intrinsicSize(
    max(measurement.width + InputPaddingX * 2, InputMinWidth).toFloat,
    max(measurement.height + InputPaddingY * 2, InputMinHeight).toFloat,
  )

method draw*(self: LineInput, widget: Widget, ctx: DrawContext) =
  let
    f = widget.frame
    focused = ctx.focused(widget.id)
    hot = ctx.hot(widget.id)
    bg =
      if focused:
        ctx.palette.cardBackgroundHot
      elif hot:
        ctx.palette.panelMuted
      else:
        ctx.palette.cardBackground
    border =
      if focused:
        ctx.palette.cardAccent
      else:
        ctx.palette.cardBorder
    (font, _) = ctx.resources.get(self.fontName)

  fillRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), bg)
  drawLine(f.x.toInt, f.y.toInt, (f.x + f.width - 1).toInt, f.y.toInt, border)
  drawLine(
    f.x.toInt,
    (f.y + f.height - 1).toInt,
    (f.x + f.width - 1).toInt,
    (f.y + f.height - 1).toInt,
    border,
  )
  drawLine(f.x.toInt, f.y.toInt, f.x.toInt, (f.y + f.height - 1).toInt, border)
  drawLine(
    (f.x + f.width - 1).toInt,
    f.y.toInt,
    (f.x + f.width - 1).toInt,
    (f.y + f.height - 1).toInt,
    border,
  )

  discard drawText(
    Font(font),
    f.x.toInt + InputPaddingX,
    f.y.toInt + InputPaddingY,
    self.state.text,
    ctx.palette.textColor,
    bg,
  )

  if focused:
    let beforeCursor =
      if self.state.cursor > 0:
        self.state.text[0 ..< self.state.cursor]
      else:
        ""
    let cursorX =
      f.x.toInt + InputPaddingX + ctx.resources.measureText(self.fontName, beforeCursor).width
    drawLine(
      cursorX,
      f.y.toInt + InputPaddingY,
      cursorX,
      (f.y + f.height).toInt - InputPaddingY,
      ctx.palette.textColor,
    )
