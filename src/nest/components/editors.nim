# TODO need to have a cursor that navigates syntax nodes over line and character,
# then give it a method that returns line and character for rendering or editing
type
  EditorCursor* = object
    index*: int

  EditorState* = ref object
    text*: string

  Editor* = ref object of Interactive
    state: EditorState
    fontName: string

proc new*(T: typedesc[EditorState], text = ""): T =
  T(text: text)

proc new*(T: typedesc[Editor], state: EditorState, fontName = "font"): T =
  T(state: state, fontName: fontName)

method update*(self: Editor, widget: Widget, ctx: var UpdateContext) =
  discard

proc getFrameStyle*(hot, focused: bool): tuple[bg, border: Color] =
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

method draw*(self: Editor, widget: Widget, ctx: DrawContext) =
  let
    f = widget.frame
    focused = ctx.focused(widget.id)
    hot = ctx.hot(widget.id)
    (bg, border) = getFrameStyle(hot, focused)
    (font, _) = ctx.resources.get(self.fontName)
  fillRect(rect(f.x.toInt, f.y.toInt, f.width.toInt, f.height.toInt), bg)
