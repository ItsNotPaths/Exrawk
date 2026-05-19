## Tab strip — horizontal row of directory-session labels above the file
## list. Click switches active tab; widget is keyboard-passive (Tab /
## Shift+Tab / `t` / `x` are window-level shortcuts wired in Exrawk.nim
## or via the palette in milestone 4).
##
## Rendering: each tab is `<i>:<basename>` separated by ` | `. The active
## tab is drawn with the accent fill. Whole strip repaints on state.notify.

import std/os
import rawk_luigi, rawk_bufferlib
import state

type
  TabStrip* = object
    e*: Element
    hitX:  seq[cint]                   ## x-position of each tab's right edge,
                                       ## refreshed every paint. Used for hit
                                       ## testing on left-down.

var theTabStrip*: ptr TabStrip

proc stripHeight(): cint =
  let (_, gH) = glyphDims()
  gH + 4                                ## 2 px padding top + bottom

proc tabLabel(t: ptr Tab, idx: int): string =
  let base =
    if t.cwd == "/": "/"
    elif t.cwd == getHomeDir(): "~"
    else: t.cwd.lastPathPart
  $idx & ":" & (if base.len == 0: t.cwd else: base)

proc tabsMessage(element: ptr Element, message: Message,
                 di: cint, dp: pointer): cint {.cdecl.} =
  let ts = cast[ptr TabStrip](element)

  if message == msgGetHeight:
    return stripHeight()

  elif message == msgPaint:
    let painter = cast[ptr Painter](dp)
    drawBlock(painter, element.bounds, ui.theme.panel2)
    ts.hitX.setLen(0)
    if state.tabs.len == 0: return 1
    let (gW, _) = glyphDims()
    var x = element.bounds.l + 4
    for i in 0 ..< state.tabs.len:
      let label = tabLabel(addr state.tabs[i], i + 1)
      let w = cint(label.len) * gW + 8
      let r = Rectangle(l: x, r: x + w,
                        t: element.bounds.t + 1,
                        b: element.bounds.b - 1)
      let isActive = (i == state.activeIdx)
      let bg = if isActive: ui.theme.selected else: ui.theme.panel1
      let fg = if isActive: ui.theme.textSelected else: ui.theme.text
      drawBlock(painter, r, bg)
      drawString(painter, r, label.cstring, label.len,
                 fg, cint(ALIGN_CENTER), nil)
      x = r.r + 6
      ts.hitX.add(r.r)
    return 1

  elif message == msgLeftDown:
    let w = element.window
    if w != nil:
      let cx = w.cursorX
      var idx = -1
      for i in 0 ..< ts.hitX.len:
        if cx <= ts.hitX[i]: idx = i; break
      if idx == -1 and ts.hitX.len > 0: idx = ts.hitX.len - 1
      if idx >= 0 and idx < state.tabs.len:
        state.setActive(idx)
    return 1

  return 0

proc tabstripCreate*(parent: ptr Element): ptr TabStrip =
  let e = elementCreate(csize_t(sizeof(TabStrip)), parent, 0,
                        tabsMessage, "ExrawkTabStrip")
  let ts = cast[ptr TabStrip](e)
  theTabStrip = ts
  state.subscribe(proc() =
    if theTabStrip != nil and theTabStrip.e.window != nil:
      elementRepaint(addr theTabStrip.e, nil))
  return ts
