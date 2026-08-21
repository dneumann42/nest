import ../[resources, widgets2]
import component
import editors

type
  LineInputState* = EditorState

  LineInput* = ref object of Interactive
    editor: Editor

proc new*(T: typedesc[LineInput], state: LineInputState, fontName = "font"): T =
  ## Create a single-line text input editing `state` in the font `fontName`.
  T(editor: Editor.new(state, fontName, singleLine = true))

method update*(self: LineInput, widget: Widget, ctx: var UpdateContext) =
  ## Forward this frame's input to the underlying editor.
  self.editor.update(widget, ctx)

method measure*(self: LineInput, resources: Resources): IntrinsicSize =
  ## Return the size of one line of text in the input's font.
  self.editor.measure(resources)

method draw*(self: LineInput, widget: Widget, ctx: var DrawContext) =
  ## Draw the input's text, selection and caret.
  self.editor.draw(widget, ctx)
