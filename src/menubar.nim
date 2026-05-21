## Menubar — File / Edit / View, plus the command palette that takes over
## the same strip when Alt+C is pressed. Adapted from Prawk menubar.nim
## (palette state machine, history walk, prevFocus restoration); trimmed:
## no clipboard ops, no selection mechanics, no shell spinner. Add later
## if the palette grows into a richer editor.
##
## Menu items dispatch by name through the commands registry — they never
## bypass the same path the palette uses, so a `:tab.new` from typing and
## a "New Tab" click reach the same code.

import std/strutils
import rawk_luigi, rawk_bufferlib
import commands, cldispatch, theme, althints, dialog

type
  MenuOption = object
    label:   string
    command: string
    args:    seq[string]

  MenuItem = object
    label:   cstring
    x, w:    cint
    options: seq[MenuOption]

  Menubar* = object
    e*: Element
    items:        array[3, MenuItem]
    hovered:      int
    prevFocus:    ptr Element
    palette:      bool
    palBuf:       string
    palCursor:    int
    palInjected*: bool    # red border until the user edits or confirms
    menuOpen:     bool
    history:      seq[string]
    histIdx:      int     # -1 at live buffer, else index in history
    histDraft:    string  # live buffer stashed when walking back
    # Dialog-mode confirm/cancel buttons (painted far-right only when
    # dialog.active()). x is relative to bounds.l, mirroring items[i].x/.w;
    # both stay 0 outside dialog mode so the hit-tests never match.
    dlgSubmitX, dlgSubmitW: cint
    dlgCancelX, dlgCancelW: cint

var theMenubar*: ptr Menubar

const
  padX: cint = 10
  padY: cint = 3

proc menusClose(): bool {.cdecl, importc: "_UIMenusClose".}

# ---------- menu population ----------

proc mkOption(label: string, cmd: string = "",
              args: seq[string] = @[]): MenuOption =
  MenuOption(label: label, command: cmd, args: args)

proc rebuildFileOptions(mb: ptr Menubar) =
  mb.items[0].options = @[
    mkOption("New Tab",   "tab.new"),
    mkOption("Close Tab", "tab.close"),
    mkOption("Refresh",   "refresh"),
    mkOption("Exit",      "exit"),
  ]

proc rebuildEditOptions(mb: ptr Menubar) =
  mb.items[1].options = @[
    mkOption("Toggle Hidden",        "hidden.toggle"),
    mkOption("Toggle Preview",       "preview.toggle"),
    mkOption("Bookmark Current Dir", "bookmark.add"),
  ]

proc rebuildViewOptions(mb: ptr Menubar) =
  mb.items[2].options = @[
    mkOption("Sort: Dirs First", "sort", @["dirs-first"]),
    mkOption("Sort: Name",       "sort", @["name"]),
    mkOption("Sort: Mtime",      "sort", @["mtime"]),
    mkOption("--- Themes ---"),
  ]
  # Discovered themes (per-user override dir first, then alongside binary).
  # The currently-active one is marked with a leading `* `; everything else
  # gets two spaces so the columns line up in monospace.
  for n in theme.themeNames():
    let label = if n == theme.activeTheme: "* " & n else: "  " & n
    mb.items[2].options.add(mkOption(label, "theme", @[n]))

# ---------- runtime helpers ----------

proc firstChild(e: ptr Element): ptr Element =
  cast[ptr Element](e.children)

proc isButton(e: ptr Element): bool =
  e != nil and e.cClassName != nil and $e.cClassName == "Button"

proc nextButton(e: ptr Element): ptr Element =
  var cur = e.next
  while cur != nil and not isButton(cur): cur = cur.next
  cur

proc prevButton(first, target: ptr Element): ptr Element =
  var cur = first
  var lastBtn: ptr Element = nil
  while cur != nil and cur != target:
    if isButton(cur): lastBtn = cur
    cur = cur.next
  lastBtn

