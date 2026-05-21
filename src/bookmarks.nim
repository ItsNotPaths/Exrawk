## Bookmarks — left-pane list of saved directories.
##
## File format: `~/.config/Exrawk/bookmarks`, one absolute path per line.
## Order in the file is the display order. On disk dedupe is preserved
## (we read once at startup, mutate in-memory, atomic-write on every
## change).
##
## Keyboard: j/k/arrows navigate, Enter cd's the active tab to the
## selection, d removes the selected entry. `bookmark.add` /
## `bookmark.del` from the palette go through the same code path.

import std/[os, strutils]
import rawk_luigi, rawk_bufferlib
import commands, state, config, icons, althints

type
  BookmarksPane* = object
    e*:            Element
    items*:        seq[string]
    selectedIdx*:  int
    scrollTop*:    int

var theBookmarks*: ptr BookmarksPane

# ---------- persistence ----------

proc atomicWrite(path, body: string) =
  let tmp = path & ".tmp"
  writeFile(tmp, body)
  moveFile(tmp, path)

proc load(bm: ptr BookmarksPane) =
  bm.items.setLen(0)
  let path = bookmarksPath()
  if not fileExists(path): return
  for raw in lines(path):
    let line = raw.strip()
    if line.len == 0 or line.startsWith('#'): continue
    if line in bm.items: continue
    bm.items.add(line)

proc persist(bm: ptr BookmarksPane) =
  createDir(configDir())
  atomicWrite(bookmarksPath(), bm.items.join("\n") & "\n")

# ---------- mutations (also driven by registry callbacks) ----------

proc addPath(bm: ptr BookmarksPane, path: string) =
  let abs = absolutePath(path).normalizedPath
  if abs.len == 0 or not dirExists(abs): return
  if abs in bm.items: return
  bm.items.add(abs)
  persist(bm)
  if bm.e.window != nil: elementRepaint(addr bm.e, nil)

proc delPath(bm: ptr BookmarksPane, path: string) =
  let abs = absolutePath(path).normalizedPath
  let idx = bm.items.find(abs)
  if idx < 0: return
  bm.items.delete(idx)
  if bm.selectedIdx >= bm.items.len:
    bm.selectedIdx = max(0, bm.items.len - 1)
  persist(bm)
  if bm.e.window != nil: elementRepaint(addr bm.e, nil)

# ---------- rendering helpers ----------

proc rowHeight(): cint =
  let (_, gH) = glyphDims()
  gH

proc visibleRows(bm: ptr BookmarksPane): int =
  let h = bm.e.bounds.b - bm.e.bounds.t
  max(1, int(h) div max(1, int(rowHeight())))

proc clampScroll(bm: ptr BookmarksPane) =
  let vr = visibleRows(bm)
  let n = bm.items.len
  let maxTop = max(0, n - vr)
  if bm.scrollTop < 0: bm.scrollTop = 0
  if bm.scrollTop > maxTop: bm.scrollTop = maxTop
  if bm.selectedIdx < 0: bm.selectedIdx = 0
  if bm.selectedIdx >= n: bm.selectedIdx = max(0, n - 1)

proc followSelection(bm: ptr BookmarksPane) =
  let vr = visibleRows(bm)
  if bm.selectedIdx < bm.scrollTop:
    bm.scrollTop = bm.selectedIdx
  elif bm.selectedIdx >= bm.scrollTop + vr:
    bm.scrollTop = bm.selectedIdx - vr + 1
  if bm.scrollTop < 0: bm.scrollTop = 0

proc displayName(path: string): string =
  ## Just the last segment, with a `..` prefix that hints "this is a path,
  ## not a relative entry". Yazi-style: `~/Downloads` shows as `..Downloads`.
  ## Root `/` and HOME are special-cased so they're recognizable.
  let p = path.strip(trailing = true, chars = {'/'})
  if p.len == 0: return "/"
  if p == getHomeDir().strip(trailing = true, chars = {'/'}): return "..~"
  let leaf = p.lastPathPart
  ".." & leaf

proc isActiveCwd(path: string): bool =
  let t = state.activeTab()
  t != nil and t.cwd == path

# ---------- element message handler ----------

