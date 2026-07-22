import std/[json, os, strutils]

import nest/screen

type Palette* = object
  primary*: Color
  primaryStrong*: Color
  rose*: Color
  mauve*: Color
  sky*: Color
  lilac*: Color
  peach*: Color
  butter*: Color
  background*: Color
  backgroundHot*: Color
  backgroundActive*: Color
  buttonBorder*: Color
  buttonBorderHot*: Color
  buttonBorderActive*: Color
  buttonHighlight*: Color
  panelBackground*: Color
  panelBorder*: Color
  panelMuted*: Color
  cardBackground*: Color
  cardBackgroundHot*: Color
  cardBorder*: Color
  cardAccent*: Color
  dialogHeaderBackground*: Color
  dialogHeaderBorder*: Color
  foreground*: Color
  textColor*: Color

proc fallback*(T: typedesc[Palette]): T =
  T(
    primary: color(56, 154, 126),
    primaryStrong: color(76, 189, 157),
    rose: color(166, 80, 95),
    mauve: color(140, 98, 168),
    sky: color(76, 164, 189),
    lilac: color(119, 106, 190),
    peach: color(190, 126, 76),
    butter: color(190, 166, 76),
    background: color(29, 32, 32),
    backgroundHot: color(44, 52, 51),
    backgroundActive: color(42, 112, 98),
    buttonBorder: color(73, 84, 82),
    buttonBorderHot: color(98, 125, 119),
    buttonBorderActive: color(76, 189, 157),
    buttonHighlight: color(57, 64, 63),
    panelBackground: color(23, 26, 27),
    panelBorder: color(68, 78, 77),
    panelMuted: color(36, 41, 42),
    cardBackground: color(31, 36, 37),
    cardBackgroundHot: color(45, 52, 53),
    cardBorder: color(86, 101, 99),
    cardAccent: color(58, 181, 145),
    dialogHeaderBackground: color(38, 44, 45),
    dialogHeaderBorder: color(92, 117, 111),
    foreground: color(220, 240, 210),
    textColor: color(255, 255, 250),
  )

proc parseHexColor(value: string; fallback: Color): Color =
  var text = value.strip
  if text.startsWith("#"):
    text = text[1 .. ^1]
  if text.len != 6 and text.len != 8:
    return fallback
  try:
    let parsed = parseHexInt(text)
    if text.len == 6:
      color(
        uint8((parsed shr 16) and 0xff),
        uint8((parsed shr 8) and 0xff),
        uint8(parsed and 0xff),
      )
    else:
      color(
        uint8((parsed shr 24) and 0xff),
        uint8((parsed shr 16) and 0xff),
        uint8((parsed shr 8) and 0xff),
        uint8(parsed and 0xff),
      )
  except ValueError:
    fallback

proc jsonColor(node: JsonNode; name: string; fallback: Color): Color =
  try:
    if node.kind == JObject and node.hasKey(name) and node[name].kind == JString:
      return parseHexColor(node[name].getStr, fallback)
  except KeyError:
    discard
  fallback

proc alatarThemePath(): string =
  let configHome = getEnv("XDG_CONFIG_HOME")
  if configHome.len > 0:
    configHome / "alatar" / "theme.json"
  else:
    getHomeDir() / ".config" / "alatar" / "theme.json"

proc loadWallustTheme*(fallback: Palette): Palette =
  result = fallback
  let path = alatarThemePath()
  if not fileExists(path):
    return
  try:
    let root = parseJson(readFile(path))
    if root.kind != JObject:
      return
    let colors =
      if root.hasKey("colors") and root["colors"].kind == JObject:
        root["colors"]
      else:
        newJObject()
    let palette =
      if root.hasKey("palette") and root["palette"].kind == JObject:
        root["palette"]
      else:
        newJObject()
    result.primary = palette.jsonColor("primary", result.primary)
    result.primaryStrong = palette.jsonColor("primary_strong", result.primaryStrong)
    result.rose = palette.jsonColor("rose", result.rose)
    result.mauve = palette.jsonColor("mauve", result.mauve)
    result.sky = palette.jsonColor("sky", result.sky)
    result.lilac = palette.jsonColor("lilac", result.lilac)
    result.peach = palette.jsonColor("peach", result.peach)
    result.butter = palette.jsonColor("butter", result.butter)
    result.foreground = colors.jsonColor("foreground", result.foreground)
    result.textColor = colors.jsonColor("foreground", result.textColor)
  except CatchableError:
    result = fallback

proc init*(T: typedesc[Palette]): T =
  Palette.fallback().loadWallustTheme()

proc colorByName*(self: Palette; name: string; fallback: Color): Color =
  case name.normalize
  of "primary":
    self.primary
  of "primarystrong", "primary-strong", "primary_strong":
    self.primaryStrong
  of "rose":
    self.rose
  of "mauve":
    self.mauve
  of "sky":
    self.sky
  of "lilac":
    self.lilac
  of "peach":
    self.peach
  of "butter":
    self.butter
  of "foreground":
    self.foreground
  of "text", "textcolor", "text-color", "text_color":
    self.textColor
  else:
    fallback
