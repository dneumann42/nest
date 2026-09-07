## Protocol code shared by Nest's SDL and headless Wayland backends.
## Keeping the compile pragmas in one module prevents duplicate interface
## symbols when an application imports both APIs through `nest`.

{.compile: "../wayland/wlr-layer-shell-unstable-v1-protocol.c".}
{.compile: "../wayland/xdg-shell-protocol.c".}
