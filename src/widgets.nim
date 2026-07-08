import std/hashes

type
  WidgetID* = distinct string
  Widget = object
    x, y, width, height: int

proc hash*(id: WidgetID): Hash {.borrow.}
proc `==`*(a, b: WidgetID): bool {.borrow.}

using self: Widget

proc left*(self): auto =
  self.x

proc right*(self): auto =
  self.x + self.width

proc top*(self): auto =
  self.y

proc bottom*(self): auto =
  self.y + self.height

proc centerX*(self): auto =
  self.x + self.width div 2

proc centerY*(self): auto =
  self.y + self.height div 2

proc center*(self): tuple[x, y: typeof self.x] =
  (self.centerX, self.centerY)
