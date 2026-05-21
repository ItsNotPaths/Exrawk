## Exrawk — a rawk applet: yazi-style 3-panel file explorer.
##
## Layout (top→bottom, then left→right inside rootSplit):
##   menubar    File / Edit / View, swaps to a `:` command palette on Alt+C
##   rootSplit
##     leftPanel   — bookmarked directories                     (milestone 5)
##     midRight
##       midCol    — tab strip + file list
##       preview   — rawk-bufferlib editor (read-only)          (milestone 6)
##
## Hotkeys are thin wrappers around the commands registry: every action
## a hotkey performs is also typeable in the palette (and vice-versa).

import std/os
import rawk_luigi, rawk_bufferlib
import config, state, filelist, tabs, commands, cldispatch, menubar, bookmarks, preview, opener, icons, althints, yank, theme

# ---------- argv ----------

var startDir*: string

proc resolveArgv() =
  if paramCount() == 0:
    startDir = getCurrentDir()
    return
  let arg = paramStr(1)
  if dirExists(arg):
    startDir = absolutePath(arg)
  elif fileExists(arg):
    startDir = absolutePath(arg.parentDir)
  else:
    startDir = getCurrentDir()

# ---------- shortcut → command shims ----------
#
# wayluigi shortcut callbacks are cdecl and can't capture closures, so
# every binding gets its own thin proc. The body is a single runCommand
# dispatch — keeps the hotkey path and `:tab.*` palette path in lock-step.

proc scTabNew(cp: pointer)   {.cdecl.} = discard runCommand("tab.new",   @[])
proc scTabClose(cp: pointer) {.cdecl.} = discard runCommand("tab.close", @[])
proc scTabNext(cp: pointer)  {.cdecl.} = discard runCommand("tab.next",  @[])
proc scTabPrev(cp: pointer)  {.cdecl.} = discard runCommand("tab.prev",  @[])

# ---------- Alt file-action shims (the alt-hints reveal) ----------
#
# Each former chord follower is now a window-level Alt+<key> shortcut.
# Immediate ops dispatch straight through the registry / yank queue;
# the destructive / arg-template ops (delete, move, new) prefill the
# palette via openPaletteWith with the rawk-red injected border, exactly
# as the old chord-inject path did, so an unintended Enter stays visible.

proc selPath(): string =
  let t = state.activeTab()
  if t == nil or t.entries.len == 0: "" else: t.cwd / t.entries[t.selectedIdx].name
proc cwdPath(): string =
  let t = state.activeTab()
  if t == nil: "" else: t.cwd

proc inject(payload: string) =
  if openPaletteWithCb != nil: openPaletteWithCb(payload)

proc scYank(cp: pointer)       {.cdecl.} = (let s = selPath(); (if s.len > 0: yank.replaceWith(s)))
proc scYankAdd(cp: pointer)    {.cdecl.} = (let s = selPath(); (if s.len > 0: yank.add(s)))
proc scPaste(cp: pointer)      {.cdecl.} = discard runCommand("paste")
proc scBookmark(cp: pointer)   {.cdecl.} = discard runCommand("bookmark.add")
proc scRefresh(cp: pointer)    {.cdecl.} = discard runCommand("refresh")
proc scHidden(cp: pointer)     {.cdecl.} = discard runCommand("hidden.toggle")
proc scCopyPath(cp: pointer)   {.cdecl.} = (let s = selPath(); (if s.len > 0: discard runCommand("clip", @[s])))
proc scCopyFolder(cp: pointer) {.cdecl.} = (let s = cwdPath(); (if s.len > 0: discard runCommand("clip", @[s])))
proc scDelete(cp: pointer)     {.cdecl.} = (let s = selPath(); (if s.len > 0: inject("rm -rf " & quoteForPalette(s))))
proc scMove(cp: pointer)       {.cdecl.} = (let s = selPath(); (if s.len > 0: inject("mv " & quoteForPalette(s) & " ")))
proc scNew(cp: pointer)        {.cdecl.} = inject("new ")   # name → file; name/ → dir

# ---------- window-level Alt observer ----------
#
# luigi dispatches msgKeyTyped to the window element for every keypress,
# including the bare Alt press. We can't just reconcile against window.alt
# on that press: on Wayland the wl_keyboard.modifiers event that sets
# window.alt frequently arrives *after* the key event, so window.alt is
# still false at this point (on X11 it's already set — both paths are
# handled). So when the key *is* an Alt keysym, force the reveal on
# directly; for any other key, sync to the current modifier state. The
# per-pane + window mouse-move hooks handle the release. Always returns 0
# so the key still reaches the shortcut layer below.
const altKeysyms = [0xffe9, 0xffea, 0xffe7, 0xffe8]  # Alt_L/R, Meta_L/R
                                                     # (X11 & xkb share keysym values)

proc onWinMsg(element: ptr Element, message: Message,
              di: cint, dp: pointer): cint {.cdecl.} =
  if message == msgKeyTyped:
    let k = cast[ptr KeyTyped](dp)
    if k.code in altKeysyms:
      althints.setHeld(true)
    else:
      althints.reconcile(element.window)
  elif message == msgMouseMove:
    althints.reconcile(element.window)
  return 0

# ---------- main ----------

initialise()
config.loadConfig()
theme.activeTheme = config.themePref
theme.loadInitialTheme()             # apply palette before any widget paints
themeInstall()                       # wire :theme into the registry
loadFont(config.fontSize)            # bufferlib's default font (preview pane)
loadAllSyntaxes()
installIcons()                       # vendored yazi mapping + activate
                                     # nerd-font for the file list glyphs
resolveArgv()
registerBuiltins()
openerInstall()

