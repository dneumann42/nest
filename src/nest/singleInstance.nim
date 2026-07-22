import std/[os, posix, strutils]
from std/times import epochTime

type SingleInstanceLock* = object
  active: bool
  lockDir, pidPath: string

proc singleInstanceName(namespace: string): string =
  result = "nest-"
  for ch in namespace:
    if ch.isAlphaNumeric:
      result.add ch
    else:
      result.add '-'

proc pidAlive(pid: int): bool =
  pid > 0 and dirExists("/proc" / $pid)

proc processCmdline(pid: int): string =
  try:
    readFile("/proc" / $pid / "cmdline").replace('\0', ' ').strip
  except CatchableError:
    ""

proc pidMatchesCurrentApp(pid: int): bool =
  if not pidAlive(pid):
    return false
  let cmdline = processCmdline(pid)
  cmdline.len > 0 and (
    cmdline.contains(getAppFilename()) or
    cmdline.contains("./nest run") or
    cmdline.contains(" nest run ")
  )

proc readPid(path: string): int =
  try:
    parseInt(readFile(path).strip)
  except CatchableError:
    0

proc removeSingleInstanceLock*(lock: SingleInstanceLock) =
  if not lock.active:
    return
  if lock.pidPath.fileExists and lock.pidPath.readPid == getCurrentProcessId():
    try:
      removeFile(lock.pidPath)
    except OSError:
      discard
    try:
      removeDir(lock.lockDir)
    except OSError:
      discard

proc terminatePid(pid: int) =
  if not pidAlive(pid) or pid == getCurrentProcessId():
    return
  discard execShellCmd("kill -TERM " & $pid & " >/dev/null 2>&1")
  let deadline = epochTime() + 1.5
  while pidAlive(pid) and epochTime() < deadline:
    os.sleep(25)
  if pidAlive(pid):
    discard execShellCmd("kill -KILL " & $pid & " >/dev/null 2>&1")

proc acquireSingleInstanceLock*(namespace: string): SingleInstanceLock =
  result.lockDir = getTempDir() / (singleInstanceName(namespace) & ".lock")
  result.pidPath = result.lockDir / "pid"

  for attempt in 0 .. 2:
    if mkdir(cstring(result.lockDir), 0o700) == 0:
      writeFile(result.pidPath, $getCurrentProcessId())
      result.active = true
      return

    let oldPid = result.pidPath.readPid
    if oldPid > 0 and pidMatchesCurrentApp(oldPid):
      terminatePid(oldPid)
    else:
      try:
        if result.pidPath.fileExists:
          removeFile(result.pidPath)
        removeDir(result.lockDir)
      except OSError:
        discard

    if attempt < 2:
      os.sleep(50)

  quit("Could not acquire single-instance lock for namespace: " & namespace)
