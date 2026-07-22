import ../[resources, widgets2]
import component
import editors

type
  LineInputState* = EditorState

  LineInput* = ref object of Interactive
    editor: Editor

proc new*(T: typedesc[LineInput], state: LineInputState, fontName = "font"): T =
  T(editor: Editor.new(state, fontName, singleLine = true))

method update*(self: LineInput, widget: Widget, ctx: var UpdateContext) =
  self.editor.update(widget, ctx)

method measure*(self: LineInput, resources: Resources): IntrinsicSize =
  self.editor.measure(resources)

method draw*(self: LineInput, widget: Widget, ctx: DrawContext) =
  self.editor.draw(widget, ctx)
