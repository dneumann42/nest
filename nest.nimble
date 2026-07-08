# Package

version       = "0.0.0"
author        = "dneumann42"
description   = "A new awesome nimble package"
license       = "GPL-3.0-or-later"
srcDir        = "src"
bin           = @["nest"]


# Dependencies

requires "nim >= 2.2.10"

requires "https://github.com/elcritch/kiwiberry"

task test, "Run the Nest test suite":
  exec "nim c -r --path:src --nimcache:build/nimcache tests/test_layout.nim"

requires "https://github.com/beef331/fungus.git"