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
  exec "nim c -r --path:src --nimcache:build/nimcache tests/test_resize_pacing.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r --path:src --nimcache:build/nimcache tests/test_ui.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r --path:src --nimcache:build/nimcache tests/test_owldsl.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r --path:src --nimcache:build/nimcache tests/test_widget.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r --path:src --nimcache:build/nimcache tests/test_events.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r --path:src --nimcache:build/nimcache tests/test_layout_reuse.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r --path:src --nimcache:build/nimcache tests/test_resize_fastpath.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r --path:src --nimcache:build/nimcache tests/test_frame_pacing.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r --path:src --nimcache:build/nimcache tests/test_signal_wake.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r --path:src --nimcache:build/nimcache tests/test_scroll_culling.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r --path:src --nimcache:build/nimcache tests/test_scroll_settle.nim"
  exec "dbus-run-session -- nim c -r --path:src --nimcache:build/nimcache tests/test_tray_dbus.nim"

task bench, "Run Nest benchmarks":
  exec "env SDL_VIDEODRIVER=dummy nim c -r -d:release --path:src --nimcache:build/nimcache-bench tests/bench_network_dialog.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r -d:release --path:src --nimcache:build/nimcache-bench tests/bench_resize.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r -d:release --path:src --nimcache:build/nimcache-bench tests/bench_idle.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r -d:release --path:src --nimcache:build/nimcache-bench tests/bench_scroll.nim"

task profile, "Run the Nest benchmarks with per-phase instrumentation":
  ## The same benchmarks built with -d:nestBench, which prints a zone
  ## breakdown of every scenario. Add -d:nestBenchDetail for per-widget zones.
  exec "env SDL_VIDEODRIVER=dummy nim c -r -d:release -d:nestBench --path:src " &
    "--nimcache:build/nimcache-profile tests/bench_resize.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r -d:release -d:nestBench --path:src " &
    "--nimcache:build/nimcache-profile tests/bench_idle.nim"
  exec "env SDL_VIDEODRIVER=dummy nim c -r -d:release -d:nestBench --path:src " &
    "--nimcache:build/nimcache-profile tests/bench_scroll.nim"

requires "nim >= 2.2.10"
requires "https://github.com/dneumann42/owl#head"
requires "chroma"
requires "https://github.com/elcritch/kiwiberry"
requires "https://github.com/nim-lang/sdl3#e5f87eb992f828419aad83075ea1c41147fbb088"
requires "https://github.com/zielmicha/nim-dbus#9aedf3c455554ccef2c7741d2379f5af0ac85e55"

task docs, "Generate the API documentation into docs/api":
  exec "nim doc --project --index:on --outdir:docs/api src/nest.nim"

task docCoverage, "Fail unless every exported routine has a doc comment":
  exec "nim jsondoc --project --outdir:build/jsondoc src/nest.nim"
  exec "nim c -r --hints:off --nimcache:build/nimcache-doccoverage " &
    "-o:build/doccoverage scripts/doccoverage.nim build/jsondoc"

task gallery, "Build and run the component gallery":
  exec "nim c -r --nimcache:build/nimcache-gallery -o:build/gallery " &
    "apps/gallery/gallery.nim"
