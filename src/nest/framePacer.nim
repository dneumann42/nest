type FramePacer* = object
  firstFrame: bool
  nextFrameTicks*: int
  frameRemainder: int

proc init*(T: typedesc[FramePacer]): T =
  T(firstFrame: true)

proc takeFirstFrame*(pacer: var FramePacer): bool =
  if pacer.firstFrame:
    pacer.firstFrame = false
    result = true

proc beginFixedFrame*(pacer: var FramePacer; frameTicks, now: int) =
  if pacer.nextFrameTicks == 0 or now > pacer.nextFrameTicks + frameTicks:
    pacer.nextFrameTicks = now

proc finishFixedFrame*(
    pacer: var FramePacer; frameNumerator, frameDenominator, now: int
) =
  pacer.frameRemainder += frameNumerator
  let frameTicks = max(pacer.frameRemainder div frameDenominator, 1)
  pacer.frameRemainder = pacer.frameRemainder mod frameDenominator
  if pacer.nextFrameTicks == 0:
    pacer.nextFrameTicks = now + frameTicks
  else:
    pacer.nextFrameTicks += frameTicks
    if now > pacer.nextFrameTicks + frameTicks:
      pacer.nextFrameTicks = now + frameTicks
