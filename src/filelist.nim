## Filelist — the middle pane. Renders the active tab's directory entries
## as a scrollable list; owns hjkl / arrows / Enter / Backspace / `.`.
##
## Modeled after Prawk's resultspane.nim (custom Element subclass, paint
## per visible row, scroll-follow on selection). Icons go in milestone 8;
## for now each row is just the name with a leading kind glyph (D/F/L/?).
##
## Widget tree:
##   FileList (the Element below — has its own paint + key handler)

import std/os
import rawk_luigi, rawk_bufferlib
import state, commands, icons, chord, yank

type
  FileList* = object
    e*: Element

var theFileList*: ptr FileList

# ---------- helpers ----------

proc rowHeight(): cint =
  let (_, gH) = glyphDims()
  gH

proc visibleRows(fl: ptr FileList): int =
  let h = fl.e.bounds.b - fl.e.bounds.t
  max(1, int(h) div max(1, int(rowHeight())))

proc clampScroll(fl: ptr FileList) =
  let t = state.activeTab()
  if t == nil: return
  let vr = visibleRows(fl)
  let n = t.entries.len
  let maxTop = max(0, n - vr)
  if t.scrollTop < 0: t.scrollTop = 0
  if t.scrollTop > maxTop: t.scrollTop = maxTop
  if t.selectedIdx < 0: t.selectedIdx = 0
  if t.selectedIdx >= n: t.selectedIdx = max(0, n - 1)

proc followSelection(fl: ptr FileList) =
  let t = state.activeTab()
  if t == nil: return
  let vr = visibleRows(fl)
  if t.selectedIdx < t.scrollTop:
    t.scrollTop = t.selectedIdx
  elif t.selectedIdx >= t.scrollTop + vr:
    t.scrollTop = t.selectedIdx - vr + 1
  if t.scrollTop < 0: t.scrollTop = 0

proc kindGlyph(k: EntryKind): char =
  ## Placeholder until milestone 8 wires real icons. Matches yazi's coarse
  ## taxonomy so even the ASCII fallback is readable.
  case k
  of ekDir:     'D'
  of ekFile:    'F'
  of ekSymlink: 'L'
  of ekOther:   '?'

# ---------- actions (consumed by msgKeyTyped) ----------

proc openSelection*(fl: ptr FileList) =
  ## Routes through the commands registry so menus, hotkeys, and the
  ## palette all share one entry point.
  discard runCommand("open", @[])

proc parentDir*() =
  discard runCommand("cd", @[".."])

# ---------- paint / event handler ----------

