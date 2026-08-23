type
  KeyCode* = enum
    KeyNone
    KeyA
    KeyB
    KeyC
    KeyD
    KeyE
    KeyF
    KeyG
    KeyH
    KeyI
    KeyJ
    KeyK
    KeyL
    KeyM
    KeyN
    KeyO
    KeyP
    KeyQ
    KeyR
    KeyS
    KeyT
    KeyU
    KeyV
    KeyW
    KeyX
    KeyY
    KeyZ
    Key0
    Key1
    Key2
    Key3
    Key4
    Key5
    Key6
    Key7
    Key8
    Key9
    KeyF1
    KeyF2
    KeyF3
    KeyF4
    KeyF5
    KeyF6
    KeyF7
    KeyF8
    KeyF9
    KeyF10
    KeyF11
    KeyF12
    KeyEnter
    KeySpace
    KeyEsc
    KeyTab
    KeyBackspace
    KeyDelete
    KeyInsert
    KeyLeft
    KeyRight
    KeyUp
    KeyDown
    KeyPageUp
    KeyPageDown
    KeyHome
    KeyEnd
    KeyCapslock
    KeyComma
    KeyPeriod
    KeySlash
    KeyMinus
    KeyEqual
    KeyPlus

  EventKind* = enum
    NoEvent
    KeyDownEvent
    KeyUpEvent
    TextInputEvent
    MouseDownEvent
    MouseUpEvent
    MouseMoveEvent
    MouseWheelEvent
    WindowResizeEvent
    WindowCloseEvent
    WindowFocusGainedEvent
    WindowFocusLostEvent
    WindowMouseEnterEvent
    WindowMouseLeaveEvent
    QuitEvent

  Modifier* = enum
    ShiftPressed
    CtrlPressed
    AltPressed
    GuiPressed

  MouseButton* = enum
    LeftButton
    RightButton
    MiddleButton

  InputFlag* = enum
    WantTextInput

  Event* = object
    kind*: EventKind
    key*: KeyCode
    mods*: set[Modifier]
    text*: array[4, char]
    x*, y*: int
    mouseX*, mouseY*: int
    wheelX*, wheelY*: float64
    button*: MouseButton
    clicks*: int

  ClipboardRelays* = object
    getText*: proc(): string {.nimcall.}
    putText*: proc(text: string) {.nimcall.}

  InputRelays* = object
    pollEvent*: proc(e: var Event, flags: set[InputFlag]): bool {.nimcall.}
    waitEvent*:
      proc(e: var Event, timeoutMs: int, flags: set[
          InputFlag]): bool {.nimcall.}
    getTicks*: proc(): int {.nimcall.}
    sleep*: proc(ms: int) {.nimcall.}
    shutdown*: proc() {.nimcall.}

var clipboardRelays* = ClipboardRelays(
  getText: proc(): string =
    "",
  putText: proc(text: string) =
    discard,
)

var inputRelays* = InputRelays(
  pollEvent: proc(e: var Event, flags: set[InputFlag]): bool =
  false,
  waitEvent: proc(e: var Event, timeoutMs: int, flags: set[InputFlag]): bool =
  false,
  getTicks: proc(): int =
  0,
  sleep: proc(ms: int) =
  discard,
  shutdown: proc() =
  discard,
)

proc pollEvent*(e: var Event, flags: set[InputFlag] = {}): bool =
  ## Take the next pending input event into `e` without blocking.
  ##
  ## Returns false when nothing is queued. `flags` carries backend hints for
  ## the frame, such as `WantTextInput` while a text widget has focus.
  inputRelays.pollEvent(e, flags)

proc waitEvent*(e: var Event, timeoutMs: int = -1, flags: set[InputFlag] = {}): bool =
  ## Wait for the next input event, storing it in `e`.
  ##
  ## Blocks for at most `timeoutMs` milliseconds, or indefinitely when it is
  ## negative, and returns false when the wait timed out. `flags` carries
  ## backend hints for the frame, such as `WantTextInput`.
  inputRelays.waitEvent(e, timeoutMs, flags)

proc getClipboardText*(): string =
  ## Return the current text contents of the system clipboard.
  clipboardRelays.getText()

proc putClipboardText*(text: string) =
  ## Replace the system clipboard contents with `text`.
  clipboardRelays.putText(text)

proc getTicks*(): int =
  ## Return the milliseconds elapsed since the input backend started.
  inputRelays.getTicks()

proc sleep*(ms: int) =
  ## Block the calling thread for `ms` milliseconds.
  inputRelays.sleep(ms)

proc shutdown*() =
  ## Shut the input backend down and release its resources.
  inputRelays.shutdown()