proc findPopupMenuWin(): ptr Window =
  var w = cast[ptr Window](ui.windows)
  while w != nil:
    if (w.e.flags and WINDOW_MENU) != 0: return w
    w = w.next
  return nil

proc restoreFocusAfterMenu(mb: ptr Menubar) =
  mb.menuOpen = false
  let prev = mb.prevFocus
  mb.prevFocus = nil
  if prev != nil and mb.e.window != nil:
    elementFocus(prev)
    elementRepaint(prev, nil)

proc runOption(cp: pointer) {.cdecl.} =
  if cp == nil: return
  let o = cast[ptr MenuOption](cp)
  if o.command.len > 0:
    discard runCommand(o.command, o.args)

proc menuButtonMessage(element: ptr Element, message: Message,
                       di: cint, dp: pointer): cint {.cdecl.} =
  ## Keyboard plumbing for menu items: J/K + arrows navigate, Enter clicks,
  ## Esc closes. Mirrors Prawk menubar.nim:72-95.
  if message == msgKeyTyped:
    let k = cast[ptr KeyTyped](dp)
    let code = k.code
    let first = firstChild(element.parent)
    if code == int(KEYCODE_DOWN) or code == int(KEYCODE_LETTER('J')):
      let nxt = nextButton(element)
      if nxt != nil: elementFocus(nxt)
      return 1
    if code == int(KEYCODE_UP) or code == int(KEYCODE_LETTER('K')):
      let prv = prevButton(first, element)
      if prv != nil: elementFocus(prv)
      return 1
    if code == int(KEYCODE_ENTER):
      discard elementMessage(element, msgClicked, 0, nil)
      discard menusClose()
      return 1
    if code == int(KEYCODE_ESCAPE):
      discard menusClose()
      return 1
  elif message == msgClicked:
    discard menusClose()
    return 0
  return 0

proc spawnMenu(mb: ptr Menubar, idx: int) =
  if idx < 0 or idx >= mb.items.len: return
  case idx
  of 0: rebuildFileOptions(mb)
  of 1: rebuildEditOptions(mb)
  of 2: rebuildViewOptions(mb)
  else: discard
  if mb.items[idx].options.len == 0: return
  if not mb.menuOpen and mb.e.window != nil:
    mb.prevFocus = mb.e.window.focused
  mb.menuOpen = true
  let m = menuCreate(addr mb.e, 0)
  for i in 0 ..< mb.items[idx].options.len:
    let optPtr = addr mb.items[idx].options[i]
    menuAddItem(m, 0, mb.items[idx].options[i].label.cstring,
                invoke = runOption, cp = cast[pointer](optPtr))
  menuShow(m)
  var child = firstChild(addr m.e)
  var firstBtn: ptr Element = nil
  while child != nil:
    if child.cClassName != nil and $child.cClassName == "Button":
      child.messageUser = menuButtonMessage
      if firstBtn == nil: firstBtn = child
    child = child.next
  if firstBtn != nil:
    elementFocus(firstBtn)
  elementFocus(addr mb.e)

proc openFileMenuCb*(cp: pointer) {.cdecl.} =
  if cp != nil: spawnMenu(cast[ptr Menubar](cp), 0)
proc openEditMenuCb*(cp: pointer) {.cdecl.} =
  if cp != nil: spawnMenu(cast[ptr Menubar](cp), 1)
proc openViewMenuCb*(cp: pointer) {.cdecl.} =
  if cp != nil: spawnMenu(cast[ptr Menubar](cp), 2)

# ---------- palette ----------

proc resetPalState(mb: ptr Menubar) =
  mb.palBuf = ""
  mb.palCursor = 0
  mb.histIdx = -1
  mb.histDraft = ""
  mb.palInjected = false

