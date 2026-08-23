import std/[math, tables]

import ../widgets2
import ../resources
import nest/screen

const ControlHeight* = 32
  ## The height a single-line control resolves to under a `fit` height
  ## policy: buttons, checkboxes, sliders, tabs, combo boxes and line
  ## inputs all measure at least this tall, so a row of mixed controls
  ## lines up without every call site naming a pixel height.

type
  CornerStyle* = enum
    FlatCorners
    RoundedCorners

  ComponentStyle* = object
    hasBackground*: bool
    background*: Color
    hasOpacity*: bool
    opacity*: float64
    cornerStyle*: CornerStyle
    cornerRadii*: CornerRadii
    hasShadow*: bool
    shadowColor*: Color
    shadowOffsetX*, shadowOffsetY*: float64
    shadowBlur*, shadowSpread*: float64

  Component* = ref object of RootObj
    style*: ComponentStyle
  Interactive* = ref object of Component
    hot, active: bool

  ShadowSpan = object
    x, y, w: int
    alpha: uint8

proc clamp(value, lo, hi: float64): float64 =
  min(max(value, lo), hi)

proc clampByte(value: int): uint8 =
  uint8(value.clamp(0, 255))

proc shadowCacheKey(width, height: int, radii: CornerRadii,
    blur, spread: int): string =
  $width & "x" & $height & "|" & $radii.topLeft.int & "," &
    $radii.topRight.int & "," & $radii.bottomRight.int & "," &
    $radii.bottomLeft.int & "|" & $blur & "|" & $spread

var shadowSpanCache = initTable[string, seq[ShadowSpan]]()

proc styledBackground*(component: Component, fallback: Color): Color =
  ## Return the component's own background colour, or `fallback` when its
  ## style does not set one.
  result =
    if component.style.hasBackground:
      component.style.background
    else:
      fallback
  if component.style.hasOpacity:
    result.a = uint8((component.style.opacity.clamp(0.0, 1.0) * 255.0 + 0.5).int)

proc radii*(radius: float64): CornerRadii =
  ## Return one radius applied to every corner.
  CornerRadii(
    topLeft: radius,
    topRight: radius,
    bottomRight: radius,
    bottomLeft: radius,
  )

proc expanded(radii: CornerRadii, amount: int): CornerRadii =
  CornerRadii(
    topLeft: max(radii.topLeft + amount.toFloat, 0),
    topRight: max(radii.topRight + amount.toFloat, 0),
    bottomRight: max(radii.bottomRight + amount.toFloat, 0),
    bottomLeft: max(radii.bottomLeft + amount.toFloat, 0),
  )

proc clampedRadius(radius: float64, w, h: int): int =
  radius.int.clamp(0, min(w, h) div 2)

proc radiusInset(radius, distance: int): int =
  if radius <= 0 or distance >= radius:
    return 0
  let dy = radius - distance
  radius - sqrt((radius * radius - dy * dy).float64).int

proc addRoundedSpans(
    spans: var seq[ShadowSpan],
    x, y, w, h: int,
    radii: CornerRadii,
    alpha: uint8,
) =
  if w <= 0 or h <= 0 or alpha == 0:
    return
  let
    tl = clampedRadius(radii.topLeft, w, h)
    tr = clampedRadius(radii.topRight, w, h)
    br = clampedRadius(radii.bottomRight, w, h)
    bl = clampedRadius(radii.bottomLeft, w, h)
  for row in 0 ..< h:
    let
      top = row
      bottom = h - 1 - row
      leftInset = max(radiusInset(tl, top), radiusInset(bl, bottom))
      rightInset = max(radiusInset(tr, top), radiusInset(br, bottom))
      spanW = w - leftInset - rightInset
    if spanW > 0:
      spans.add ShadowSpan(x: x + leftInset, y: y + row, w: spanW, alpha: alpha)

