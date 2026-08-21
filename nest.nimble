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
  exec "env SDL_VIDEODRIVER=dummy nim c -r --path:src --nimcache:build/nimcache tests/test_owldsl.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r --path:src --nimcache:build/nimcache tests/test_widget.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r --path:src --nimcache:build/nimcache tests/test_events.nim"

task bench, "Run Nest benchmarks":
  exec "env SDL_VIDEODRIVER=dummy nim c -r --path:src --nimcache:build/nimcache tests/bench_network_dialog.nim"

requires "nim >= 2.2.10"
requires "https://github.com/dneumann42/owl"
requires "chroma"
requires "https://github.com/elcritch/kiwiberry"
requires "https://github.com/beef331/fungus.git"
requires "https://github.com/nim-lang/sdl3"

task docs, "Generate the API documentation into docs/api":
  exec "nim doc --project --index:on --outdir:docs/api src/nest.nim"

task docCoverage, "Fail unless every exported routine has a doc comment":
  exec "nim jsondoc --project --outdir:build/jsondoc src/nest.nim"
  exec "nim c -r --hints:off --nimcache:build/nimcache-doccoverage " &
    "-o:build/doccoverage scripts/doccoverage.nim build/jsondoc"

task gallery, "Build and run the component gallery":
  exec "nim c -r --nimcache:build/nimcache-gallery -o:build/gallery " &
    "apps/gallery/gallery.nim"