proc histRecall(mb: ptr Menubar, delta: int) =
  ## delta = -1: walk back (Up). +1: walk forward (Down) toward live buffer.
  if mb.history.len == 0: return
  if mb.histIdx == -1 and delta < 0:
    mb.histDraft = mb.palBuf
  var idx = mb.histIdx
  if idx == -1:
    if delta < 0: idx = mb.history.len - 1
    else: return
  else:
    idx += -delta
    if idx < 0: idx = 0
    elif idx >= mb.history.len:
      mb.histIdx = -1
      mb.palBuf = mb.histDraft
      mb.palCursor = mb.palBuf.len
      return
  mb.histIdx = idx
  mb.palBuf = mb.history[idx]
  mb.palCursor = mb.palBuf.len

proc palClampCursor(mb: ptr Menubar) =
  if mb.palCursor < 0: mb.palCursor = 0
  if mb.palCursor > mb.palBuf.len: mb.palCursor = mb.palBuf.len

proc palInsert(mb: ptr Menubar, s: string) =
  if s.len == 0: return
  palClampCursor(mb)
  let head = if mb.palCursor <= 0: "" else: mb.palBuf.substr(0, mb.palCursor - 1)
  let tail = if mb.palCursor >= mb.palBuf.len: "" else: mb.palBuf.substr(mb.palCursor)
  mb.palBuf = head & s & tail
  mb.palCursor += s.len

proc enterPalette*(mb: ptr Menubar) =
  let wasPalette = mb.palette
  discard menusClose()
  mb.palette = true
  resetPalState(mb)
  if mb.e.window != nil and not wasPalette:
    mb.prevFocus = mb.e.window.focused
  elementFocus(addr mb.e)
  elementRepaint(addr mb.e, nil)

proc exitPalette*(mb: ptr Menubar) =
  if not mb.palette: return
  mb.palette = false
  resetPalState(mb)
  let prev = mb.prevFocus
  mb.prevFocus = nil
  if prev != nil:
    elementFocus(prev)
    elementRepaint(prev, nil)
  elementRepaint(addr mb.e, nil)

proc paletteOpenCb*(cp: pointer) {.cdecl.} =
  if cp == nil: return
  enterPalette(cast[ptr Menubar](cp))

proc executePalette(mb: ptr Menubar) =
  let line = mb.palBuf.strip()
  if line.len > 0:
    if mb.history.len == 0 or mb.history[^1] != line:
      mb.history.add(line)
      const histMax = 200
      if mb.history.len > histMax:
        mb.history = mb.history[mb.history.len - histMax .. ^1]
  exitPalette(mb)
  if line.len > 0:
    clDispatch(line)

proc openPaletteWith*(text: string) =
  ## Surface a prefilled line. The injected-state flag stays set until the
  ## user touches the buffer (any key clears it) — paint draws a red
  ## border around the strip while it's true, so an unintended Enter is
  ## visually obvious.
  if theMenubar == nil: return
  enterPalette(theMenubar)
  theMenubar.palBuf = text
  theMenubar.palCursor = text.len
  theMenubar.palInjected = true
  elementRepaint(addr theMenubar.e, nil)

# ---------- element message handler ----------

proc hitItem(mb: ptr Menubar, localX: cint): int =
  for i in 0 ..< mb.items.len:
    let it = mb.items[i]
    if localX >= it.x and localX < it.x + it.w: return i
  return -1

