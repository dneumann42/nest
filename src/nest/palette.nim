import uirelays

type Palette* = object
  primary*: Color
  background*: Color
  foreground*: Color
  textColor*: Color

proc init*(T: typedesc[Palette]): T =
  T(
    primary: color(0, 120, 70),
    background: color(10, 12, 21),
    foreground: color(220, 240, 210),
    textColor: color(255, 255, 250),
  )
