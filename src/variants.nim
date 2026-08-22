import std/macros

proc bareIdent(n: NimNode): NimNode =
  case n.kind
  of nnkPostfix:
    n[1]
  of nnkPragmaExpr:
    bareIdent(n[0])
  else:
    n

proc identText(n: NimNode): string =
  case n.kind
  of nnkIdent, nnkSym:
    $n
  of nnkPostfix:
    identText(n[1])
  of nnkPragmaExpr:
    identText(n[0])
  else:
    error("expected an identifier, got " & $n.kind, n)

proc hasExportMarker(n: NimNode): bool =
  n.kind == nnkPostfix and n.len == 2 and $n[0] == "*"

proc maybeExported(name: string; exportIt: bool): NimNode =
  if exportIt:
    nnkPostfix.newTree(ident"*", ident(name))
  else:
    ident(name)

proc stripVariantPragma(n: NimNode): NimNode =
  result = copyNimTree(n)
  if result.kind != nnkPragmaExpr:
    return

  let pragmas = result[1]
  let kept = newNimNode(nnkPragma)
  for pragma in pragmas:
    if identText(pragma) != "variant":
      kept.add pragma

  if kept.len == 0:
    result = result[0]
  else:
    result[1] = kept

proc typeNameNode(typeDef: NimNode): NimNode =
  stripVariantPragma(typeDef[0])

proc enumNameFor(typeName: NimNode): NimNode =
  maybeExported(identText(typeName.bareIdent) & "Kind", typeName.hasExportMarker)

proc findRecCase(n: NimNode): NimNode =
  if n.kind == nnkRecCase:
    return n

  for child in n:
    result = findRecCase(child)
    if result != nil:
      return

proc setDiscriminatorType(recCase, enumName: NimNode) =
  let discriminator = recCase[0]
  if discriminator.kind != nnkIdentDefs:
    error("variant object case discriminator must be a field definition", discriminator)

  discriminator[1] = enumName.bareIdent

proc enumFieldName(branch: NimNode): NimNode =
  if branch.len < 1:
    error("variant branch is missing an enum field", branch)
  branch[0]

macro variant*(typeDef: untyped): untyped =
  if typeDef.kind != nnkTypeDef:
    error("{.variant.} can only be applied to a type definition", typeDef)

  let typeName = typeNameNode(typeDef)
  let enumName = enumNameFor(typeName)
  let body = copyNimTree(typeDef[2])
  let recCase = findRecCase(body)
  if recCase == nil:
    error("{.variant.} requires an object variant case section", typeDef)

  setDiscriminatorType(recCase, enumName)

  let enumTy = newNimNode(nnkEnumTy).add(newEmptyNode())
  for branch in recCase:
    if branch.kind == nnkOfBranch:
      enumTy.add enumFieldName(branch)

  result = nnkTypeSection.newTree(
    nnkTypeDef.newTree(enumName, newEmptyNode(), enumTy),
    nnkTypeDef.newTree(typeName, typeDef[1], body))

type
  ToolID = distinct string
  MenuID = distinct string

  ToolbarEvent* {.variant.} = object
    case kind*: ToolbarEventKind
    of ToolPressed:
      id*: ToolID
    of MenuPressed:
      menuID*: MenuID
      action*: MenuID

when isMainModule:
  let toolEvent = ToolbarEvent(kind: ToolPressed, id: ToolID"paint")
  let menuEvent = ToolbarEvent(
    kind: MenuPressed,
    menuID: MenuID"file",
    action: MenuID"open")

  doAssert toolEvent.kind == ToolPressed
  doAssert toolEvent.id.string == "paint"
  doAssert menuEvent.kind == MenuPressed
  doAssert menuEvent.menuID.string == "file"
  doAssert menuEvent.action.string == "open"
  doAssert $ToolbarEventKind == "ToolbarEventKind"

  echo "variant pragma generated ToolbarEventKind"
