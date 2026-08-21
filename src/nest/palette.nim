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

proc dark*(T: typedesc[Palette]): T =
  ## Return Nest's built-in dark palette.
  let t: uint8 = 8
  T(
    primary: color(79, 185, 154),
    primaryStrong: color(110, 219, 188),
    rose: color(222, 116, 139),
    mauve: color(178, 139, 222),
    sky: color(104, 184, 222),
    lilac: color(145, 139, 232),
    peach: color(225, 158, 104),
    butter: color(226, 196, 92),
    background: color(28, 31, 34),
    backgroundHot: color(42, 48, 52),
    backgroundActive: color(48, 120, 105),
    buttonBorder: color(67, 78, 84),
    buttonBorderHot: color(96, 124, 127),
    buttonBorderActive: color(110, 219, 188),
    buttonHighlight: color(55, 61, 65),
    panelBackground: color(20, 23, 26),
    panelBorder: color(68, 79, 86),
    panelMuted: color(35, 40, 44),
    # cardBackground: color(31, 36, 40),
    # cardBackgroundHot: color(43, 50, 55),

    cardBackground: color(31 + t, 36 + t, 40 + t),
    cardBackgroundHot: color(43 + t, 50 + t, 55 + t),
    cardBorder: color(84, 100, 108),
    cardAccent: color(79, 185, 154),
    dialogHeaderBackground: color(37, 43, 48),
    dialogHeaderBorder: color(92, 126, 126),
    foreground: color(203, 213, 217),
    textColor: color(241, 246, 247),
  )

proc light*(T: typedesc[Palette]): T =
  ## Return Nest's built-in light palette.
  T(
    primary: color(25, 132, 112),
    primaryStrong: color(17, 105, 91),
    rose: color(188, 75, 96),
    mauve: color(135, 94, 181),
    sky: color(47, 133, 172),
    lilac: color(92, 91, 184),
    peach: color(188, 111, 52),
    butter: color(159, 124, 21),
    background: color(238, 242, 240),
    backgroundHot: color(226, 234, 231),
    backgroundActive: color(182, 225, 215),
    buttonBorder: color(184, 198, 197),
    buttonBorderHot: color(125, 160, 157),
    buttonBorderActive: color(25, 132, 112),
    buttonHighlight: color(250, 252, 251),
    panelBackground: color(248, 250, 249),
    panelBorder: color(201, 213, 211),
    panelMuted: color(230, 236, 234),
    cardBackground: color(255, 255, 255),
    cardBackgroundHot: color(241, 247, 245),
    cardBorder: color(199, 213, 211),
    cardAccent: color(25, 132, 112),
    dialogHeaderBackground: color(232, 239, 237),
    dialogHeaderBorder: color(184, 202, 198),
    foreground: color(81, 92, 96),
    textColor: color(23, 30, 34),
  )

proc fallback*(T: typedesc[Palette]): T =
  ## Return the palette used when no theme has been chosen: the dark one.
  Palette.dark()

proc theme*(T: typedesc[Palette], name: string): T =
  ## Return the built-in palette called `name`.
  ##
  ## `light` and `dark` select those palettes, an empty name means dark, and
  ## an unrecognised name falls back to `Palette.fallback()`. Matching
  ## ignores case and underscores.
  case name.normalize
  of "light":
    Palette.light()
  of "dark", "":
    Palette.dark()
  else:
    Palette.fallback()

proc parseHexColor(value: string, fallback: Color): Color =
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

proc jsonColor(node: JsonNode, name: string, fallback: Color): Color =
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
  ## Return `fallback` with the colors of the wallust/alatar theme file
  ## applied on top.
  ##
  ## `fallback` is returned untouched when the theme file is missing or
  ## cannot be parsed.
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
    result.background = palette.jsonColor("background", result.background)
    result.backgroundHot = palette.jsonColor("background_hot", result.backgroundHot)
    result.backgroundActive =
      palette.jsonColor("background_active", result.backgroundActive)
    result.buttonBorder = palette.jsonColor("button_border", result.buttonBorder)
    result.buttonBorderHot =
      palette.jsonColor("button_border_hot", result.buttonBorderHot)
    result.buttonBorderActive =
      palette.jsonColor("button_border_active", result.buttonBorderActive)
    result.buttonHighlight =
      palette.jsonColor("button_highlight", result.buttonHighlight)
    result.panelBackground =
      palette.jsonColor("panel_background", result.panelBackground)
    result.panelBorder = palette.jsonColor("panel_border", result.panelBorder)
    result.panelMuted = palette.jsonColor("panel_muted", result.panelMuted)
    result.cardBackground = palette.jsonColor("card_background", result.cardBackground)
    result.cardBackgroundHot =
      palette.jsonColor("card_background_hot", result.cardBackgroundHot)
    result.cardBorder = palette.jsonColor("card_border", result.cardBorder)
    result.cardAccent = palette.jsonColor("card_accent", result.cardAccent)
    result.dialogHeaderBackground =
      palette.jsonColor("dialog_header_background", result.dialogHeaderBackground)
    result.dialogHeaderBorder =
      palette.jsonColor("dialog_header_border", result.dialogHeaderBorder)
    result.foreground = colors.jsonColor("foreground", result.foreground)
    result.textColor = colors.jsonColor("foreground", result.textColor)
  except CatchableError:
    result = fallback

proc init*(T: typedesc[Palette]): T =
  ## Return the palette Nest starts with: the fallback palette with the
  ## wallust theme applied when the user has one.
  Palette.fallback().loadWallustTheme()

proc init*(T: typedesc[Palette], themeName: string): T =
  ## Return the palette for the configured `themeName`.
  ##
  ## An empty name, `wallust` or `alatar` load the user's wallust theme over
  ## the fallback palette; any other name selects a built-in palette.
  case themeName.normalize
  of "", "wallust", "alatar":
    Palette.fallback().loadWallustTheme()
  else:
    Palette.theme(themeName)

proc colorByName*(self: Palette, name: string, fallback: Color): Color =
  ## Return the palette color called `name`, or `fallback` when the palette
  ## has no such color.
  ##
  ## Names ignore case and accept `-` or `_` between words, so
  ## `primaryStrong`, `primary-strong` and `primary_strong` all match.
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
  of "background":
    self.background
  of "backgroundhot", "background-hot", "background_hot":
    self.backgroundHot
  of "backgroundactive", "background-active", "background_active":
    self.backgroundActive
  of "buttonborder", "button-border", "button_border":
    self.buttonBorder
  of "buttonborderhot", "button-border-hot", "button_border_hot":
    self.buttonBorderHot
  of "buttonborderactive", "button-border-active", "button_border_active":
    self.buttonBorderActive
  of "buttonhighlight", "button-highlight", "button_highlight":
    self.buttonHighlight
  of "panel", "panelbackground", "panel-background", "panel_background":
    self.panelBackground
  of "panelborder", "panel-border", "panel_border":
    self.panelBorder
  of "panelmuted", "panel-muted", "panel_muted":
    self.panelMuted
  of "card", "cardbackground", "card-background", "card_background":
    self.cardBackground
  of "cardbackgroundhot", "card-background-hot", "card_background_hot":
    self.cardBackgroundHot
  of "cardborder", "card-border", "card_border":
    self.cardBorder
  of "cardaccent", "card-accent", "card_accent":
    self.cardAccent
  of "dialogheader", "dialogheaderbackground", "dialog-header-background",
      "dialog_header_background":
    self.dialogHeaderBackground
  of "dialogheaderborder", "dialog-header-border", "dialog_header_border":
    self.dialogHeaderBorder
  else:
    fallback
