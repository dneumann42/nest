import std/[json, os]

import nest/[appConfig, dialogAnchors, runtime, screen, ui]

const
  PopoverFontSize = 14
  TooltipHeight = 30
  ChoiceRowHeight = 28
  MaxPopoverWidth = 360

proc estimateWidth(text: string; padding = 18): int =
  min(MaxPopoverWidth, max(48, text.len * 8 + padding))

proc tooltipConfig(text, anchorJson, theme: string): AppConfig =
  AppConfig
    .overlayDialog(
      estimateWidth(text).Positive,
      TooltipHeight.Positive,
      title = "Nest Tooltip",
      namespace = "nest-tooltip",
    )
    .applyDialogAnchor(parseDialogAnchor(anchorJson))

proc choiceConfig(options: openArray[string]; anchorJson, theme: string): AppConfig =
  var widest = 80
  for option in options:
    widest = max(widest, estimateWidth(option, 28))
  AppConfig
    .overlayDialog(
      widest.Positive,
      max(ChoiceRowHeight, options.len * ChoiceRowHeight).Positive,
      title = "Nest Choices",
      namespace = "nest-choice-popover",
    )
    .applyDialogAnchor(parseDialogAnchor(anchorJson))

proc applyTheme(cfg: var AppConfig; theme: string) =
  if theme.len > 0:
    cfg.themeName = theme

proc parentAlive(parentPid: int): bool =
  parentPid <= 0 or dirExists("/proc" / $parentPid)

proc runTooltipPopover*(text, anchorJson, theme: string, parentPid = 0) =
  ## Show a small tooltip popover until the parent process terminates it.
  var appCfg = tooltipConfig(text, anchorJson, theme)
  appCfg.applyTheme(theme)
  var appUi = UI.init()
  application appCfg, appUi:
    if not parentAlive(parentPid):
      running = false
    appUi.requestRedrawAfter(500)
    appUi.layout:
      appUi.card(
        appUi.id("tooltip"),
        cfg(
          width = fill(),
          height = fill(),
          paddingLeft = 10,
          paddingTop = 4,
          paddingRight = 4,
          paddingBottom = 4,
          alignItems = Center,
          justifyContent = Center,
        ).withBackground(color(0, 0, 0)),
      ):
        appUi.label(
          appUi.id("text"),
          text,
          fill(),
          fit(),
          fontName = appUi.fontAtSize("font", PopoverFontSize),
          textScroll = true,
        )

proc optionsFromJson(data: string): seq[string] =
  try:
    let node = parseJson(data)
    if node.kind == JArray:
      for item in node.items:
        if item.kind == JString:
          result.add item.getStr
        else:
          result.add $item
  except JsonParsingError:
    discard

proc runChoicePopover*(data, resultPath, anchorJson, theme: string, parentPid = 0) =
  ## Show a click-to-select choice popover and write the selected index.
  let options = optionsFromJson(data)
  if options.len == 0:
    return
  var appCfg = choiceConfig(options, anchorJson, theme)
  appCfg.applyTheme(theme)
  var appUi = UI.init()
  application appCfg, appUi:
    if not parentAlive(parentPid):
      running = false
    appUi.requestRedrawAfter(500)
    appUi.layout:
      appUi.column(
        appUi.id("choices"),
        cfg(width = fill(), height = fill(), gap = 0, alignItems = Stretch),
      ):
        for index, option in options:
          let optionID = appUi.id("option", index)
          if appUi.button(
            optionID,
            option,
            fill(),
            fixed(ChoiceRowHeight),
            textScroll = true,
            fontName = appUi.fontAtSize("font", PopoverFontSize),
          ):
            if resultPath.len > 0:
              writeFile(resultPath, $index)
            running = false
