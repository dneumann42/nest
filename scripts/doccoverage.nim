## Fails unless every exported routine in the generated documentation carries a
## doc comment.
##
## Run it over the output of `nim jsondoc --project`, which is what
## `nimble docCoverage` does.

import std/[json, os, strutils]

const RoutineKinds = [
  "skProc", "skFunc", "skTemplate", "skMacro", "skMethod", "skIterator",
  "skConverter",
]

proc entriesOf(node: JsonNode): JsonNode =
  ## Return a module's doc entries, whichever shape jsondoc emitted.
  if node.kind == JArray:
    node
  elif node.kind == JObject and node.hasKey("entries"):
    node["entries"]
  else:
    newJArray()

proc main() =
  let dir =
    if paramCount() >= 1:
      paramStr(1)
    else:
      "build/jsondoc"
  if not dirExists(dir):
    quit("no jsondoc output in " & dir & ": run `nim jsondoc --project` first", 1)

  var
    total = 0
    missing: seq[string]
  for path in walkDirRec(dir):
    if path.splitFile.ext != ".json":
      continue
    for entry in entriesOf(parseFile(path)):
      if entry{"type"}.getStr notin RoutineKinds:
        continue
      inc total
      if entry{"description"}.getStr.strip.len == 0:
        missing.add path & ":" & $entry{"line"}.getInt & ": " &
          entry{"name"}.getStr

  for item in missing:
    echo "undocumented: ", item
  echo "exported routines: ", total, ", undocumented: ", missing.len
  if missing.len > 0:
    quit(1)

main()
