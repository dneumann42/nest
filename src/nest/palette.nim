import uirelays

type Palette* = object
  primary*: Color
  background*: Color
  backgroundHot*: Color
  backgroundActive*: Color
  foreground*: Color
  textColor*: Color

proc init*(T: typedesc[Palette]): T =
  T(
    primary: color(0, 120, 70),
    background: color(20, 22, 21),
    backgroundHot: color(50, 62, 61),
    backgroundActive: color(50, 162, 161),
    foreground: color(220, 240, 210),
    textColor: color(255, 255, 250),
  )
