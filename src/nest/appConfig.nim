import nest/[crowdsl, dialogs, layerShellSdl3Driver]
import nest/[backend, screen]

type AppConfig* = object
  title*: string
  width*, height*: int
  layerShell*: bool
  layerShellConfig*: LayerShellConfig
  alwaysRun60Fps*: bool
  themeName*: string

proc init*(
    T: typedesc[AppConfig],
    width = 800,
    height = 600,
    title = "Nest",
    alwaysRun60Fps = false,
): T =
  T(
    title: title,
    width: width,
    height: height,
    layerShellConfig: layerShellSdl3Driver.dockTop(height.Positive),
    alwaysRun60Fps: alwaysRun60Fps,
    themeName: "",
  )

proc layerShell*(cfg: AppConfig, config: LayerShellConfig): AppConfig =
  result = cfg
  result.layerShell = true
  result.layerShellConfig = config

proc dockTop*(
    T: typedesc[AppConfig], height: Positive, title = "Nest", namespace = "nest"
): T =
  AppConfig.init(width = 1, height = height, title = title).layerShell(
    layerShellSdl3Driver.dockTop(height, namespace)
  )

proc dockBottom*(
    T: typedesc[AppConfig], height: Positive, title = "Nest", namespace = "nest"
): T =
  AppConfig.init(width = 1, height = height, title = title).layerShell(
    layerShellSdl3Driver.dockBottom(height, namespace)
  )

proc dockLeft*(
    T: typedesc[AppConfig], width: Positive, title = "Nest", namespace = "nest"
): T =
  AppConfig.init(width = width, height = 1, title = title).layerShell(
    layerShellSdl3Driver.dockLeft(width, namespace)
  )

proc dockRight*(
    T: typedesc[AppConfig], width: Positive, title = "Nest", namespace = "nest"
): T =
  AppConfig.init(width = width, height = 1, title = title).layerShell(
    layerShellSdl3Driver.dockRight(width, namespace)
  )

proc overlayDialog*(
    T: typedesc[AppConfig],
    width: Positive,
    height: Positive,
    title = "Nest Dialog",
    namespace = "nest-dialog",
): T =
  AppConfig.init(width = width, height = height, title = title).layerShell(
    LayerShellConfig(
      namespace: namespace,
      layer: LayerOverlay,
      anchors: {},
      exclusiveZone: -1,
      keyboard: KeyboardOnDemand,
    )
  )

proc initWindow*(cfg: AppConfig): ScreenLayout =
  if cfg.layerShell:
    layerShellSdl3Driver.layerShellConfig = cfg.layerShellConfig
    initLayerShellSdl3Driver()
  else:
    initBackend()
  crowdsl.runtimeWake = layerShellSdl3Driver.wakeEventLoop
  result = createWindow(cfg.width, cfg.height)
  crowdsl.pickFileDialog = proc(callback: PathSelectedProc) {.closure, raises: [].} =
    try:
      dialogs.browse(callback, window = layerShellSdl3Driver.currentSdlWindow())
    except CatchableError:
      discard
  crowdsl.pickDirectoryDialog = proc(callback: PathSelectedProc) {.closure, raises: [].} =
    try:
      dialogs.browseFolder(callback, window = layerShellSdl3Driver.currentSdlWindow())
    except CatchableError:
      discard
  setWindowTitle(cfg.title)
