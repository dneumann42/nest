import sdl3

export Window

type
  FileDialogFilter* = object
    name*, pattern*: string

  FileDialogResult* = object
    paths*: seq[string]
    selectedFilter*: int
    canceled*: bool

  FileDialogCallback* = proc(result: FileDialogResult)

  OpenFileDialogOptions* = object
    window*: Window
    defaultLocation*: string
    filters*: seq[FileDialogFilter]
    allowMany*: bool

  OpenFolderDialogOptions* = object
    window*: Window
    defaultLocation*: string
    allowMany*: bool

  DialogRequest = ref object
    callback: FileDialogCallback
    defaultLocation: string
    filters: seq[FileDialogFilter]
    sdlFilters: seq[DialogFileFilter]

var pendingRequests: seq[DialogRequest]
var lastDialogError* = ""

proc dialogError*(): string =
  lastDialogError

proc toSdlFilters(request: DialogRequest) =
  request.sdlFilters.setLen(request.filters.len)
  for i, filter in request.filters:
    request.sdlFilters[i] =
      DialogFileFilter(name: filter.name.cstring, pattern: filter.pattern.cstring)

proc removePending(request: DialogRequest) =
  let index = pendingRequests.find(request)
  if index >= 0:
    pendingRequests.delete(index)

proc collectPaths(filelist: cstringArray): seq[string] =
  if filelist.isNil:
    return

  var i = 0
  while not filelist[i].isNil:
    result.add $filelist[i]
    inc i

proc openFileCallback(
    userdata: pointer, filelist: cstringArray, filter: cint
) {.cdecl.} =
  let request = cast[DialogRequest](userdata)
  if filelist.isNil:
    lastDialogError = $sdl3.getError()
  let paths = collectPaths(filelist)
  if not request.callback.isNil:
    request.callback(
      FileDialogResult(
        paths: paths, selectedFilter: filter.int, canceled: paths.len == 0
      )
    )
  removePending(request)

proc showOpenFileDialog*(options: OpenFileDialogOptions, callback: FileDialogCallback) =
  discard sdl3.clearError()
  lastDialogError = ""
  var request = DialogRequest(
    callback: callback,
    defaultLocation: options.defaultLocation,
    filters: options.filters,
  )
  request.toSdlFilters()
  pendingRequests.add request

  let defaultLocation =
    if request.defaultLocation.len > 0: request.defaultLocation.cstring else: nil

  if request.sdlFilters.len > 0:
    sdl3.showOpenFileDialog(
      openFileCallback,
      cast[pointer](request),
      options.window,
      request.sdlFilters,
      defaultLocation,
      options.allowMany,
    )
  else:
    sdl3.showOpenFileDialog(
      openFileCallback,
      cast[pointer](request),
      options.window,
      nil,
      0,
      defaultLocation,
      options.allowMany,
    )
  let error = $sdl3.getError()
  if error.len > 0:
    lastDialogError = error

proc showOpenFileDialog*(
    callback: FileDialogCallback,
    defaultLocation = "",
    filters: openArray[FileDialogFilter] = [],
    allowMany = false,
    window: Window = nil,
) =
  showOpenFileDialog(
    OpenFileDialogOptions(
      window: window,
      defaultLocation: defaultLocation,
      filters: @filters,
      allowMany: allowMany,
    ),
    callback,
  )

proc browse*(
    callback: proc(path: string),
    defaultLocation = "",
    filters: openArray[FileDialogFilter] = [],
    window: Window = nil,
) =
  showOpenFileDialog(
    proc(result: FileDialogResult) =
      if not result.canceled and result.paths.len > 0 and not callback.isNil:
        callback(result.paths[0])
    ,
    defaultLocation = defaultLocation,
    filters = filters,
    allowMany = false,
    window = window,
  )

proc pick*(
    callback: proc(paths: seq[string]),
    defaultLocation = "",
    filters: openArray[FileDialogFilter] = [],
    allowMany = true,
    window: Window = nil,
) =
  showOpenFileDialog(
    proc(result: FileDialogResult) =
      if not result.canceled and not callback.isNil:
        callback(result.paths)
    ,
    defaultLocation = defaultLocation,
    filters = filters,
    allowMany = allowMany,
    window = window,
  )

proc showOpenFolderDialog*(
    options: OpenFolderDialogOptions, callback: FileDialogCallback
) =
  discard sdl3.clearError()
  lastDialogError = ""
  var request =
    DialogRequest(callback: callback, defaultLocation: options.defaultLocation)
  pendingRequests.add request

  let defaultLocation =
    if request.defaultLocation.len > 0: request.defaultLocation.cstring else: nil

  sdl3.showOpenFolderDialog(
    openFileCallback,
    cast[pointer](request),
    options.window,
    defaultLocation,
    options.allowMany,
  )
  let error = $sdl3.getError()
  if error.len > 0:
    lastDialogError = error

proc showOpenFolderDialog*(
    callback: FileDialogCallback,
    defaultLocation = "",
    allowMany = false,
    window: Window = nil,
) =
  showOpenFolderDialog(
    OpenFolderDialogOptions(
      window: window, defaultLocation: defaultLocation, allowMany: allowMany
    ),
    callback,
  )

proc browseFolder*(
    callback: proc(path: string), defaultLocation = "", window: Window = nil
) =
  showOpenFolderDialog(
    proc(result: FileDialogResult) =
      if not result.canceled and result.paths.len > 0 and not callback.isNil:
        callback(result.paths[0])
    ,
    defaultLocation = defaultLocation,
    allowMany = false,
    window = window,
  )

proc pickFolders*(
    callback: proc(paths: seq[string]),
    defaultLocation = "",
    allowMany = true,
    window: Window = nil,
) =
  showOpenFolderDialog(
    proc(result: FileDialogResult) =
      if not result.canceled and not callback.isNil:
        callback(result.paths)
    ,
    defaultLocation = defaultLocation,
    allowMany = allowMany,
    window = window,
  )
