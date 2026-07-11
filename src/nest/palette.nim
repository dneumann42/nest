import uirelays

type Palette* = object
  primary*: Color
  background*: Color
  backgroundHot*: Color
  backgroundActive*: Color
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

proc init*(T: typedesc[Palette]): T =
  T(
    primary: color(0, 120, 70),
    background: color(20, 22, 21),
    backgroundHot: color(50, 62, 61),
    backgroundActive: color(50, 162, 161),
    panelBackground: color(27, 31, 32),
    panelBorder: color(61, 72, 71),
    panelMuted: color(38, 44, 45),
    cardBackground: color(34, 39, 41),
    cardBackgroundHot: color(47, 55, 57),
    cardBorder: color(82, 96, 96),
    cardAccent: color(0, 148, 112),
    dialogHeaderBackground: color(31, 37, 38),
    dialogHeaderBorder: color(91, 111, 109),
    foreground: color(220, 240, 210),
    textColor: color(255, 255, 250),
  )
