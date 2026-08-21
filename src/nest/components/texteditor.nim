type
  TextEditorState* = ref object
    text*: string

  TextEditor* = ref object of Interactive
    state: TextEditorState
    fontName: string

proc new*(T: typedesc[TextEditorState], text = ""): T =
  ## Create editor state holding `text`.
  T(text: text)

proc new*(T: typedesc[TextInput], state: TextEditorState, fontName = "font"): T =
  ## Create a text input over `state`, rendered in the font `fontName`.
  T(state: state, fontName: fontName)

method update*(self: TextEditor, widget: Widget, ctx: var UpdateContext) =
  ## Handle this frame's input.
  ##
  ## Nothing to do: editing is implemented by `Editor`, which `LineInput` and
  ## the multi-line editor widgets use.
  discard
