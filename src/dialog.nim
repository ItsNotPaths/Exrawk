## Dialog mode — turns the running explorer into a system file picker.
##
## When launched with `--dialog open|multi|dir|save`, Exrawk behaves like
## zenity: the chosen absolute path(s) are printed to stdout, one per line,
## and the process exits 0 on confirm / 1 on cancel. The XDG portal backend
## (`exrawk_portal`) drives this surface — it spawns `Exrawk --dialog …` and
## reads the stdout.
##
## No UI imports here (only state + yank) so commands/menubar/filelist can
## all import this without an import cycle. The selection store is the same
## global yank queue used by Alt+Y / Alt+Shift+Y / Shift-arrows, so the
## picker reuses the existing green-bar multiselect verbatim.

import std/os
import state, yank

type DialogMode* = enum dmNone, dmOpenFile, dmOpenMulti, dmOpenDir, dmSave

var
  mode*:        DialogMode = dmNone
  suggestName*: string          ## save prefill (--name)

proc active*(): bool = mode != dmNone

proc submitLabel*(): string =
  ## Label for the far-right confirm button (menubar paints this).
  case mode
  of dmOpenFile, dmOpenMulti: "Open"
  of dmOpenDir:               "Select Folder"
  of dmSave:                  "Save"
  of dmNone:                  ""

proc emit(paths: seq[string]) =
  for p in paths: stdout.writeLine(p)
  stdout.flushFile(); quit(0)

proc cancel*() = quit(1)

proc select*() =
  ## `:select` — the typed equivalent of Alt+Y (replace-yank). In file mode a
  ## directory navigates instead of selecting; in dir mode a non-dir entry
  ## resolves to its containing folder.
  let t = state.activeTab()
  if t == nil or t.entries.len == 0: return
  let e = t.entries[t.selectedIdx]
  let p = t.cwd / e.name
  if mode in {dmOpenFile, dmOpenMulti} and e.kind == ekDir:
    state.cdActive(p)
  else:
    yank.replaceWith(if mode == dmOpenDir and e.kind != ekDir: t.cwd else: p)

proc confirm*(name = "") =
  ## `:confirm [name]` — finalize and emit. Save mode uses the typed name (or
  ## the --name prefill); open/dir modes emit the yank queue, falling back to
  ## the current selection / cwd when nothing was explicitly yanked.
  let t = state.activeTab()
  case mode
  of dmSave:
    let n = if name.len > 0: name else: suggestName
    if n.len > 0 and t != nil:
      emit(@[if isAbsolute(n): n else: t.cwd / n])
  of dmOpenMulti:
    let ps = yank.paths()
    if ps.len > 0: emit(ps)
  of dmOpenFile:
    var ps = yank.paths()
    if ps.len == 0 and t != nil and t.entries.len > 0:
      ps = @[t.cwd / t.entries[t.selectedIdx].name]
    if ps.len > 0: emit(@[ps[0]])
  of dmOpenDir:
    var ps = yank.paths()
    if ps.len == 0 and t != nil: ps = @[t.cwd]
    if ps.len > 0: emit(@[ps[0]])
  else: discard
