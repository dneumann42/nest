# Package

version = "0.0.0"
author = "dneumann42"
description = "A new awesome nimble package"
license = "GPL-3.0-or-later"
srcDir = "src"
bin = @["nest"]

# Dependencies

task test, "Run the Nest test suite":
  exec "nim c -r --path:src --nimcache:build/nimcache tests/test_layout.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r --path:src --nimcache:build/nimcache tests/test_ui.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r --path:src --nimcache:build/nimcache tests/test_crowdsl.nim"

requires "nim >= 2.2.10"
requires "crow"
requires "chroma"
requires "https://github.com/elcritch/kiwiberry"
requires "https://github.com/beef331/fungus.git"
requires "https://github.com/nim-lang/uirelays"
requires "https://github.com/nim-lang/sdl3"