proc bookmarksMessage(element: ptr Element, message: Message,
                      di: cint, dp: pointer): cint {.cdecl.} =
  let bm = cast[ptr BookmarksPane](element)

  if message == msgPaint:
    let painter = cast[ptr Painter](dp)
    drawBlock(painter, element.bounds, ui.theme.panel1)
    let rh = rowHeight()
    let vr = visibleRows(bm)
    let focused = element.window != nil and element.window.focused == element
    for i in 0 ..< vr:
      let idx = bm.scrollTop + i
      if idx >= bm.items.len: break
      let y = element.bounds.t + cint(i) * rh
      let rowRect = Rectangle(l: element.bounds.l,
                              r: element.bounds.r,
                              t: y, b: y + rh)
      let isSel = (idx == bm.selectedIdx) and focused
      let isCur = (idx == bm.selectedIdx)
      let item = bm.items[idx]
      let isHere = isActiveCwd(item)
      let bg =
        if isSel: ui.theme.selected
        elif isCur: ui.theme.panel2
        elif isHere: ui.theme.buttonHovered
        else: ui.theme.panel1
      drawBlock(painter, rowRect, bg)
      # Icon column — reuse the filelist's yazi mapping so bookmarks
      # styled with category-specific glyphs (Downloads, Desktop, etc.)
      # pick those up automatically.
      let (gW, _) = glyphDims()
      let hint = EntryHint(isDir: true, isLink: false, isExec: false,
                           name: item.lastPathPart)
      let rule = lookupRule(hint)
      let glyphColor = if isSel: ui.theme.textSelected else: rule.color
      withIconFont:
        drawGlyphCp(painter, rowRect.l + 6,
                    rowRect.t + (rh - gW) div 2,
                    rule.cp, glyphColor)
      # Just the leaf with a `..` prefix; full path lives on disk.
      let label = displayName(item)
      let fg = if isSel: ui.theme.textSelected else: ui.theme.text
      let textRect = Rectangle(l: rowRect.l + 6 + gW * 2,
                               r: rowRect.r - 2,
                               t: rowRect.t, b: rowRect.b)
      drawString(painter, textRect, label.cstring, label.len,
                 fg, cint(ALIGN_LEFT), nil)
    if focused:
      drawBorder(painter, element.bounds, ui.theme.selected,
                 Rectangle(l: 1, r: 1, t: 1, b: 1))
    return 1

  elif message == msgLeftDown:
    elementFocus(element)
    let w = element.window
    if w != nil:
      let ly = w.cursorY - element.bounds.t
      let row = bm.scrollTop + int(ly div max(1, rowHeight()))
      if row >= 0 and row < bm.items.len:
        bm.selectedIdx = row
        elementRepaint(element, nil)
    return 1

  elif message == msgMouseWheel:
    bm.scrollTop += int(di) div 60
    clampScroll(bm)
    elementRepaint(element, nil)
    return 1

  elif message == msgMouseMove:
    # Catch Alt-release while the cursor is over the bookmarks pane (luigi
    # mouse-moves the hovered element on each modifier transition).
    althints.reconcile(element.window)
    return 0

  elif message == msgKeyTyped:
    let k = cast[ptr KeyTyped](dp)
    let w = element.window
    if w != nil and w.alt: return 0
    let code = k.code
    let n = bm.items.len
    if code == int(KEYCODE_DOWN) or code == int(KEYCODE_LETTER('J')):
      if bm.selectedIdx < n - 1: inc bm.selectedIdx
    elif code == int(KEYCODE_UP) or code == int(KEYCODE_LETTER('K')):
      if bm.selectedIdx > 0: dec bm.selectedIdx
    elif code == int(KEYCODE_HOME):
      bm.selectedIdx = 0
    elif code == int(KEYCODE_END):
      bm.selectedIdx = max(0, n - 1)
    elif code == int(KEYCODE_ENTER) or
         code == int(KEYCODE_RIGHT) or
         code == int(KEYCODE_LETTER('L')):
      if n > 0:
        let path = bm.items[bm.selectedIdx]
        if w != nil and w.shift:
          # Shift+Enter → open in a fresh tab instead of replacing the
          # current one. Useful when you want to compare two locations
          # side-by-side via the tab strip.
          discard runCommand("tab.new", @[path])
        else:
          discard runCommand("cd", @[path])
        # Activating a bookmark is "go look at that folder" — focus
        # belongs in the file list, not in the picker that triggered it.
        discard runCommand("focus.files", @[])
      return 1
    elif (code == int(KEYCODE_DELETE) or
          (k.text != nil and k.textBytes > 0 and
           (k.text[0] == 'd' or k.text[0] == 'q'))):
      if n > 0:
        delPath(bm, bm.items[bm.selectedIdx])
      return 1
    else:
      return 0
    followSelection(bm)
    elementRepaint(element, nil)
    return 1

  return 0

proc bookmarksCreate*(parent: ptr Element, flags: uint32 = 0): ptr BookmarksPane =
  let e = elementCreate(csize_t(sizeof(BookmarksPane)), parent,
                        flags or ELEMENT_TAB_STOP,
                        bookmarksMessage, "ExrawkBookmarks")
  let bm = cast[ptr BookmarksPane](e)
  theBookmarks = bm
  load(bm)

  # Surface this pane through the commands registry. Anything that wants to
  # add/remove a bookmark (palette, future right-click on a tree node) goes
  # through these — keeps the file format change one-step removed.
  commands.bookmarkAddCb = proc(path: string) =
    if theBookmarks != nil: addPath(theBookmarks, path)
  commands.bookmarkDelCb = proc(path: string) =
    if theBookmarks != nil: delPath(theBookmarks, path)
  commands.focusBookmarksCb = proc() =
    if theBookmarks != nil:
      elementFocus(addr theBookmarks.e)
      elementRepaint(addr theBookmarks.e, nil)

  # Repaint when the active cwd moves (the "you are here" highlight tracks
  # the file list).
  state.subscribe(proc() =
    if theBookmarks != nil and theBookmarks.e.window != nil:
      elementRepaint(addr theBookmarks.e, nil))
  return bm