proc filelistMessage(element: ptr Element, message: Message,
                     di: cint, dp: pointer): cint {.cdecl.} =
  let fl = cast[ptr FileList](element)

  if message == msgPaint:
    let painter = cast[ptr Painter](dp)
    drawBlock(painter, element.bounds, ui.theme.panel1)
    let t = state.activeTab()
    if t == nil: return 1
    let rh = rowHeight()
    let (gW, _) = glyphDims()
    let vr = visibleRows(fl)
    for i in 0 ..< vr:
      let idx = t.scrollTop + i
      if idx >= t.entries.len: break
      let y = element.bounds.t + cint(i) * rh
      let rowRect = Rectangle(l: element.bounds.l,
                              r: element.bounds.r,
                              t: y, b: y + rh)
      let isSel = (idx == t.selectedIdx) and
                  element.window != nil and
                  element.window.focused == element
      let isCur = (idx == t.selectedIdx)
      let bg = if isSel: ui.theme.selected
               elif isCur: ui.theme.panel2
               else: ui.theme.panel1
      drawBlock(painter, rowRect, bg)
      let entry = t.entries[idx]
      # Yank-queue indicator — narrow green bar at the row's left edge,
      # before the icon. Hardcoded green; the theme palette doesn't
      # currently carry a "yank" slot.
      let entryPath = t.cwd / entry.name
      if yank.contains(entryPath):
        let barRect = Rectangle(l: rowRect.l,
                                r: rowRect.l + 3,
                                t: rowRect.t + 1, b: rowRect.b - 1)
        drawBlock(painter, barRect, 0x66bb6a'u32)
      let fg = if isSel: ui.theme.textSelected else: ui.theme.text
      # Icon — yazi mapping. The glyph paints in its theme color unless the
      # row is the selected highlight, in which case we tint with the
      # selection foreground for contrast.
      let hint = EntryHint(
        isDir:  (entry.kind == ekDir),
        isLink: (entry.kind == ekSymlink),
        isExec: false,
        name:   entry.name)
      let rule = lookupRule(hint)
      let glyphColor = if isSel: ui.theme.textSelected else: rule.color
      withIconFont:
        drawGlyphCp(painter, rowRect.l + 6,
                    rowRect.t + (rh - gW) div 2,
                    rule.cp, glyphColor)
      # Name column. 2 cells of horizontal padding past the glyph.
      let nameRect = Rectangle(l: rowRect.l + 6 + gW * 2,
                               r: rowRect.r - 4,
                               t: rowRect.t, b: rowRect.b)
      drawString(painter, nameRect,
                 entry.name.cstring, entry.name.len,
                 fg, cint(ALIGN_LEFT), nil)
    if element.window != nil and element.window.focused == element:
      drawBorder(painter, element.bounds, ui.theme.selected,
                 Rectangle(l: 1, r: 1, t: 1, b: 1))
    return 1

  elif message == msgLeftDown:
    elementFocus(element)
    let w = element.window
    let t = state.activeTab()
    if w != nil and t != nil:
      let ly = w.cursorY - element.bounds.t
      let row = t.scrollTop + int(ly div max(1, rowHeight()))
      if row >= 0 and row < t.entries.len and row != t.selectedIdx:
        t.selectedIdx = row
        state.notify()
    return 1

  elif message == msgMouseWheel:
    let t = state.activeTab()
    if t != nil:
      t.scrollTop += int(di) div 60
      clampScroll(fl)
      elementRepaint(element, nil)
    return 1

  elif message == msgKeyTyped:
    let k = cast[ptr KeyTyped](dp)
    let w = element.window
    if w != nil and w.alt: return 0     # Alt+x belongs to window shortcuts
    let code = k.code
    let t = state.activeTab()
    if t == nil: return 0

    let shift = w != nil and w.shift
    let ctrl  = w != nil and w.ctrl

    # Chord-leader takes precedence. When active the next keystroke is
    # the follower; recognized → consumed, unrecognized → exit chord and
    # let the rest of this handler process the key (so `c b` exits chord
    # AND jumps focus to bookmarks instead of swallowing the b).
    if chord.active:
      if code == int(KEYCODE_ESCAPE):
        chord.exit()
        elementRepaint(element, nil)
        return 1
      if k.text != nil and k.textBytes > 0:
        if chord.handleFollower(k.text[0], shift, ctrl):
          elementRepaint(element, nil)
          return 1
        chord.exit()
        elementRepaint(element, nil)
        # fall through — this key now hits the normal bindings below
      else:
        chord.exit()
        elementRepaint(element, nil)
        return 1

    # `c` (bare, no modifier) enters chord mode. The bookmarks pane swaps
    # to the chord-help element on the left.
    if k.text != nil and k.textBytes > 0 and k.text[0] == 'c':
      chord.enter()
      elementRepaint(element, nil)
      return 1

    # `b` → focus the bookmarks pane. (Adding a bookmark goes through the
    # chord-leader: c-b.)
    if k.text != nil and k.textBytes > 0 and k.text[0] == 'b':
      discard runCommand("focus.bookmarks", @[])
      return 1

    let prevSel = t.selectedIdx
    if code == int(KEYCODE_DOWN) or code == int(KEYCODE_LETTER('J')):
      if t.selectedIdx < t.entries.len - 1: inc t.selectedIdx
    elif code == int(KEYCODE_UP) or code == int(KEYCODE_LETTER('K')):
      if t.selectedIdx > 0: dec t.selectedIdx
    elif code == int(KEYCODE_HOME):
      t.selectedIdx = 0
    elif code == int(KEYCODE_END):
      t.selectedIdx = max(0, t.entries.len - 1)
    elif code == int(KEYCODE_ENTER) or
         code == int(KEYCODE_RIGHT) or
         code == int(KEYCODE_LETTER('L')):
      openSelection(fl)
      return 1
    elif code == int(KEYCODE_BACKSPACE) or
         code == int(KEYCODE_LEFT) or
         code == int(KEYCODE_LETTER('H')):
      parentDir()
      return 1
    elif k.text != nil and k.textBytes > 0 and k.text[0] == '.':
      discard runCommand("hidden.toggle", @[])
      return 1
    else:
      return 0
    followSelection(fl)
    # Notify on selection change so the preview pane reloads. Other
    # subscribers (tabs, bookmarks) repaint cheaply on the same signal.
    if t.selectedIdx != prevSel:
      state.notify()
      # Shift held during a cursor move = yank multiselect. Extends the
      # queue with the new selection; releasing shift returns to plain
      # navigation. Yazi-style range-yank.
      if shift and t.entries.len > 0:
        yank.add(t.cwd / t.entries[t.selectedIdx].name)
    elementRepaint(element, nil)
    return 1

  return 0

proc filelistCreate*(parent: ptr Element, flags: uint32 = 0): ptr FileList =
  let e = elementCreate(csize_t(sizeof(FileList)), parent,
                        flags or ELEMENT_TAB_STOP,
                        filelistMessage, "ExrawkFileList")
  let fl = cast[ptr FileList](e)
  theFileList = fl
  state.subscribe(proc() =
    if theFileList != nil and theFileList.e.window != nil:
      elementRepaint(addr theFileList.e, nil))
  yank.onChange = proc() =
    if theFileList != nil and theFileList.e.window != nil:
      elementRepaint(addr theFileList.e, nil)
  commands.focusFilesCb = proc() =
    if theFileList != nil:
      elementFocus(addr theFileList.e)
      elementRepaint(addr theFileList.e, nil)
  return fl
