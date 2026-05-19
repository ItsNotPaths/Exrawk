## State — tab list, active selection, change notifications.
##
## A tab is one directory session: cwd + the listed entries + a selection +
## scroll. Widgets (filelist, tabstrip, preview) subscribe via `subscribe`
## and the active-tab mutator calls `notify` so every observer repaints.
##
## We don't push refresh policy here — the filelist asks `refreshEntries` at
## the right moments. State stays a passive record.

import std/[os, algorithm, strutils, tables]
import config

type
  EntryKind* = enum ekDir, ekFile, ekSymlink, ekOther

  DirEntry* = object
    name*:     string
    kind*:     EntryKind
    isHidden*: bool
    size*:     int64

  Tab* = object
    cwd*:         string
    entries*:     seq[DirEntry]
    selectedIdx*: int
    scrollTop*:   int
    needsReload*: bool
    selMemory*:   Table[string, string]
      ## cwd → entry name to land on when next visiting that cwd. Filled on
      ## every cd: leaving X records the current selection at X; entering Y
      ## records "Y → leaf-of-old-cwd" if old was a descendant (so going
      ## back up via `<` lands on the dir we just came out of).

var
  tabs*:      seq[Tab]
  activeIdx*: int = -1
  changeSubs: seq[proc() {.closure.}]

# ---------- pub/sub ----------

proc subscribe*(p: proc() {.closure.}) =
  changeSubs.add(p)

proc notify*() =
  for cb in changeSubs:
    if cb != nil: cb()

# ---------- helpers ----------

proc activeTab*(): ptr Tab =
  if activeIdx < 0 or activeIdx >= tabs.len: nil
  else: addr tabs[activeIdx]

proc cmpDirEntry(a, b: DirEntry): int =
  case sortMode
  of smDirsFirst:
    if a.kind == ekDir and b.kind != ekDir: return -1
    if b.kind == ekDir and a.kind != ekDir: return 1
    cmpIgnoreCase(a.name, b.name)
  of smName:
    cmpIgnoreCase(a.name, b.name)
  of smMTime:
    # mtime not cached in DirEntry yet (out of scope for skeleton); fall back
    # to name to keep behavior predictable.
    cmpIgnoreCase(a.name, b.name)

proc kindOf(path: string): EntryKind =
  ## Symlink-aware classifier. Follows symlinks for the dir/file distinction
  ## (yazi-style) so a symlink to a directory still navigates into it; we
  ## remember it *was* a symlink via ekSymlink → ekDir in callers later.
  let info =
    try: getFileInfo(path, followSymlink = false)
    except OSError: return ekOther
  case info.kind
  of pcDir: ekDir
  of pcFile: ekFile
  of pcLinkToDir: ekDir          # collapses to dir for now
  of pcLinkToFile: ekSymlink

proc refreshEntries*(t: ptr Tab) =
  ## Read `t.cwd`, populate `t.entries`, sort, optionally filter hidden.
  ## Clamps the cursor to stay valid; never throws.
  if t == nil: return
  t.entries.setLen(0)
  if not dirExists(t.cwd):
    t.selectedIdx = 0
    t.scrollTop = 0
    t.needsReload = false
    return
  try:
    for kind, path in walkDir(t.cwd, relative = true):
      let nm = path
      let hidden = nm.len > 0 and nm[0] == '.'
      if hidden and not config.showHidden: continue
      var ek =
        case kind
        of pcDir: ekDir
        of pcFile: ekFile
        of pcLinkToDir: ekDir
        of pcLinkToFile: ekSymlink
      var sz: int64 = 0
      if ek == ekFile:
        try: sz = getFileSize(t.cwd / nm)
        except OSError: discard
      t.entries.add(DirEntry(name: nm, kind: ek, isHidden: hidden, size: sz))
  except OSError:
    discard
  sort(t.entries, cmpDirEntry)
  if t.selectedIdx >= t.entries.len: t.selectedIdx = max(0, t.entries.len - 1)
  if t.selectedIdx < 0: t.selectedIdx = 0
  if t.scrollTop > max(0, t.entries.len - 1): t.scrollTop = max(0, t.entries.len - 1)
  if t.scrollTop < 0: t.scrollTop = 0
  t.needsReload = false

# ---------- tab management ----------

proc newTab*(cwd: string): int =
  ## Returns the index of the new tab. Does *not* set it active.
  let abs = absolutePath(cwd).normalizedPath
  var t = Tab(cwd: abs, selectedIdx: 0, scrollTop: 0, needsReload: true)
  refreshEntries(addr t)
  tabs.add(t)
  result = tabs.len - 1

proc setActive*(idx: int) =
  if idx < 0 or idx >= tabs.len: return
  if idx == activeIdx: return
  activeIdx = idx
  notify()

proc closeTab*(idx: int) =
  if idx < 0 or idx >= tabs.len: return
  if tabs.len == 1:
    # Last tab — replace with a fresh $HOME tab rather than going empty.
    tabs[0] = Tab(cwd: getHomeDir(), selectedIdx: 0, scrollTop: 0,
                  needsReload: true)
    refreshEntries(addr tabs[0])
    activeIdx = 0
    notify()
    return
  tabs.delete(idx)
  if activeIdx >= tabs.len: activeIdx = tabs.len - 1
  notify()

proc nextTab*() =
  if tabs.len < 2: return
  setActive((activeIdx + 1) mod tabs.len)

proc prevTab*() =
  if tabs.len < 2: return
  setActive((activeIdx - 1 + tabs.len) mod tabs.len)

# ---------- navigation ----------

proc currentSelectionName(t: ptr Tab): string =
  if t == nil or t.entries.len == 0: return ""
  t.entries[t.selectedIdx].name

proc leafOfDescendant(parent, descendant: string): string =
  ## If `descendant` is strictly inside `parent`, return the first segment
  ## after `parent`. Used so `cd ..` from /a/b/c into /a/b lands on `c`.
  let p = parent.strip(trailing = true, chars = {'/'})
  if descendant.len <= p.len + 1: return ""
  if not descendant.startsWith(p & "/"): return ""
  let rest = descendant[p.len + 1 .. ^1]
  let slash = rest.find('/')
  if slash < 0: rest else: rest[0 ..< slash]

proc cdActive*(dest: string) =
  let t = activeTab()
  if t == nil: return
  let resolved =
    if isAbsolute(dest): dest
    else: t.cwd / dest
  let norm = absolutePath(resolved).normalizedPath
  if not dirExists(norm): return
  if norm == t.cwd: return

  # Remember where we were standing in the old cwd so re-entering it lands
  # on the same entry.
  let leaving = currentSelectionName(t)
  if leaving.len > 0:
    t.selMemory[t.cwd] = leaving

  # If we're stepping *out* (new cwd is an ancestor of old), the natural
  # selection in the parent is the dir we just left. Stamp it into the
  # memory so `< < <` walks back up the way we came.
  let leaf = leafOfDescendant(norm, t.cwd)
  if leaf.len > 0:
    t.selMemory[norm] = leaf

  t.cwd = norm
  t.selectedIdx = 0
  t.scrollTop = 0
  refreshEntries(t)

  # Restore from selMemory if we have a record of the target cwd.
  if t.selMemory.hasKey(norm):
    let want = t.selMemory[norm]
    for i, e in t.entries:
      if e.name == want:
        t.selectedIdx = i
        break

  notify()

proc refreshActive*() =
  let t = activeTab()
  if t == nil: return
  refreshEntries(t)
  notify()
