import std/[strformat, strutils, times]

import owl
import nest/[owldsl, screen, ui]

proc installFonts() =
  fontRelays = FontRelays(
    openFont: proc(path: string, size: int, metrics: var FontMetrics): Font =
    metrics = FontMetrics(ascent: 14, descent: 4, lineHeight: 22)
    Font(1),
    closeFont: proc(f: Font) =
    discard,
    getFontMetrics: proc(f: Font): FontMetrics =
    FontMetrics(ascent: 14, descent: 4, lineHeight: 22),
    measureText: proc(f: Font; text: string): TextExtent =
    TextExtent(w: max(text.len, 1) * 9, h: 18),
    drawText: proc(f: Font; x, y: int; text: string; fg,
        bg: Color): TextExtent =
    TextExtent(w: max(text.len, 1) * 9, h: 18),
  )

proc wifiRows(count: int): string =
  for i in 0 ..< count:
    if result.len > 0:
      result.add '\n'
    let selected = if i == 0: "yes" else: "no"
    result.add &"network\tssid-{i:03d}\t{selected}\tssid-{i:03d}  {30 + i mod 70}%  WPA2"

proc profileRows(count: int): string =
  for i in 0 ..< min(count, 80):
    if result.len > 0:
      result.add '\n'
    result.add &"profile\tssid-{i:03d}"

proc shellValue(key: string; rows: int): string =
  if key.contains("available"):
    "yes"
  elif key.contains("wifi-radio"):
    "enabled"
  elif key.contains("active-ssid"):
    "ssid-000"
  elif key.contains("status"):
    "Wi-Fi ssid-000 on wlan0\nEthernet offline"
  elif key.contains("wifi-list"):
    wifiRows(rows)
  elif key.contains("profiles"):
    profileRows(rows)
  elif key.contains("ethernet"):
    "device\teth0\tdisconnected\twired"
  else:
    ""

proc valueText(value: Value): string =
  case value.kind
  of Text:
    value.text
  of Number:
    $value.number
  of Boolean:
    if value.boolean: "true" else: "false"
  of Native:
    if value.native of WidgetIDValue:
      let widget = WidgetIDValue(value.native)
      if widget.key.len > 0:
        widget.key
      else:
        $widget.value
    else:
      $value
  else:
    $value

proc installShellStubs(runtime: NestOwlRuntime; rows: int) =
  runtime.evaluator.native "shell":
    discard layout
    discard bodyNodes
    if arguments.len == 0:
      return text("")
    text(shellValue(env.eval(arguments[0]).valueText, rows))
  runtime.evaluator.native "shellAsync":
    discard layout
    discard bodyNodes
    if arguments.len == 0:
      return text("")
    text(shellValue(env.eval(arguments[0]).valueText, rows))

proc runCase(rows, frames: int) =
  let app = NestOwlApp.init("apps/layerShellBar/network/main.owl")
  app.runtime.installShellStubs(rows)
  var ui = UI.init()
  ui.initContext(620, 520)
  ui.loadFont("font", "", 18)
  ui.loadFont("editor", "", 18)
  let started = epochTime()
  for _ in 0 ..< frames:
    app.render(ui)
  let elapsed = epochTime() - started
  let frameMs = elapsed * 1000.0 / frames.float64
  echo &"rows={rows} frames={frames} totalMs={elapsed * 1000.0:.2f} frameMs={frameMs:.3f} fps={1000.0 / frameMs:.1f}"

when isMainModule:
  installFonts()
  for rows in [0, 20, 100, 300]:
    runCase(rows, 240)
