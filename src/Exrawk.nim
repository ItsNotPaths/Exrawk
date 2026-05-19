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
import config, state, filelist, tabs, commands, menubar, bookmarks, preview, opener, icons, chord, theme

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

# Left — bookmarks pane stacked with a hidden chord-help. Chord mode flips
# the ELEMENT_HIDE bits to swap between the two (see chord.nim).
let leftPanel = panelCreate(addr rootSplit.e, PANEL_GRAY or PANEL_EXPAND)
let bm = bookmarksCreate(addr leftPanel.e, ELEMENT_V_FILL or ELEMENT_H_FILL)
let help = chordHelpCreate(addr leftPanel.e)
chord.theBookmarksEl = addr bm.e
# `help` is initially hidden via the create-flags; chord.enter shows it.

let midRight = splitPaneCreate(addr rootSplit.e,
                               ELEMENT_V_FILL or ELEMENT_H_FILL,
                               0.50)

let midCol = panelCreate(addr midRight.e, PANEL_GRAY or PANEL_EXPAND)
discard tabstripCreate(addr midCol.e)
let fl = filelistCreate(addr midCol.e, ELEMENT_V_FILL or ELEMENT_H_FILL)

# Right — preview pane (rawk-bufferlib editor, read-only by convention).
discard previewCreate(addr midRight.e)

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

elementFocus(addr fl.e)
quit messageLoop()
