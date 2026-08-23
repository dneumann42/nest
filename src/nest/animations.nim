import std/math

const DefaultMaxOpacity* = 0.95

type
  AnimationCurve* = enum
    Linear
    EaseIn
    EaseOut
    EaseInOut
    SmoothStep
    Spring
    BackOut

  AnimationSpec* = object
    durationMs*: int
    curve*: AnimationCurve
    fromOpacity*, toOpacity*: float64
    fromScale*, toScale*: float64
    offsetX*, offsetY*: float64

  AnimationValue* = object
    progress*: float64
    opacity*: float64
    scale*: float64
    offsetX*, offsetY*: float64
    running*: bool

proc clamp01*(value: float64): float64 =
  min(max(value, 0.0), 1.0)

proc lerp(a, b, t: float64): float64 =
  a + (b - a) * t

proc fadeIn*(
    durationMs = 160,
    curve = EaseOut,
    maxOpacity = DefaultMaxOpacity,
): AnimationSpec =
  AnimationSpec(
    durationMs: durationMs,
    curve: curve,
    fromOpacity: 0.0,
    toOpacity: maxOpacity,
    fromScale: 1.0,
    toScale: 1.0,
  )

proc scaleIn*(
    durationMs = 180,
    curve = BackOut,
    fromScale = 0.96,
    fromOpacity = 0.0,
    maxOpacity = DefaultMaxOpacity,
): AnimationSpec =
  AnimationSpec(
    durationMs: durationMs,
    curve: curve,
    fromOpacity: fromOpacity,
    toOpacity: maxOpacity,
    fromScale: fromScale,
    toScale: 1.0,
  )

proc slideIn*(
    durationMs = 180,
    curve = EaseOut,
    offsetX = 0.0,
    offsetY = 8.0,
    maxOpacity = DefaultMaxOpacity,
): AnimationSpec =
  AnimationSpec(
    durationMs: durationMs,
    curve: curve,
    fromOpacity: 0.0,
    toOpacity: maxOpacity,
    fromScale: 1.0,
    toScale: 1.0,
    offsetX: offsetX,
    offsetY: offsetY,
  )

proc dialogPopIn*(durationMs = 180, maxOpacity = DefaultMaxOpacity): AnimationSpec =
  AnimationSpec(
    durationMs: durationMs,
    curve: BackOut,
    fromOpacity: 0.0,
    toOpacity: maxOpacity,
    fromScale: 0.94,
    toScale: 1.0,
    offsetX: 0.0,
    offsetY: 6.0,
  )

proc eased*(curve: AnimationCurve, t: float64): float64 =
  let x = t.clamp01()
  case curve
  of Linear:
    x
  of EaseIn:
    x * x
  of EaseOut:
    1.0 - (1.0 - x) * (1.0 - x)
  of EaseInOut:
    if x < 0.5: 2.0 * x * x else: 1.0 - pow(-2.0 * x + 2.0, 2.0) / 2.0
  of SmoothStep:
    x * x * (3.0 - 2.0 * x)
  of Spring:
    let decay = pow(2.0, -10.0 * x)
    (1.0 - decay * cos(x * 6.0 * PI)).clamp01()
  of BackOut:
    let c1 = 1.70158
    let c3 = c1 + 1.0
    1.0 + c3 * pow(x - 1.0, 3.0) + c1 * pow(x - 1.0, 2.0)

proc valueAt*(spec: AnimationSpec, progress: float64, running = false): AnimationValue =
  let t = spec.curve.eased(progress)
  AnimationValue(
    progress: progress.clamp01(),
    opacity: lerp(spec.fromOpacity, spec.toOpacity, t).clamp01(),
    scale: max(lerp(spec.fromScale, spec.toScale, t), 0.0001),
    offsetX: lerp(spec.offsetX, 0.0, t),
    offsetY: lerp(spec.offsetY, 0.0, t),
    running: running,
  )
