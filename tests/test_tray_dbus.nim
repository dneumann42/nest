import std/[os, strutils, unittest]

import dbus, dbus/lowlevel
import owl
import nest/tray

const
  WatcherName = "org.kde.StatusNotifierWatcher"
  WatcherPath = "/StatusNotifierWatcher"
  WatcherIface = "org.kde.StatusNotifierWatcher"
  PropertiesIface = "org.freedesktop.DBus.Properties"

proc privateSessionBus(): Bus =
  var error: DBusError
  dbus_error_init(addr error)
  let connection = dbus_bus_get_private(DBUS_BUS_SESSION, addr error)
  if dbus_error_is_set(addr error) != 0:
    let message = if error.message == nil: "D-Bus connection failed"
      else: $error.message
    dbus_error_free(addr error)
    raise newException(IOError, message)
  dbus_connection_set_exit_on_disconnect(connection, 0)
  Bus(conn: connection)

proc closePrivate(bus: Bus) =
  dbus_connection_close(bus.conn)
  dbus_connection_unref(bus.conn)

proc watcherProperty(bus: Bus; name: string): DbusValue =
  var message = makeCall(WatcherName, WatcherPath.ObjectPath,
    PropertiesIface, "Get")
  var iter = message.initIter()
  (addr iter).append(WatcherIface)
  (addr iter).append(name)
  var reply = bus.sendMessageWithReply(message).waitForReply()
  defer: reply.close()
  reply.raiseIfError()
  var input = reply.iterate()
  let value = input.unpackCurrent(DbusValue)
  check value.kind == dtVariant
  value.variantValue

proc call(bus: Bus; destination, path, iface, member: string;
    args: openArray[DbusValue]): Reply =
  var message = makeCall(destination, path.ObjectPath, iface, member)
  var iter = message.initIter()
  for arg in args:
    (addr iter).append(arg)
  result = bus.sendMessageWithReply(message).waitForReply()
  result.raiseIfError()

proc variant(value: DbusValue): DbusValue =
  DbusValue(kind: dtVariant, variantType: value.getDbusType,
    variantValue: value)

proc fakeItemProperty(name: string): DbusValue =
  case name
  of "Id": "test-item".asDbusValue
  of "Title": "Test tray item".asDbusValue
  of "Status": "Active".asDbusValue
  of "Category": "ApplicationStatus".asDbusValue
  of "IconName", "AttentionIconName", "IconThemePath": "".asDbusValue
  of "Menu": "/StatusNotifierItem/Menu".ObjectPath.asDbusValue
  of "ToolTip": DbusValue(kind: dtStruct, structValues: @[
    "".asDbusValue,
    DbusValue(kind: dtArray, arrayValueType: DbusType(kind: dtStruct,
      itemTypes: @[dtInt32.DbusType, dtInt32.DbusType,
        DbusType(kind: dtArray, itemType: dtByte.DbusType)])),
    "Test tray item".asDbusValue,
    "".asDbusValue,
  ])
  of "IconPixmap", "AttentionIconPixmap":
    DbusValue(kind: dtArray, arrayValueType: DbusType(kind: dtStruct,
      itemTypes: @[dtInt32.DbusType, dtInt32.DbusType,
        DbusType(kind: dtArray, itemType: dtByte.DbusType)]))
  else: "".asDbusValue

proc menuProperties(label, entryType: string): DbusValue =
  result = DbusValue(kind: dtArray, arrayValueType: DbusType(
    kind: dtDictEntry, keyType: dtString, valueType: dtVariant))
  for (key, value) in [("label", label), ("type", entryType)]:
    result.arrayValue.add DbusValue(kind: dtDictEntry,
      dictKey: key.asDbusValue, dictValue: variant(value.asDbusValue))

proc menuNode(id: int32; label: string; entryType = ""): DbusValue =
  DbusValue(kind: dtStruct, structValues: @[
    id.asDbusValue,
    menuProperties(label, entryType),
    DbusValue(kind: dtArray, arrayValueType: DbusType(kind: dtVariant,
      variantType: DbusType(kind: dtStruct, itemTypes: @[
        dtInt32.DbusType,
        DbusType(kind: dtArray, itemType: DbusType(kind: dtDictEntry,
          keyType: dtString, valueType: dtVariant)),
        DbusType(kind: dtArray, itemType: dtVariant.DbusType),
      ]))),
  ])

proc fakeMenuLayout(): DbusValue =
  let launch = menuNode(42, "Launch Steam")
  result = menuNode(0, "")
  result.structValues[2].arrayValue.add variant(launch)