proc menubarMessage(element: ptr Element, message: Message,
                    di: cint, dp: pointer): cint {.cdecl.} =
  let mb = cast[ptr Menubar](element)

  if message == msgGetHeight:
    let (_, gH) = glyphDims()
    return gH + 2 * padY

  elif message == msgPaint:
    let painter = cast[ptr Painter](dp)
    let (gW, _) = glyphDims()
    if mb.palette:
      drawBlock(painter, element.bounds, ui.theme.textboxFocused)
      let leftX = element.bounds.l + padX
      let txt = ":" & mb.palBuf
      let r = Rectangle(l: leftX, r: element.bounds.r,
                        t: element.bounds.t, b: element.bounds.b)
      drawString(painter, r, txt.cstring, txt.len,
                 ui.theme.text, cint(ALIGN_LEFT), nil)
      let beforeCursor = ":" & mb.palBuf.substr(0, mb.palCursor - 1)
      let cx = leftX + measureStringWidth(beforeCursor.cstring, beforeCursor.len)
      drawInvert(painter, Rectangle(l: cx, r: cx + gW,
                                    t: element.bounds.t + padY,
                                    b: element.bounds.b - padY))
      if mb.palInjected:
        drawBorder(painter, element.bounds, currentPalette.clInject,
                   Rectangle(l: 2, r: 2, t: 2, b: 2))
      return 1
    drawBlock(painter, element.bounds, ui.theme.panel2)
    var x: cint = element.bounds.l
    for i in 0 ..< mb.items.len:
      let label = mb.items[i].label
      let textW = measureStringWidth(label)
      let w = textW + 2 * padX
      let itemRect = Rectangle(l: x, r: x + w,
                               t: element.bounds.t, b: element.bounds.b)
      let bg = if i == mb.hovered: ui.theme.buttonHovered else: ui.theme.panel2
      drawBlock(painter, itemRect, bg)
      drawString(painter, itemRect, label, -1,
                 ui.theme.text, cint(ALIGN_CENTER), nil)
      mb.items[i].x = x - element.bounds.l
      mb.items[i].w = w
      x += w
    if dialog.active():
      # Far-right submit + a Cancel to its left. Submit gets the hovered
      # button tint so it reads as the primary action; Cancel sits flat.
      let sLabel = dialog.submitLabel()
      let cLabel = "Cancel"
      let sW = measureStringWidth(sLabel.cstring) + 2 * padX
      let cW = measureStringWidth(cLabel.cstring) + 2 * padX
      let sX = element.bounds.r - sW
      let cX = sX - cW
      let sRect = Rectangle(l: sX, r: sX + sW,
                            t: element.bounds.t, b: element.bounds.b)
      let cRect = Rectangle(l: cX, r: cX + cW,
                            t: element.bounds.t, b: element.bounds.b)
      drawBlock(painter, sRect, ui.theme.buttonHovered)
      drawString(painter, sRect, sLabel.cstring, -1,
                 ui.theme.text, cint(ALIGN_CENTER), nil)
      drawBlock(painter, cRect, ui.theme.panel2)
      drawString(painter, cRect, cLabel.cstring, -1,
                 ui.theme.text, cint(ALIGN_CENTER), nil)
      mb.dlgSubmitX = sX - element.bounds.l
      mb.dlgSubmitW = sW
      mb.dlgCancelX = cX - element.bounds.l
      mb.dlgCancelW = cW
    return 1

  elif message == msgKeyTyped:
    if mb.menuOpen:
      let popup = findPopupMenuWin()
      if popup == nil:
        restoreFocusAfterMenu(mb)
        return 0
      let target = popup.focused
      var rc: cint = 0
      if target != nil:
        rc = elementMessage(target, msgKeyTyped, di, dp)
      if findPopupMenuWin() == nil:
        restoreFocusAfterMenu(mb)
      return rc
    if not mb.palette: return 0
    let k = cast[ptr KeyTyped](dp)
    let code = k.code
    # Any keystroke means the user is engaging — drop the injected flag so
    # the red border goes away. Enter/Esc clear via resetPalState anyway.
    mb.palInjected = false
    if code == int(KEYCODE_ESCAPE):
      exitPalette(mb); return 1
    if code == int(KEYCODE_ENTER):
      executePalette(mb); return 1
    if code == int(KEYCODE_LEFT):
      if mb.palCursor > 0: dec mb.palCursor
      elementRepaint(element, nil); return 1
    if code == int(KEYCODE_RIGHT):
      if mb.palCursor < mb.palBuf.len: inc mb.palCursor
      elementRepaint(element, nil); return 1
    if code == int(KEYCODE_UP):
      histRecall(mb, -1); elementRepaint(element, nil); return 1
    if code == int(KEYCODE_DOWN):
      histRecall(mb, +1); elementRepaint(element, nil); return 1
    if code == int(KEYCODE_HOME):
      mb.palCursor = 0; elementRepaint(element, nil); return 1
    if code == int(KEYCODE_END):
      mb.palCursor = mb.palBuf.len; elementRepaint(element, nil); return 1
    if code == int(KEYCODE_BACKSPACE):
      if mb.palCursor > 0:
        let head = if mb.palCursor <= 1: "" else: mb.palBuf.substr(0, mb.palCursor - 2)
        let tail = if mb.palCursor >= mb.palBuf.len: "" else: mb.palBuf.substr(mb.palCursor)
        mb.palBuf = head & tail
        dec mb.palCursor
      elementRepaint(element, nil); return 1
    if code == int(KEYCODE_DELETE):
      if mb.palCursor < mb.palBuf.len:
        let head = if mb.palCursor <= 0: "" else: mb.palBuf.substr(0, mb.palCursor - 1)
        let tail = if mb.palCursor + 1 >= mb.palBuf.len: "" else: mb.palBuf.substr(mb.palCursor + 1)
        mb.palBuf = head & tail
      elementRepaint(element, nil); return 1
    if k.textBytes > 0:
      var s = newString(int(k.textBytes))
      copyMem(addr s[0], k.text, int(k.textBytes))
      palInsert(mb, s)
      elementRepaint(element, nil)
      return 1
    return 1

  elif message == msgMouseMove:
    # Keep the alt-hints reveal in sync if Alt is released over the menubar.
    althints.reconcile(element.window)
    if mb.palette: return 0
    let w = element.window
    if w != nil:
      let lx = w.cursorX - element.bounds.l
      let h = hitItem(mb, lx)
      if h != mb.hovered:
        mb.hovered = h
        elementRepaint(element, nil)
    return 0

  elif message == msgLeftDown:
    let w = element.window
    if w == nil: return 0
    if mb.palette:
      # Click within palette is just a focus grab — cursor positioning by
      # mouse is out of scope until we measure glyph offsets.
      return 1
    let lx = w.cursorX - element.bounds.l
    if dialog.active():
      if lx >= mb.dlgSubmitX and lx < mb.dlgSubmitX + mb.dlgSubmitW:
        if dialog.mode == dmSave:
          # Surface `:confirm <name>` prefilled (red injected border) so the
          # user names the file before Enter dispatches it.
          openPaletteWith("confirm " & dialog.suggestName)
        else:
          discard runCommand("confirm")
        return 1
      if lx >= mb.dlgCancelX and lx < mb.dlgCancelX + mb.dlgCancelW:
        discard runCommand("cancel")
        return 1
    let h = hitItem(mb, lx)
    if h < 0: return 0
    spawnMenu(mb, h)
    return 1

  return 0

proc menubarCreate*(parent: ptr Element, flags: uint32 = 0): ptr Menubar =
  let e = elementCreate(csize_t(sizeof(Menubar)), parent,
                        flags or ELEMENT_TAB_STOP,
                        menubarMessage, "ExrawkMenubar")
  let mb = cast[ptr Menubar](e)
  mb.items[0] = MenuItem(label: cstring"File")
  mb.items[1] = MenuItem(label: cstring"Edit")
  mb.items[2] = MenuItem(label: cstring"View")
  mb.hovered = -1
  theMenubar = mb
  # Expose palette injection through the commands.* callback so other
  # modules (bookmarks dirty-prompt, future drag-and-drop, etc.) can fill
  # the palette without depending on menubar.
  commands.openPaletteWithCb = proc(text: string) = openPaletteWith(text)
  return mb