proc cachedShadowSpans(width, height: int, radii: CornerRadii,
    blur, spread: int): seq[ShadowSpan] =
  let key = shadowCacheKey(width, height, radii, blur, spread)
  if shadowSpanCache.hasKey(key):
    return shadowSpanCache[key]

  var spans: seq[ShadowSpan]
  let
    spreadPx = max(spread, 0)
    blurPx = max(blur, 0)
    maskW = width + spreadPx * 2
    maskH = height + spreadPx * 2
    shadowW = maskW + blurPx * 2
    shadowH = maskH + blurPx * 2
    maskRadii = radii.expanded(spreadPx)
  if shadowW <= 0 or shadowH <= 0:
    return

  var mask = newSeq[bool](maskW * maskH)
  var maskSpans: seq[ShadowSpan]
  maskSpans.addRoundedSpans(0, 0, maskW, maskH, maskRadii, 255)
  for span in maskSpans:
    for x in span.x ..< span.x + span.w:
      mask[span.y * maskW + x] = true

  proc insideMask(x, y: int): bool =
    x >= 0 and x < maskW and y >= 0 and y < maskH and mask[y * maskW + x]

  for y in 0 ..< shadowH:
    var
      runX = 0
      runAlpha = 0'u8
      hasRun = false
    for x in 0 ..< shadowW:
      let
        maskX = x - blurPx
        maskY = y - blurPx
      var alpha = 0'u8
      if insideMask(maskX, maskY):
        alpha = 255
      else:
        var best = blurPx + 1
        block search:
          for dy in -blurPx .. blurPx:
            for dx in -blurPx .. blurPx:
              let distance = sqrt((dx * dx + dy * dy).float64).int
              if distance < best and distance <= blurPx and
                  insideMask(maskX + dx, maskY + dy):
                best = distance
                if best == 0:
                  break search
        if best <= blurPx:
          let t = 1.0 - best.float64 / max(blurPx, 1).float64
          alpha = clampByte((255.0 * t * t + 0.5).int)

      if alpha == runAlpha:
        if not hasRun:
          runX = x
          hasRun = true
      else:
        if hasRun and runAlpha > 0:
          spans.add ShadowSpan(x: runX, y: y, w: x - runX, alpha: runAlpha)
        runX = x
        runAlpha = alpha
        hasRun = true
    if hasRun and runAlpha > 0:
      spans.add ShadowSpan(x: runX, y: y, w: shadowW - runX, alpha: runAlpha)
  shadowSpanCache[key] = spans
  spans

proc styledFillRect*(component: Component, r: Rect, color: Color) =
  ## Fill `r` using the component's corner style.
  case component.style.cornerStyle
  of FlatCorners:
    fillRect(r, color)
  of RoundedCorners:
    fillRoundedRect(r, component.style.cornerRadii, color)

proc drawShadow*(component: Component, r: Rect) =
  ## Draw the component's cached outer shadow behind `r`.
  if not component.style.hasShadow or r.w <= 0 or r.h <= 0:
    return
  let
    blur = max(component.style.shadowBlur.int, 0)
    spread = component.style.shadowSpread.int
    width = r.w
    height = r.h
    radii =
      if component.style.cornerStyle == RoundedCorners:
        component.style.cornerRadii
      else:
        CornerRadii()
    spans = cachedShadowSpans(width, height, radii, blur, spread)
    base = component.style.shadowColor
    originX = r.x + component.style.shadowOffsetX.toInt - blur - max(component.style.shadowSpread.int, 0)
    originY = r.y + component.style.shadowOffsetY.toInt - blur - max(component.style.shadowSpread.int, 0)
  if base.a == 0:
    return
  for span in spans:
    var c = base
    c.a = clampByte((base.a.int * span.alpha.int + 127) div 255)
    if c.a > 0:
      fillRect(rect(originX + span.x, originY + span.y, span.w, 1), c)

proc styledLineRect*(component: Component, r: Rect, color: Color) =
  ## Stroke `r` using the component's corner style.
  case component.style.cornerStyle
  of FlatCorners:
    lineRect(r, color)
  of RoundedCorners:
    lineRoundedRect(r, component.style.cornerRadii, color)

proc new*(T: typedesc[Component]): T =
  ## Create a bare component that measures, updates and draws as nothing.
  ##
  ## Useful as a placeholder and as the base for subclasses.
  T()

method update*(c: Component, widget: Widget, ctx: var UpdateContext) {.base.} =
  ## React to this frame's input for the widget the component is attached to.
  ##
  ## Called once per frame before drawing, with `widget` already laid out.
  ## Override to mark the widget hot, active or submitted, or to change the
  ## component's own state. Does nothing by default.
  discard

method measure*(c: Component, resources: Resources): IntrinsicSize {.base.} =
  ## Return the size the component's content wants, which a `fit` size
  ## policy resolves to.
  ##
  ## `resources` provides the font and image metrics needed to measure.
  ## Reports no intrinsic size by default.
  discard

method draw*(c: Component, widget: Widget, ctx: var DrawContext) {.base.} =
  ## Draw the component inside its widget's frame. Draws nothing by default.
  discard

method pointerShield*(
    c: Component, widget: Widget, windowWidth, windowHeight: int
): tuple[has: bool, frame: Frame] {.base.} =
  ## Return the area this component swallows pointer input over, above
  ## everything else in the frame.
  ##
  ## A component that draws outside its own box in `drawOverlay`, such as an
  ## open dropdown list, reports that area here. While the pointer is inside
  ## it, only this component and the widgets inside it see the pointer, so a
  ## click on the list cannot also land on whatever it covers. Shields
  ## nothing by default.
  discard

method drawOverlay*(c: Component, widget: Widget, ctx: var DrawContext) {.base.} =
  ## Draw the parts of the component that must appear above its siblings,
  ## such as an open dropdown list.
  ##
  ## Called after every component's `draw`. Draws nothing by default.
  discard
