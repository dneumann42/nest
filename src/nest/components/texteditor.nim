type
  TextEditorState* = ref object
    text*: string

  TextEditor* = ref object of Interactive
    state: TextEditorState
    fontName: string

proc new*(T: typedesc[TextEditorState], text = ""): T =
  T(text: text)

proc new*(T: typedesc[TextInput], state: TextEditorState, fontName = "font"): T =
  T(state: state, fontName: fontName)

method update*(self: TextEditor, widget: Widget, ctx: var UpdateContext) =
  discard
