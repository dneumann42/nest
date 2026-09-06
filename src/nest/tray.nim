## StatusNotifierWatcher and tray-item host backed by libdbus.
##
## D-Bus framing, authentication, alignment, variants and dispatch belong to
## libdbus through nim-dbus. This module only implements the KDE
## StatusNotifier protocol and publishes immutable snapshots to Owl.

import std/[locks, os, posix, strformat, strutils, tables]

import dbus, dbus/lowlevel
import owl

const
  WatcherName = "org.kde.StatusNotifierWatcher"
  WatcherPath = "/StatusNotifierWatcher"
  WatcherIface = "org.kde.StatusNotifierWatcher"
  ItemIface = "org.kde.StatusNotifierItem"
  MenuIface = "com.canonical.dbusmenu"
  PropertiesIface = "org.freedesktop.DBus.Properties"
  IntrospectableIface = "org.freedesktop.DBus.Introspectable"
  PeerIface = "org.freedesktop.DBus.Peer"
  BusName = "org.freedesktop.DBus"
  BusPath = "/org/freedesktop/DBus"
  RequestNamePrimaryOwner = 1
  RequestNameAlreadyOwner = 4
  RequestNameDoNotQueue = 4'u32

var trayNotifyChange*: proc() {.gcsafe, raises: [].} =
  proc() {.gcsafe, raises: [].} = discard

type
  TrayActionKind* = enum
    taActivate, taSecondaryActivate, taContextMenu

  PendingAction = object
    kind: TrayActionKind
    displayId: string
    menuId: int32

  Pixmap = object
    width, height: int
    argb: seq[uint8]

  ItemState = object
    service, owner, path, id, title, tooltip, status, category: string
    iconName, attentionIconName, iconThemePath, iconPath: string
    pixmaps, attentionPixmaps: seq[Pixmap]
    iconFingerprint: string
    menuPath, menuData: string

  PublishedItem* = object
    service*, displayId*, title*, tooltip*, status*, category*: string
    iconPath*, menuData*: string
    hasIcon*, needsAttention*: bool

  Registration = object
    service, owner, path: string

  TrayHost = ref object
    thread: Thread[TrayHost]
    lock: Lock
    started, stopping, registered: bool
    nameOwned, objectRegistered, filterRegistered: bool
    published: seq[PublishedItem]
    pendingActions: seq[PendingAction]
    pendingMenuLoads: seq[string]
    pendingRegistrations: seq[Registration]
    pendingRefreshes: seq[string]
    pendingRemovals: seq[string]
    items: seq[ItemState]
    bus: Bus
    iconDir: string

var trayHost = TrayHost(iconDir: getTempDir() / ("nest-tray-" & $getuid()))
initLock(trayHost.lock)

proc publish(host: TrayHost)

