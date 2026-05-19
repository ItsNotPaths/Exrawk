## Commands — closure-based registry. Mirrors Prawk's commands.nim model:
## modules register named procs at startup, the palette and hotkeys both
## dispatch via `runCommand(name, args)`. Registry hits return true; misses
## return false and let the caller fall through (cldispatch routes misses to
## the shell starting in milestone 9).
##
## Cross-module callbacks live here too — they keep this module the lone
## "outbound" import point for higher-level wiring (menubar palette,
## bookmarks/preview/theme stubs) without forcing circular imports.

import std/[os, strutils, osproc]
import rawk_bufferlib
import config, state, yank

type
  CmdProc* = proc (args: seq[string]) {.closure.}
  Command* = object
    name*:   string
    invoke*: CmdProc

var
  registry*: seq[Command]
    ## Module-public so cldispatch can iterate; not mutated by anyone else.

  # Set by menubar.nim at startup. Lets non-UI modules surface text into the
  # palette (e.g. "tab.close" sees a dirty buffer → injects `tab.close.force
  # <idx>` for the user to confirm).
  openPaletteWithCb*: proc(text: string) {.closure.}

  # Set by bookmarks/preview/theme modules when they create their widget.
  # Stays nil until that milestone ships; commands.nim null-checks before
  # invoking so the registry is always safe to call.
  bookmarkAddCb*:    proc(path: string) {.closure.}
  bookmarkDelCb*:    proc(path: string) {.closure.}
  previewToggleCb*:  proc() {.closure.}
  themeLoadCb*:      proc(name: string): bool {.closure.}
  openPathCb*:       proc(path: string) {.closure.}
  focusFilesCb*:     proc() {.closure.}
  focusBookmarksCb*: proc() {.closure.}

# ---------- registry ----------

proc registerCommand*(name: string, p: CmdProc) =
  for i in 0 ..< registry.len:
    if registry[i].name == name:
      registry[i].invoke = p
      return
  registry.add(Command(name: name, invoke: p))

proc runCommand*(name: string, args: seq[string] = @[]): bool =
  for c in registry:
    if c.name == name:
      c.invoke(args)
      return true
  return false

# ---------- built-in command implementations ----------

proc cmdExit(args: seq[string])    = quit(0)
proc cmdRefresh(args: seq[string]) = state.refreshActive()

proc cmdCd(args: seq[string]) =
  if args.len < 1: return
  state.cdActive(args[0])

proc cmdTabNew(args: seq[string]) =
  let t = state.activeTab()
  let cwd =
    if args.len >= 1: args[0]
    elif t != nil: t.cwd
    else: getHomeDir()
  state.setActive(state.newTab(cwd))

proc cmdTabClose(args: seq[string]) =
  var idx = state.activeIdx
  if args.len >= 1:
    try: idx = parseInt(args[0]) - 1
    except ValueError: return
  state.closeTab(idx)

proc cmdTabNext(args: seq[string]) = state.nextTab()
proc cmdTabPrev(args: seq[string]) = state.prevTab()

proc cmdHiddenToggle(args: seq[string]) =
  config.showHidden = not config.showHidden
  config.setConfigKey("hidden", if config.showHidden: "on" else: "off")
  state.refreshActive()

proc cmdHiddenSet(args: seq[string]) =
  if args.len < 1: return
  let on =
    case args[0].toLowerAscii
    of "on", "true", "yes", "1": true
    of "off", "false", "no", "0": false
    else: return
  config.showHidden = on
  config.setConfigKey("hidden", if on: "on" else: "off")
  state.refreshActive()

proc cmdPreviewToggle(args: seq[string]) =
  config.previewOn = not config.previewOn
  config.setConfigKey("preview", if config.previewOn: "on" else: "off")
  if previewToggleCb != nil: previewToggleCb()
  state.notify()

proc cmdSort(args: seq[string]) =
  if args.len < 1: return
  let m =
    case args[0].toLowerAscii
    of "dirs-first", "dirs": smDirsFirst
    of "name":               smName
    of "mtime", "modified":  smMTime
    else: return
  config.sortMode = m
  let label = case m
              of smDirsFirst: "dirs-first"
              of smName:      "name"
              of smMTime:     "mtime"
  config.setConfigKey("sort", label)
  state.refreshActive()

proc cmdBookmarkAdd(args: seq[string]) =
  let t = state.activeTab()
  let path =
    if args.len >= 1: absolutePath(args[0])
    elif t != nil:    t.cwd
    else:             ""
  if path.len == 0 or not dirExists(path): return
  if bookmarkAddCb != nil: bookmarkAddCb(path)