proc waitForWatcher(bus: Bus): bool =
  for _ in 0 ..< 50:
    try:
      return bus.watcherProperty("ProtocolVersion").int32Value == 0
    except Exception:
      sleep(20)
  false

suite "status notifier tray":
  test "ARGB status icons preserve the alpha channel":
    check argbToRgba([255'u8, 10, 20, 30, 0, 40, 50, 60]) ==
      @[10'u8, 20, 30, 255, 40, 50, 60, 0]

  test "PNG encoder produces a valid RGBA image":
    let png = encodePng(1, 1, [10'u8, 20, 30, 255])
    check png[0 .. 7] == @[137'u8, 80, 78, 71, 13, 10, 26, 10]
    check png[^12 .. ^9] == @[0'u8, 0, 0, 0]
    check png[^8 .. ^5] == @[73'u8, 69, 78, 68]

  test "watcher exports standard D-Bus properties":
    ensureStarted()
    let bus = privateSessionBus()
    defer:
      bus.closePrivate()
      closeTrayHost()
    check bus.waitForWatcher()
    check bus.watcherProperty("ProtocolVersion").int32Value == 0
    let registered = bus.watcherProperty("RegisteredStatusNotifierItems")
    check registered.kind == dtArray

  test "watcher can stop and start again":
    ensureStarted()
    closeTrayHost()
    ensureStarted()
    let bus = privateSessionBus()
    defer:
      bus.closePrivate()
      closeTrayHost()
    check bus.waitForWatcher()

  test "registered items reach the Owl snapshot":
    ensureStarted()
    let bus = privateSessionBus()
    defer:
      discard dbus_connection_unregister_object_path(bus.conn,
        "/StatusNotifierItem")
      discard dbus_connection_unregister_object_path(bus.conn,
        "/StatusNotifierItem/Menu")
      bus.closePrivate()
      closeTrayHost()
    check bus.waitForWatcher()
    bus.registerObject("/StatusNotifierItem".ObjectPath,
      proc(kind: IncomingMessageType; incoming: IncomingMessage): bool =
        if kind == mtCall and incoming.interfaceName ==
            "org.freedesktop.DBus.Properties" and incoming.name == "Get":
          let arguments = incoming.unpackValueSeq()
          if arguments.len == 2 and arguments[1].kind == dtString:
            bus.sendReply(incoming,
              @[variant(fakeItemProperty(arguments[1].stringValue))])
          else:
            bus.sendErrorReply(incoming, "invalid property request")
          return true
        false)
    var clickedMenuId = 0'i32
    bus.registerObject("/StatusNotifierItem/Menu".ObjectPath,
      proc(kind: IncomingMessageType; incoming: IncomingMessage): bool =
        if kind != mtCall or incoming.interfaceName !=
            "com.canonical.dbusmenu":
          return false
        if incoming.name == "AboutToShow":
          bus.sendReply(incoming, @[false.asDbusValue])
          return true
        if incoming.name == "GetLayout":
          bus.sendReply(incoming,
            @[1'u32.asDbusValue, fakeMenuLayout()])
          return true
        if incoming.name == "Event":
          let arguments = incoming.unpackValueSeq()
          if arguments.len > 0 and arguments[0].kind == dtInt32:
            clickedMenuId = arguments[0].int32Value
          bus.sendReply(incoming, @[])
          return true
        false)
    var registration = bus.call(WatcherName, WatcherPath,
      WatcherIface, "RegisterStatusNotifierItem",
      ["/StatusNotifierItem".asDbusValue])
    registration.close()
    var items = trayItems()
    for _ in 0 ..< 50:
      discard dbus_connection_read_write_dispatch(bus.conn, 20)
      items = trayItems()
      if items.count == 1:
        break
    check items.count == 1
    if items.count == 1:
      check items[0]["title"].text == "Test tray item"
      check items[0]["status"].text == "Active"
      let displayId = items[0]["id"].text
      trayRequestMenu(displayId)
      var menuData = ""
      for _ in 0 ..< 50:
        discard dbus_connection_read_write_dispatch(bus.conn, 20)
        menuData = trayMenuData(displayId)
        if menuData.len > 0:
          break
      check menuData.contains("42\t\tLaunch Steam")
      trayMenuActivate(displayId, "42")
      for _ in 0 ..< 50:
        discard dbus_connection_read_write_dispatch(bus.conn, 20)
        if clickedMenuId == 42:
          break
      check clickedMenuId == 42

  test "empty UI snapshot is an Owl list":
    closeTrayHost()
    let items = trayItems()
    check items.kind == List
    check items.count == 0
    closeTrayHost()
