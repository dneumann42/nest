type
  Rect* = object
    x*, y*: int
    w*, h*: int

  Point* = object
    x*, y*: int

  GlobalPos* = object
    x*, y*, z*: int
    t*: int

proc rect*(x, y, w, h: int): Rect =
  ## Construct a `Rect` from its top-left corner and its size.
  Rect(x: x, y: y, w: w, h: h)

proc point*(x, y: int): Point =
  ## Construct a `Point` from x/y window coordinates.
  Point(x: x, y: y)

proc contains*(r: Rect; p: Point): bool =
  ## Test whether `p` falls inside `r`. The left and top edges are inclusive,
  ## the right and bottom edges exclusive.
  p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h
