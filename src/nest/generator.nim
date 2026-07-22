import std/os

proc writeProjectFile(path, content: string) =
  if fileExists(path):
    quit("Refusing to overwrite existing file: " & path)
  writeFile(path, content)

proc generateProject*(projectDir: string) =
  let dir = projectDir.normalizedPath
  if not dirExists(dir):
    createDir(dir)

  writeProjectFile(
    dir / "project.nest",
    """main = "main.nest"
title = "Nest App"
width = 800
height = 600
layerShell = "none"
namespace = "nest-app"
exclusiveZone = -1
marginTop = 0
marginRight = 0
marginBottom = 0
marginLeft = 0
""",
  )
  writeProjectFile(
    dir / "main.nest",
    """define:
  count = 0
  rootID = id
  titleID = id
  decrementID = (id "decrement")
  incrementID = (id "increment")
events:
  when (clicked decrementID):
    -= count 1
  when (clicked incrementID):
    += count 1
panel rootID:
  width = fill
  height = fill
  gap = 12.0
  padding = 16.0
  alignItems = AlignCenter
  justifyContent = JustifyCenter
  label titleID "Counter":
    width = fit
    height = fit
  row (id "controls"):
    width = fit
    height = fit
    gap = 8
    button decrementID "-":
      width = (fixed 32)
      height = fit
    label (id "count") count:
      width = (fixed 80)
      height = fit
    button incrementID "+":
      width = (fixed 32)
      height = fit
""",
  )
  echo "Created Nest project in " & dir