discard state.newTab(startDir)
state.setActive(0)

let win = windowCreate(nil, 0, "Exrawk", 1100, 700)
let root = panelCreate(addr win.e, PANEL_GRAY or PANEL_EXPAND)

let mb = menubarCreate(addr root.e)

let rootSplit = splitPaneCreate(addr root.e,
                                ELEMENT_V_FILL or ELEMENT_H_FILL,
                                0.20)

# Left — bookmarks pane stacked with a hidden alt-hints panel. Holding Alt
# flips the ELEMENT_HIDE bits to swap between the two (see althints.nim).
let leftPanel = panelCreate(addr rootSplit.e, PANEL_GRAY or PANEL_EXPAND)
let bm = bookmarksCreate(addr leftPanel.e, ELEMENT_V_FILL or ELEMENT_H_FILL)
discard altHintsCreate(addr leftPanel.e)
althints.theBookmarksEl = addr bm.e
# `hints` is initially hidden via the create-flags; reconcile() shows it
# while Alt is held.

let midRight = splitPaneCreate(addr rootSplit.e,
                               ELEMENT_V_FILL or ELEMENT_H_FILL,
                               0.50)

let midCol = panelCreate(addr midRight.e, PANEL_GRAY or PANEL_EXPAND)
discard tabstripCreate(addr midCol.e)
let fl = filelistCreate(addr midCol.e, ELEMENT_V_FILL or ELEMENT_H_FILL)

# Right — preview pane: title bar + editor stacked vertically inside a
# panel, mirroring midCol so both columns line up under the same top row.
let rightCol = panelCreate(addr midRight.e, PANEL_GRAY or PANEL_EXPAND)
discard previewTitleCreate(addr rightCol.e)
discard previewCreate(addr rightCol.e)

# Window-level shortcuts.
windowRegisterShortcut(win, Shortcut(
  code: int(KEYCODE_LETTER('C')), alt: true,
  invoke: paletteOpenCb, cp: cast[pointer](mb)))
windowRegisterShortcut(win, Shortcut(
  code: int(KEYCODE_LETTER('F')), alt: true,
  invoke: openFileMenuCb, cp: cast[pointer](mb)))
windowRegisterShortcut(win, Shortcut(
  code: int(KEYCODE_LETTER('E')), alt: true,
  invoke: openEditMenuCb, cp: cast[pointer](mb)))
windowRegisterShortcut(win, Shortcut(
  code: int(KEYCODE_LETTER('V')), alt: true,
  invoke: openViewMenuCb, cp: cast[pointer](mb)))

# Tab cycling / management. These dispatch through runCommand so muscle-
# memory hotkeys and `:tab.*` palette commands stay in lock-step.
windowRegisterShortcut(win, Shortcut(
  code: int(KEYCODE_LEFT),  alt: true, shift: true, invoke: scTabPrev))
windowRegisterShortcut(win, Shortcut(
  code: int(KEYCODE_RIGHT), alt: true, shift: true, invoke: scTabNext))
windowRegisterShortcut(win, Shortcut(
  code: int(KEYCODE_LETTER('T')), alt: true, invoke: scTabNew))
windowRegisterShortcut(win, Shortcut(
  code: int(KEYCODE_LETTER('Q')), alt: true, invoke: scTabClose))

# Alt file-actions — the bindings surfaced in the alt-hints reveal. The
# Shift variants (add-yank, copy-folder, new-dir) register as separate
# shortcuts; luigi matches on the full ctrl/shift/alt state.
windowRegisterShortcut(win, Shortcut(
  code: int(KEYCODE_LETTER('Y')), alt: true, invoke: scYank))
# Shift+letter is backend-split: X11 reports the unshifted keysym (XK_y),
# Wayland the shifted one (XK_Y == int('Y')). Register both so either matches.
windowRegisterShortcut(win, Shortcut(
  code: int(KEYCODE_LETTER('Y')), alt: true, shift: true, invoke: scYankAdd))
windowRegisterShortcut(win, Shortcut(
  code: int('Y'), alt: true, shift: true, invoke: scYankAdd))
windowRegisterShortcut(win, Shortcut(
  code: int(KEYCODE_LETTER('P')), alt: true, invoke: scPaste))
windowRegisterShortcut(win, Shortcut(
  code: int(KEYCODE_LETTER('D')), alt: true, invoke: scDelete))
windowRegisterShortcut(win, Shortcut(
  code: int(KEYCODE_LETTER('X')), alt: true, invoke: scMove))
windowRegisterShortcut(win, Shortcut(
  code: int(KEYCODE_LETTER('N')), alt: true, invoke: scNew))
windowRegisterShortcut(win, Shortcut(
  code: int(KEYCODE_LETTER('W')), alt: true, invoke: scCopyPath))
windowRegisterShortcut(win, Shortcut(
  code: int(KEYCODE_LETTER('W')), alt: true, shift: true, invoke: scCopyFolder))
windowRegisterShortcut(win, Shortcut(
  code: int('W'), alt: true, shift: true, invoke: scCopyFolder))
windowRegisterShortcut(win, Shortcut(
  code: int(KEYCODE_LETTER('B')), alt: true, invoke: scBookmark))
windowRegisterShortcut(win, Shortcut(
  code: int(KEYCODE_LETTER('R')), alt: true, invoke: scRefresh))
windowRegisterShortcut(win, Shortcut(
  code: int(KEYCODE_LETTER('H')), alt: true, invoke: scHidden))

# Window-level Alt observer: shows the alt-hints reveal the instant Alt
# goes down (the per-pane mouse-move hooks handle the release).
win.e.messageUser = onWinMsg

elementFocus(addr fl.e)
quit messageLoop()
