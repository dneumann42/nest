import std/strformat
import nest
import nest/screen

proc stubFonts() =
  fontRelays = FontRelays(
    openFont: proc(path: string, size: int, metrics: var FontMetrics): Font =
      metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
      Font(size),
    closeFont: proc(f: Font) = discard,
    getFontMetrics: proc(f: Font): FontMetrics =
      FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
    measureText: proc(f: Font, text: string): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
    drawText: proc(f: Font, x, y: int, text: string, fg, bg: Color): TextExtent =
      TextExtent(w: max(text.len, 1) * 9, h: 18),
  )

proc dump(ui: UI, what: string, id: WidgetID) =
  let located = ui.widgetFrame(id)
  if located.ok:
    let f = located.frame
    echo &"  {what:<26} x={f.x:6.0f} y={f.y:6.0f} w={f.width:6.0f} h={f.height:6.0f}"
  else:
    echo &"  {what:<26} (no frame)"

proc main() =
  stubFonts()
  var state = LineInputState.new("hi")
  for rowWidth in ["fit", "fill"]:
    var ui = UI.init()
    ui.initContext(400, 300)
    ui.loadFont("font", "", 18)
    for i in 0 .. 1:
      ui.beginInputFrame()
      ui.markAllDirty()
      ui.layout:
        ui.column(ui.id("root"), cfg(width = fill(), height = fit(), gap = 6,
            padding = 8)):
          ui.row(ui.id("row"), cfg(
              width = (if rowWidth == "fit": fit() else: fill()),
              height = fit(), gap = 6)):
            ui.label(ui.id("label"), "Name", fit(), fit())
            ui.lineInput(ui.id("fillInput"), state, fill(min = 160), fit())
          ui.row(ui.id("row2"), cfg(
              width = (if rowWidth == "fit": fit() else: fill()),
              height = fit(), gap = 6)):
            ui.label(ui.id("label2"), "Name", fit(), fit())
            ui.lineInput(ui.id("fitInput"), state, fit(), fit())
      ui.finishInputFrame()
    echo &"row width = {rowWidth}"
    ui.dump("row (fill input)", ui.id("row"))
    ui.dump("  lineInput fill()", ui.id("fillInput"))
    ui.dump("row2 (fit input)", ui.id("row2"))
    ui.dump("  lineInput fit()", ui.id("fitInput"))

main()
