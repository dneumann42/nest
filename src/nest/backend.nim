import layerShellSdl3Driver

proc initBackend*() =
  ## Initialise the SDL3 backend used for ordinary desktop windows.
  initSdl3Driver()