proc cmdBookmarkDel(args: seq[string]) =
  if args.len < 1 or bookmarkDelCb == nil: return
  bookmarkDelCb(args[0])

proc cmdOpen(args: seq[string]) =
  ## :open [path] — directory → `cd` into it; file → external handler
  ## (openPathCb, wired by opener.nim in milestone 7). With no path arg,
  ## operates on the current selection.
  let t = state.activeTab()
  if t == nil: return
  let path =
    if args.len >= 1: (if isAbsolute(args[0]): args[0] else: t.cwd / args[0])
    elif t.entries.len > 0: t.cwd / t.entries[t.selectedIdx].name
    else: ""
  if path.len == 0: return
  if dirExists(path):
    state.cdActive(path)
  elif openPathCb != nil:
    openPathCb(path)

proc cmdTheme(args: seq[string]) =
  if args.len < 1 or themeLoadCb == nil: return
  if themeLoadCb(args[0]):
    config.setConfigKey("theme", args[0])

proc cmdClip(args: seq[string]) =
  ## Cross-platform clipboard write. Backend is compile-time selected in
  ## rawk-bufferlib's clipboard module — xclip for the X11 build,
  ## wl-copy for `-d:wayland`. Same binary works for whichever flavor
  ## the user shipped.
  if args.len < 1: return
  clipboardSetBoth(args.join(" "))

proc cpInto(srcs: seq[string], dest: string) =
  ## cp -rn each source into dest. `-n` makes immediate-chord paste safe
  ## against accidental overwrites; users who want overwrite type
  ## `cp -rf …` in the palette manually.
  if srcs.len == 0: return
  var argv = @["-rn", "--"] & srcs & @[dest]
  try:
    let p = startProcess("/bin/cp", args = argv,
                         options = {poParentStreams})
    let code = waitForExit(p)
    p.close()
    if code != 0:
      stderr.writeLine("[Exrawk] paste exit " & $code)
  except OSError as e:
    stderr.writeLine("[Exrawk] paste spawn failed: " & e.msg)

proc cmdPaste(args: seq[string]) =
  ## Two-tier paste:
  ##   1. If the yank queue is non-empty, cp each queued path into the
  ##      active tab's cwd, then clear the queue (yazi semantics).
  ##   2. Otherwise fall back to a single-shot clipboard read — so a
  ##      `c-c` → navigate → `c-p` workflow still works without an
  ##      explicit yank.
  let t = state.activeTab()
  let dest = if t == nil: getCurrentDir() else: t.cwd
  let q = yank.paths()
  if q.len > 0:
    stderr.writeLine("[Exrawk] :paste — cp -rn (" & $q.len & " items) -> " & dest)
    cpInto(q, dest)
    yank.clear()
  else:
    let src = clipboardGet()
    if src.len == 0:
      stderr.writeLine("[Exrawk] :paste — yank queue empty + clipboard empty")
      return
    stderr.writeLine("[Exrawk] :paste — cp -rn " & src & " -> " & dest)
    cpInto(@[src], dest)
  state.refreshActive()

proc cmdYankClear(args: seq[string]) = yank.clear()

proc cmdFocusFiles(args: seq[string]) =
  if focusFilesCb != nil: focusFilesCb()

proc cmdFocusBookmarks(args: seq[string]) =
  if focusBookmarksCb != nil: focusBookmarksCb()

proc registerBuiltins*() =
  registerCommand("exit",            cmdExit)
  registerCommand("refresh",         cmdRefresh)
  registerCommand("cd",              cmdCd)
  registerCommand("tab.new",         cmdTabNew)
  registerCommand("tab.close",       cmdTabClose)
  registerCommand("tab.next",        cmdTabNext)
  registerCommand("tab.prev",        cmdTabPrev)
  registerCommand("hidden.toggle",   cmdHiddenToggle)
  registerCommand("hidden",          cmdHiddenSet)
  registerCommand("preview.toggle",  cmdPreviewToggle)
  registerCommand("sort",            cmdSort)
  registerCommand("bookmark.add",    cmdBookmarkAdd)
  registerCommand("bookmark.del",    cmdBookmarkDel)
  registerCommand("open",            cmdOpen)
  registerCommand("theme",           cmdTheme)
  registerCommand("clip",            cmdClip)
  registerCommand("paste",           cmdPaste)
  registerCommand("yank.clear",      cmdYankClear)
  registerCommand("focus.files",     cmdFocusFiles)
  registerCommand("focus.bookmarks", cmdFocusBookmarks)
