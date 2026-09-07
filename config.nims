--d:sdl3

# Load Atlas's generated dependency paths only in this checkout. Nimble copies
# nimble.paths into its temporary install tree, where its absolute source paths
# would mix the checkout with the staged package.
import std/[os, strutils]

const
  nestConfigDir = currentSourcePath().parentDir
  nestNimblePaths = nestConfigDir / "nimble.paths"
when system.fileExists(nestNimblePaths):
  if system.readFile(nestNimblePaths).contains(nestConfigDir):
    include "nimble.paths"

# Keep this package buildable when invoked from another project's directory.
switch("path", nestConfigDir / "src")
# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