proc notifyChange() {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    trayNotifyChange()

proc reportError(context, message: string) {.gcsafe, raises: [].} =
  try:
    stderr.writeLine("nest tray: " & context & ": " & message)
  except IOError:
    discard

proc isStopping(host: TrayHost): bool {.gcsafe, raises: [].} =
  withLock host.lock:
    result = host.stopping

proc safe(c: cstring): string =
  if c == nil: "" else: $c

proc variant(value: DbusValue): DbusValue =
  DbusValue(kind: dtVariant, variantType: value.getDbusType,
    variantValue: value)

proc dictEntry(key: string; value: DbusValue): DbusValue =
  DbusValue(kind: dtDictEntry, dictKey: key.asDbusValue,
    dictValue: variant(value))

proc propertyDict(entries: openArray[(string, DbusValue)]): DbusValue =
  result = DbusValue(kind: dtArray, arrayValueType: DbusType(
    kind: dtDictEntry, keyType: dtString, valueType: dtVariant))
  for (key, value) in entries:
    result.arrayValue.add dictEntry(key, value)

proc sendRaw(bus: Bus; message: ptr DBusMessage) =
  if message == nil:
    return
  discard dbus_connection_send(bus.conn, message, nil)
  dbus_message_unref(message)
  bus.flush()

proc sendReply(bus: Bus; request: ptr DBusMessage;
    values: openArray[DbusValue]) =
  let reply = dbus_message_new_method_return(request)
  if reply == nil:
    return
  var iter: DBusMessageIter
  dbus_message_iter_init_append(reply, addr iter)
  try:
    for value in values:
      (addr iter).append(value)
    bus.sendRaw(reply)
  except DbusException as error:
    reportError("cannot send method reply", error.msg)
    dbus_message_unref(reply)
  except CatchableError as error:
    reportError("cannot send method reply", error.msg)
    dbus_message_unref(reply)

proc sendError(bus: Bus; request: ptr DBusMessage; name, message: string) =
  bus.sendRaw(dbus_message_new_error(request, name, message))

proc emitSignal(bus: Bus; member: string; values: openArray[DbusValue]) =
  var signal = makeSignal(WatcherPath, WatcherIface, member)
  var iter = signal.initIter()
  for value in values:
    (addr iter).append(value)
  discard bus.sendMessage(signal)
  bus.flush()

proc watcherXml(): string = """<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
  <interface name="org.freedesktop.DBus.Introspectable">
    <method name="Introspect"><arg type="s" direction="out"/></method>
  </interface>
  <interface name="org.freedesktop.DBus.Peer">
    <method name="Ping"/>
  </interface>
  <interface name="org.freedesktop.DBus.Properties">
    <method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
    <method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method>
  </interface>
  <interface name="org.kde.StatusNotifierWatcher">
    <method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
    <method name="RegisterStatusNotifierHost"><arg type="s" direction="in"/></method>
    <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
    <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
    <property name="ProtocolVersion" type="i" access="read"/>
    <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
    <signal name="StatusNotifierItemUnregistered"><arg type="s"/></signal>
    <signal name="StatusNotifierHostRegistered"/>
  </interface>
</node>"""

proc registeredNames(host: TrayHost): seq[string] =
  for item in host.items:
    result.add item.service

proc watcherProperty(host: TrayHost; name: string): DbusValue =
  case name
  of "RegisteredStatusNotifierItems": host.registeredNames.asDbusValue
  of "IsStatusNotifierHostRegistered": true.asDbusValue
  of "ProtocolVersion": 0'i32.asDbusValue
  else: nil

proc readStrings(message: ptr DBusMessage): seq[string] =
  var reply = replyFromMessage(message)
  var iter = reply.iterate()
  let signature = safe(dbus_message_get_signature(message))
  for index, kind in signature:
    let value = iter.unpackCurrent(DbusValue)
    case value.kind
    of dtString: result.add value.stringValue
    of dtObjectPath: result.add value.objectPathValue.string
    else: result.add ""
    if index + 1 < signature.len:
      iter.advanceIter()

proc queueRegistration(host: TrayHost; message: ptr DBusMessage; arg: string) =
  let sender = safe(dbus_message_get_sender(message))
  var registration = Registration(
    service: sender, owner: sender, path: "/StatusNotifierItem")
  if arg.startsWith("/"):
    registration.path = arg
  elif arg.len > 0:
    registration.service = arg
  host.pendingRegistrations.add registration

proc watcherCallback(connection: ptr DBusConnection; message: ptr DBusMessage;
    userData: pointer): DBusHandlerResult {.cdecl.} =
  let host = cast[TrayHost](userData)
  try:
    let iface = safe(dbus_message_get_interface(message))
    let member = safe(dbus_message_get_member(message))
    if iface == WatcherIface:
      case member
      of "RegisterStatusNotifierItem":
        let args = readStrings(message)
        if args.len != 1:
          host.bus.sendError(message, "org.freedesktop.DBus.Error.InvalidArgs",
            "RegisterStatusNotifierItem expects one string or object path")
        else:
          # Reply before querying the item. Many clients synchronously wait for
          # this reply and cannot answer Properties.GetAll until it arrives.
          host.bus.sendReply(message, [])
          host.queueRegistration(message, args[0])
        return DBUS_HANDLER_RESULT_HANDLED
      of "RegisterStatusNotifierHost":
        host.bus.sendReply(message, [])
        host.bus.emitSignal("StatusNotifierHostRegistered", [])
        return DBUS_HANDLER_RESULT_HANDLED
      else: discard
    elif iface == PropertiesIface:
      let args = readStrings(message)
      if member == "Get" and args.len == 2 and args[0] == WatcherIface:
        let value = host.watcherProperty(args[1])
        if value == nil:
          host.bus.sendError(message,
            "org.freedesktop.DBus.Error.UnknownProperty", args[1])
        else:
          host.bus.sendReply(message, [variant(value)])
        return DBUS_HANDLER_RESULT_HANDLED
      if member == "GetAll" and args.len == 1 and args[0] == WatcherIface:
        host.bus.sendReply(message, [propertyDict([
          ("RegisteredStatusNotifierItems", host.registeredNames.asDbusValue),
          ("IsStatusNotifierHostRegistered", true.asDbusValue),
          ("ProtocolVersion", 0'i32.asDbusValue),
        ])])
        return DBUS_HANDLER_RESULT_HANDLED
    elif iface == IntrospectableIface and member == "Introspect":
      host.bus.sendReply(message, [watcherXml().asDbusValue])
      return DBUS_HANDLER_RESULT_HANDLED
    elif iface == PeerIface and member == "Ping":
      host.bus.sendReply(message, [])
      return DBUS_HANDLER_RESULT_HANDLED
    host.bus.sendError(message, "org.freedesktop.DBus.Error.UnknownMethod",
      "Unknown method " & iface & "." & member)
    DBUS_HANDLER_RESULT_HANDLED
  except DbusException as error:
    reportError("watcher method", error.msg)
    DBUS_HANDLER_RESULT_NOT_YET_HANDLED
  except CatchableError as error:
    reportError("watcher method", error.msg)
    DBUS_HANDLER_RESULT_NOT_YET_HANDLED

proc filterCallback(connection: ptr DBusConnection; message: ptr DBusMessage;
    userData: pointer): DBusHandlerResult {.cdecl.} =
  let host = cast[TrayHost](userData)
  try:
    let iface = safe(dbus_message_get_interface(message))
    let member = safe(dbus_message_get_member(message))
    if iface == BusName and member == "NameOwnerChanged":
      let args = readStrings(message)
      if args.len == 3 and args[2].len == 0:
        host.pendingRemovals.add args[0]
        host.pendingRemovals.add args[1]
    elif iface == ItemIface and member.startsWith("New"):
      host.pendingRefreshes.add safe(dbus_message_get_sender(message))
  except DbusException, CatchableError:
    discard
  DBUS_HANDLER_RESULT_NOT_YET_HANDLED

proc registerWatcherObject(host: TrayHost): bool =
  var vtable: DBusObjectPathVTable
  reset(vtable)
  vtable.message_function = watcherCallback
  result = dbus_connection_register_object_path(host.bus.conn, WatcherPath,
    addr vtable, cast[pointer](host)) != 0
  host.objectRegistered = result

proc claimWatcherName(host: TrayHost): bool =
  var err: DBusError
  dbus_error_init(addr err)
  let response = dbus_bus_request_name(host.bus.conn, WatcherName,
    RequestNameDoNotQueue, addr err)
  if dbus_error_is_set(addr err) != 0:
    let message = safe(err.message)
    dbus_error_free(addr err)
    reportError("cannot claim " & WatcherName, message)
    return false
  result = response in {RequestNamePrimaryOwner, RequestNameAlreadyOwner}
  if not result:
    reportError("cannot claim " & WatcherName,
      "request-name reply " & $response)
  host.nameOwned = result

proc addMatch(host: TrayHost; rule: string): bool =
  var err: DBusError
  dbus_error_init(addr err)
  dbus_bus_add_match(host.bus.conn, rule, addr err)
  if dbus_error_is_set(addr err) != 0:
    dbus_error_free(addr err)
    return false
  true

proc call(bus: Bus; destination, path, iface, member: string;
    args: openArray[DbusValue]): Reply =
  var message = makeCall(destination, path.ObjectPath, iface, member)
  var iter = message.initIter()
  for arg in args:
    (addr iter).append(arg)
  result = bus.sendMessageWithReply(message).waitForReply()
  result.raiseIfError()

proc getNameOwner(bus: Bus; name: string): string =
  if name.startsWith(":"):
    return name
  var reply = bus.call(BusName, BusPath, BusName, "GetNameOwner",
    [name.asDbusValue])
  defer: reply.close()
  var iter = reply.iterate()
  iter.unpackCurrent(string)

proc getProperty(bus: Bus; service, path, name: string): DbusValue =
  var reply = bus.call(service, path, PropertiesIface, "Get",
    [ItemIface.asDbusValue, name.asDbusValue])
  defer: reply.close()
  var iter = reply.iterate()
  let value = iter.unpackCurrent(DbusValue)
  if value.kind == dtVariant: value.variantValue else: value

proc tryGetProperty(bus: Bus; service, path, name: string): DbusValue =
  try:
    bus.getProperty(service, path, name)
  except DbusException, CatchableError:
    nil

proc textValue(value: DbusValue): string =
  if value == nil:
    return ""
  case value.kind
  of dtString: value.stringValue
  of dtObjectPath: value.objectPathValue.string
  else: ""

proc pixmapValue(value: DbusValue): seq[Pixmap] =
  if value == nil or value.kind != dtArray:
    return
  for entry in value.arrayValue:
    if entry.kind != dtStruct or entry.structValues.len != 3:
      continue
    let bytes = entry.structValues[2]
    if entry.structValues[0].kind == dtInt32 and
        entry.structValues[1].kind == dtInt32 and bytes.kind == dtArray:
      var pixmap = Pixmap(width: entry.structValues[0].int32Value.int,
        height: entry.structValues[1].int32Value.int)
      for value in bytes.arrayValue:
        if value.kind == dtByte:
          pixmap.argb.add value.byteValue
      result.add pixmap

proc tooltipValue(value: DbusValue): string =
  if value == nil or value.kind != dtStruct or value.structValues.len != 4:
    return ""
  let title = value.structValues[2]
  let body = value.structValues[3]
  if title.kind == dtString:
    result = title.stringValue
  if body.kind == dtString and body.stringValue.len > 0:
    if result.len > 0: result.add " — "
    result.add body.stringValue

proc menuProperty(properties: DbusValue; name: string): DbusValue =
  if properties == nil or properties.kind != dtArray:
    return nil
  for entry in properties.arrayValue:
    if entry.kind == dtDictEntry and entry.dictKey.kind == dtString and
        entry.dictKey.stringValue == name:
      let value = entry.dictValue
      return if value.kind == dtVariant: value.variantValue else: value

proc appendMenuRows(node: DbusValue; rows: var seq[string]) =
  let layout =
    if node != nil and node.kind == dtVariant: node.variantValue else: node
  if layout == nil or layout.kind != dtStruct or layout.structValues.len != 3:
    return
  let
    id = layout.structValues[0]
    properties = layout.structValues[1]
    children = layout.structValues[2]
    label = properties.menuProperty("label").textValue
    entryType = properties.menuProperty("type").textValue
  if id.kind == dtInt32 and id.int32Value != 0:
    rows.add $id.int32Value & "\t" & entryType & "\t" &
      label.replace("\t", " ").replace("\r", " ").replace("\n", " ")
  if children.kind == dtArray:
    for child in children.arrayValue:
      child.appendMenuRows(rows)

proc loadMenu(host: TrayHost; index: int) =
  if index < 0 or index >= host.items.len or
      host.items[index].menuPath.len == 0:
    return
  var about = host.bus.call(host.items[index].service,
    host.items[index].menuPath, MenuIface, "AboutToShow",
    [0'i32.asDbusValue])
  about.close()
  var reply = host.bus.call(host.items[index].service,
    host.items[index].menuPath, MenuIface, "GetLayout", [
      0'i32.asDbusValue,
      (-1'i32).asDbusValue,
      @["label", "type", "children-display"].asDbusValue,
    ])
  defer: reply.close()
  var input = reply.iterate()
  discard input.unpackCurrent(DbusValue) # layout revision
  input.advanceIter()
  let layout = input.unpackCurrent(DbusValue)
  var rows: seq[string]
  layout.appendMenuRows(rows)
  host.items[index].menuData = rows.join("\n")
  host.publish()

proc choosePixmap(pixmaps: seq[Pixmap]; target = 24): Pixmap =
  for pixmap in pixmaps:
    if pixmap.width <= 0 or pixmap.height <= 0 or
        pixmap.argb.len < pixmap.width * pixmap.height * 4:
      continue
    if result.width == 0 or
        (pixmap.width >= target and
          (result.width < target or pixmap.width < result.width)) or
        (result.width < target and pixmap.width > result.width):
      result = pixmap

proc argbToRgba*(argb: openArray[uint8]): seq[uint8] =
  ## Convert StatusNotifierItem's network-order ARGB32 bytes to RGBA bytes.
  result = newSeq[uint8](argb.len)
  for pixel in 0 ..< argb.len div 4:
    result[pixel * 4] = argb[pixel * 4 + 1]
    result[pixel * 4 + 1] = argb[pixel * 4 + 2]
    result[pixel * 4 + 2] = argb[pixel * 4 + 3]
    result[pixel * 4 + 3] = argb[pixel * 4]

proc crc32(data: openArray[uint8]): uint32 =
  result = 0xFFFF_FFFF'u32
  for b in data:
    result = result xor uint32(b)
    for _ in 0 ..< 8:
      result = (result shr 1) xor
        (if (result and 1) != 0: 0xEDB8_8320'u32 else: 0'u32)
  result = not result

proc adler32(data: openArray[uint8]): uint32 =
  var a = 1'u32
  var b = 0'u32
  for value in data:
    a = (a + uint32(value)) mod 65521'u32
    b = (b + a) mod 65521'u32
  (b shl 16) or a

proc appendU32BE(data: var seq[uint8]; value: uint32) =
  data.add uint8(value shr 24)
  data.add uint8(value shr 16)
  data.add uint8(value shr 8)
  data.add uint8(value)

proc appendChunk(png: var seq[uint8]; kind: string; payload: seq[uint8]) =
  png.appendU32BE(uint32(payload.len))
  var checked: seq[uint8]
  for ch in kind:
    png.add uint8(ch)
    checked.add uint8(ch)
  png.add payload
  checked.add payload
  png.appendU32BE(crc32(checked))

proc encodePng*(width, height: int; rgba: openArray[uint8]): seq[uint8] =
  result = @[137'u8, 80, 78, 71, 13, 10, 26, 10]
  var ihdr: seq[uint8]
  ihdr.appendU32BE(uint32(width))
  ihdr.appendU32BE(uint32(height))
  ihdr.add @[8'u8, 6, 0, 0, 0]
  result.appendChunk("IHDR", ihdr)
  var raw: seq[uint8]
  for y in 0 ..< height:
    raw.add 0
    for x in 0 ..< width:
      let offset = (y * width + x) * 4
      raw.add rgba[offset .. offset + 3]
  var zlib = @[0x78'u8, 0x01]
  var offset = 0
  while offset < raw.len:
    let count = min(65535, raw.len - offset)
    zlib.add(if offset + count == raw.len: 1'u8 else: 0'u8)
    zlib.add uint8(count)
    zlib.add uint8(count shr 8)
    let inverse = not uint16(count)
    zlib.add uint8(inverse)
    zlib.add uint8(inverse shr 8)
    zlib.add raw[offset ..< offset + count]
    offset += count
  zlib.appendU32BE(adler32(raw))
  result.appendChunk("IDAT", zlib)
  result.appendChunk("IEND", @[])

proc sanitizeId(service: string): string =
  for ch in service:
    result.add(if ch.isAlphaNumeric or ch in {'_', '-', '.'}: ch else: '_')

proc fingerprint(pixmap: Pixmap): string =
  result = &"{pixmap.width}x{pixmap.height}-"
  var hash = 2166136261'u32
  for value in pixmap.argb:
    hash = (hash xor uint32(value)) * 16777619'u32
  result.add hash.toHex(8)

proc resolveNamedIcon(name, themePath: string): string =
  if name.len == 0:
    return ""
  if fileExists(name):
    return name
  var roots: seq[string]
  if themePath.len > 0:
    for extension in [".png", ".svg", ".xpm"]:
      let candidate = themePath / (name & extension)
      if fileExists(candidate):
        return candidate
    roots.add themePath
  roots.add getHomeDir() / ".local/share/icons/hicolor"
  roots.add getHomeDir() / ".icons/hicolor"
  roots.add "/usr/local/share/icons/hicolor"
  roots.add "/usr/share/icons/hicolor"
  for root in roots:
    for size in ["16x16", "22x22", "24x24", "32x32", "48x48", "64x64"]:
      for context in ["apps", "status", "actions"]:
        for extension in [".png", ".svg", ".xpm"]:
          let candidate = root / size / context / (name & extension)
          if fileExists(candidate):
            return candidate
  let pixmap = "/usr/share/pixmaps" / (name & ".png")
  if fileExists(pixmap): pixmap else: ""

proc updateIcon(host: TrayHost; item: var ItemState) =
  let attention = item.status == "NeedsAttention"
  let pixmap = choosePixmap(
    if attention and item.attentionPixmaps.len > 0:
      item.attentionPixmaps
    else:
      item.pixmaps)
  if pixmap.width == 0:
    item.iconPath = resolveNamedIcon(
      if attention and item.attentionIconName.len > 0:
        item.attentionIconName
      else:
        item.iconName,
      item.iconThemePath)
    return
  let currentFingerprint = pixmap.fingerprint
  if item.iconFingerprint == currentFingerprint and item.iconPath.len > 0:
    return
  item.iconFingerprint = currentFingerprint
  let rgba = argbToRgba(pixmap.argb)
  try:
    createDir(host.iconDir)
    item.iconPath = host.iconDir /
      (sanitizeId(item.service) & "-" & currentFingerprint & ".png")
    let png = encodePng(pixmap.width, pixmap.height, rgba)
    var bytes = newString(png.len)
    for index, value in png:
      bytes[index] = char(value)
    writeFile(item.iconPath, bytes)
  except OSError:
    item.iconPath = ""

proc itemIndex(host: TrayHost; name: string): int =
  for index, item in host.items:
    if name in [item.service, item.owner]:
      return index
  -1

proc publish(host: TrayHost) =
  var snapshot: seq[PublishedItem]
  for item in host.items:
    snapshot.add PublishedItem(
      service: item.service,
      displayId: sanitizeId(item.service),
      title: item.title,
      tooltip: item.tooltip,
      status: item.status,
      category: item.category,
      iconPath: item.iconPath,
      menuData: item.menuData,
      hasIcon: item.iconPath.len > 0,
      needsAttention: item.status == "NeedsAttention")
  withLock host.lock:
    host.published = snapshot
  notifyChange()

proc refreshItem(host: TrayHost; name: string) =
  let index = host.itemIndex(name)
  if index < 0:
    return
  try:
    var item = host.items[index]
    template itemProperty(propertyName: string): DbusValue =
      host.bus.tryGetProperty(item.service, item.path, propertyName)
    item.id = itemProperty("Id").textValue
    item.title = itemProperty("Title").textValue
    item.status = itemProperty("Status").textValue
    if item.status.len == 0: item.status = "Passive"
    item.category = itemProperty("Category").textValue
    item.iconName = itemProperty("IconName").textValue
    item.attentionIconName =
      itemProperty("AttentionIconName").textValue
    item.iconThemePath = itemProperty("IconThemePath").textValue
    item.menuPath = itemProperty("Menu").textValue
    item.tooltip = itemProperty("ToolTip").tooltipValue
    if item.tooltip.len == 0: item.tooltip = item.title
    item.pixmaps = itemProperty("IconPixmap").pixmapValue
    item.attentionPixmaps = itemProperty("AttentionIconPixmap").pixmapValue
    host.updateIcon(item)
    host.items[index] = item
    host.publish()
  except DbusException, CatchableError:
    discard

proc registerPending(host: TrayHost) =
  let registrations = move(host.pendingRegistrations)
  host.pendingRegistrations = @[]
  for registration in registrations:
    var value = registration
    try:
      value.owner = host.bus.getNameOwner(value.service)
    except DbusException, CatchableError:
      discard
    if host.itemIndex(value.service) >= 0 or host.itemIndex(value.owner) >= 0:
      continue
    host.items.add ItemState(service: value.service, owner: value.owner,
      path: value.path)
    host.bus.emitSignal("StatusNotifierItemRegistered",
      [value.service.asDbusValue])
    host.refreshItem(value.service)

proc removePending(host: TrayHost) =
  let removals = move(host.pendingRemovals)
  host.pendingRemovals = @[]
  var changed = false
  for name in removals:
    let index = host.itemIndex(name)
    if index >= 0:
      let service = host.items[index].service
      host.items.delete(index)
      host.bus.emitSignal("StatusNotifierItemUnregistered",
        [service.asDbusValue])
      changed = true
  if changed: host.publish()

proc refreshPending(host: TrayHost) =
  let refreshes = move(host.pendingRefreshes)
  host.pendingRefreshes = @[]
  for name in refreshes:
    host.refreshItem(name)

proc loadPendingMenus(host: TrayHost) =
  var loads: seq[string]
  withLock host.lock:
    loads = move(host.pendingMenuLoads)
    host.pendingMenuLoads = @[]
  for displayId in loads:
    for index, item in host.items:
      if sanitizeId(item.service) == displayId:
        if item.menuPath.len > 0:
          try:
            host.loadMenu(index)
          except DbusException as error:
            reportError("cannot load menu for " & item.service, error.msg)
          except CatchableError as error:
            reportError("cannot load menu for " & item.service, error.msg)
        else:
          withLock host.lock:
            host.pendingActions.add PendingAction(kind: taContextMenu,
              displayId: displayId)
        break

proc flushActions(host: TrayHost) =
  var actions: seq[PendingAction]
  withLock host.lock:
    actions = move(host.pendingActions)
    host.pendingActions = @[]
  for action in actions:
    var index = -1
    for candidate, item in host.items:
      if sanitizeId(item.service) == action.displayId:
        index = candidate
        break
    if index < 0:
      continue
    let member = case action.kind
      of taActivate: "Activate"
      of taSecondaryActivate: "SecondaryActivate"
      of taContextMenu: "ContextMenu"
    try:
      var reply =
        if action.menuId != 0 and host.items[index].menuPath.len > 0:
          host.bus.call(host.items[index].service,
            host.items[index].menuPath, MenuIface, "Event", [
              action.menuId.asDbusValue,
              "clicked".asDbusValue,
              variant(0'i32.asDbusValue),
              0'u32.asDbusValue,
            ])
        else:
          host.bus.call(host.items[index].service,
            host.items[index].path, ItemIface, member,
            [0'i32.asDbusValue, 0'i32.asDbusValue])
      reply.close()
    except DbusException, CatchableError:
      if action.kind == taActivate:
        try:
          var fallback = host.bus.call(host.items[index].service,
            host.items[index].path, ItemIface, "SecondaryActivate",
            [0'i32.asDbusValue, 0'i32.asDbusValue])
          fallback.close()
        except DbusException as error:
          reportError("cannot activate " & host.items[index].service,
            error.msg)
        except CatchableError as error:
          reportError("cannot activate " & host.items[index].service,
            error.msg)

proc setup(host: TrayHost): bool =
  host.bus = getBus(DBUS_BUS_SESSION)
  dbus_connection_set_exit_on_disconnect(host.bus.conn, 0)
  if not host.claimWatcherName():
    return false
  if not host.registerWatcherObject():
    reportError("startup", "cannot register " & WatcherPath)
    return false
  if dbus_connection_add_filter(host.bus.conn, filterCallback,
      cast[pointer](host), nil) == 0:
    reportError("startup", "cannot install D-Bus message filter")
    return false
  host.filterRegistered = true
  if not host.addMatch("type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged'"):
    reportError("startup", "cannot subscribe to owner changes")
    return false
  if not host.addMatch("type='signal',interface='org.kde.StatusNotifierItem'"):
    reportError("startup", "cannot subscribe to item changes")
    return false
  host.registered = true
  host.bus.emitSignal("StatusNotifierHostRegistered", [])
  host.publish()
  true

proc trayThreadMain(host: TrayHost) {.thread.} =
  {.cast(gcsafe).}:
    try:
      if not host.setup():
        return
      while not host.isStopping():
        discard dbus_connection_read_write_dispatch(host.bus.conn, 100)
        host.registerPending()
        host.removePending()
        host.refreshPending()
        host.loadPendingMenus()
        host.flushActions()
    except DbusException as error:
      reportError("watcher stopped", error.msg)
    except CatchableError as error:
      reportError("watcher stopped", error.msg)
    finally:
      host.items.setLen(0)
      host.registered = false
      if host.bus != nil:
        if host.filterRegistered:
          dbus_connection_remove_filter(host.bus.conn, filterCallback,
            cast[pointer](host))
          host.filterRegistered = false
        if host.objectRegistered:
          discard dbus_connection_unregister_object_path(host.bus.conn,
            WatcherPath)
          host.objectRegistered = false
        if host.nameOwned:
          var error: DBusError
          dbus_error_init(addr error)
          discard dbus_bus_release_name(host.bus.conn, WatcherName, addr error)
          if dbus_error_is_set(addr error) != 0:
            dbus_error_free(addr error)
          host.nameOwned = false
      host.bus = nil
      host.publish()

proc ensureStarted*() {.raises: [].} =
  # libdbus requires its threading primitives to be installed before another
  # thread makes the first connection.
  if dbus_threads_init_default() == 0:
    reportError("watcher", "cannot initialize libdbus threading")
    return
  var start = false
  withLock trayHost.lock:
    if not trayHost.started:
      trayHost.stopping = false
      trayHost.started = true
      start = true
  if start:
    try:
      createThread(trayHost.thread, trayThreadMain, trayHost)
    except CatchableError as error:
      reportError("watcher", "cannot create thread: " & error.msg)
      withLock trayHost.lock:
        trayHost.started = false

proc closeTrayHost*() {.raises: [].} =
  var join = false
  withLock trayHost.lock:
    if trayHost.started:
      trayHost.stopping = true
      join = true
  if join:
    try:
      joinThread(trayHost.thread)
    except CatchableError:
      discard
  withLock trayHost.lock:
    trayHost.started = false
    trayHost.stopping = false
    trayHost.pendingActions.setLen(0)
    trayHost.published.setLen(0)

proc queueTrayAction*(displayId: string; kind: TrayActionKind) {.raises: [].} =
  withLock trayHost.lock:
    trayHost.pendingActions.add PendingAction(kind: kind, displayId: displayId)

proc trayActivate*(displayId: string) {.raises: [].} =
  queueTrayAction(displayId, taActivate)

proc traySecondaryActivate*(displayId: string) {.raises: [].} =
  queueTrayAction(displayId, taSecondaryActivate)

proc trayContextMenu*(displayId: string) {.raises: [].} =
  queueTrayAction(displayId, taContextMenu)

proc trayRequestMenu*(displayId: string) {.raises: [].} =
  withLock trayHost.lock:
    trayHost.pendingMenuLoads.add displayId

proc trayMenuData*(displayId: string): string {.raises: [].} =
  withLock trayHost.lock:
    for item in trayHost.published:
      if item.displayId == displayId:
        return item.menuData

proc trayMenuActivate*(displayId, menuId: string) {.raises: [].} =
  try:
    withLock trayHost.lock:
      trayHost.pendingActions.add PendingAction(kind: taContextMenu,
        displayId: displayId, menuId: parseInt(menuId).int32)
  except ValueError:
    discard

proc trayItems*(): Value {.raises: [].} =
  ensureStarted()
  var snapshot: seq[PublishedItem]
  withLock trayHost.lock:
    snapshot = trayHost.published
  var values: seq[Value]
  for item in snapshot:
    var entry = initTable[string, Value]()
    entry["id"] = text(item.displayId)
    entry["service"] = text(item.service)
    entry["title"] = text(item.title)
    entry["tooltip"] = text(item.tooltip)
    entry["status"] = text(item.status)
    entry["category"] = text(item.category)
    entry["iconPath"] = text(item.iconPath)
    entry["hasIcon"] = boolean(item.hasIcon)
    entry["needsAttention"] = boolean(item.needsAttention)
    values.add record(entry)
  list(values)
