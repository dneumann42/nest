import nest/[owldsl, dialogs, layerShellSdl3Driver]
import nest/[backend, screen]
import nest/perf

type AppConfig* = object
  title*: string
  width*, height*: int
  layerShell*: bool
  layerShellConfig*: LayerShellConfig
  alwaysRun60Fps*: bool
  themeName*: string
  perfOptions*: PerfOptions

proc init*(
    T: typedesc[AppConfig],
    width = 800,
    height = 600,
    title = "Nest",
    alwaysRun60Fps = false,
): T =
  ## Build the configuration for an ordinary application window.
  ##
  ## `alwaysRun60Fps` opts out of Nest's event-driven redraws and keeps the
  ## main loop running at a fixed frame rate, which suits continuously
  ## animating apps and benchmarks.
  T(
    title: title,
    width: width,
    height: height,
    layerShellConfig: layerShellSdl3Driver.dockTop(height.Positive),
    alwaysRun60Fps: alwaysRun60Fps,
    themeName: "",
  )

proc layerShell*(cfg: AppConfig, config: LayerShellConfig): AppConfig =
  ## Return `cfg` turned into a layer-shell surface described by `config`.
  result = cfg
  result.layerShell = true
  result.layerShellConfig = config

proc dockTop*(
    T: typedesc[AppConfig], height: Positive, title = "Nest", namespace = "nest"
): T =
  ## Configure a layer-shell bar docked to the top edge of the screen,
  ## `height` pixels tall and as wide as the output.
  AppConfig.init(width = 1, height = height, title = title).layerShell(
    layerShellSdl3Driver.dockTop(height, namespace)
  )

proc dockBottom*(
    T: typedesc[AppConfig], height: Positive, title = "Nest", namespace = "nest"
): T =
  ## Configure a layer-shell bar docked to the bottom edge of the screen,
  ## `height` pixels tall and as wide as the output.
  AppConfig.init(width = 1, height = height, title = title).layerShell(
    layerShellSdl3Driver.dockBottom(height, namespace)
  )

proc dockLeft*(
    T: typedesc[AppConfig], width: Positive, title = "Nest", namespace = "nest"
): T =
  ## Configure a layer-shell bar docked to the left edge of the screen,
  ## `width` pixels wide and as tall as the output.
  AppConfig.init(width = width, height = 1, title = title).layerShell(
    layerShellSdl3Driver.dockLeft(width, namespace)
  )

proc dockRight*(
    T: typedesc[AppConfig], width: Positive, title = "Nest", namespace = "nest"
): T =
  ## Configure a layer-shell bar docked to the right edge of the screen,
  ## `width` pixels wide and as tall as the output.
  AppConfig.init(width = width, height = 1, title = title).layerShell(
    layerShellSdl3Driver.dockRight(width, namespace)
  )

proc overlayDialog*(
    T: typedesc[AppConfig],
    width: Positive,
    height: Positive,
    title = "Nest Dialog",
    namespace = "nest-dialog",
    draggable = false,
): T =
  ## Configure a floating overlay dialog of `width` by `height` pixels.
  ##
  ## The surface sits on the overlay layer, takes keyboard focus on demand
  ## and claims no exclusive zone. `draggable` anchors it to the top-left
  ## corner so the app can move it by changing the surface margins.
  var layerConfig = LayerShellConfig(
      namespace: namespace,
      layer: LayerOverlay,
      anchors: {},
      exclusiveZone: -1,
      keyboard: KeyboardOnDemand,
    )
  if draggable:
    # An anchored surface can be repositioned by changing its margins.
    layerConfig.anchors = {EdgeTop, EdgeLeft}
    layerConfig.marginTop = 96
    layerConfig.marginLeft = 96
  AppConfig.init(width = width, height = height, title = title).layerShell(layerConfig)

proc initWindow*(cfg: AppConfig): ScreenLayout =
  ## Open the window described by `cfg` and return its screen layout.
  ##
  ## Initialises either the layer-shell or the ordinary window backend,
  ## installs the file and directory pickers used by the owl runtime, and
  ## applies the configured window title.
  if cfg.layerShell:
    layerShellSdl3Driver.layerShellConfig = cfg.layerShellConfig
    initLayerShellSdl3Driver()
  else:
    initBackend()
  owldsl.runtimeWake = layerShellSdl3Driver.wakeEventLoop
  result = createWindow(cfg.width, cfg.height)
  owldsl.pickFileDialog = proc(callback: PathSelectedProc) {.closure, raises: [].} =
    try:
      dialogs.browse(callback, window = layerShellSdl3Driver.currentSdlWindow())
    except CatchableError:
      discard
  owldsl.pickDirectoryDialog = proc(callback: PathSelectedProc) {.closure,
      raises: [].} =
    try:
      dialogs.browseFolder(callback, window = layerShellSdl3Driver.currentSdlWindow())
    except CatchableError:
      discard
  setWindowTitle(cfg.title)
