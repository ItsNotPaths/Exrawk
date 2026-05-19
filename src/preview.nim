## Preview — right-pane content for the currently-selected file.
##
## Embeds a rawk-bufferlib editor and treats it as read-only by convention:
## we never wire a save shortcut and we never give it tab focus by default.
## (The editor widget itself doesn't have a hard read-only flag; if the
## user clicks in and types, edits stay in-memory and discard on selection
## change.)
##
## On every state.notify, we look at the active tab's current entry and
## decide what to show:
##   - directory                           → synthetic "[directory]" stub
##   - binary (NUL in first 4 KB) / huge   → synthetic "[binary]" / "[too big]"
##   - text                                → editorOpenFile
## Old buffers (other tabs in the editor) are reaped after every load so
## the preview's internal tab list never grows.

import std/os
import rawk_luigi, rawk_bufferlib
import config, state, commands, opener

type
  Preview* = object
    ed*:       ptr Editor
    lastKey*:  string                 # (cwd | "@" | selectedName) — change detection
    enabled*:  bool

  PreviewTitle* = object
    e*: Element

var
  thePreview*:      Preview
  thePreviewTitle*: ptr PreviewTitle

const
  sniffBytes  = 4096
  sizeCap     = 1 shl 20              # 1 MiB

# ---------- classification ----------

type PreviewKind = enum pkText, pkDir, pkBinary, pkTooBig, pkUnreadable, pkEmpty

proc classify(path: string, size: int64): PreviewKind =
  if path.len == 0: return pkEmpty
  if dirExists(path): return pkDir
  if size > sizeCap: return pkTooBig
  var head = ""
  try:
    let f = open(path, fmRead)
    defer: f.close()
    var buf = newString(sniffBytes)
    let n = f.readBuffer(addr buf[0], buf.len)
    head = buf[0 ..< n]
  except IOError, OSError:
    return pkUnreadable
  for c in head:
    if c == '\0': return pkBinary
  pkText

# ---------- selection identity ----------

proc currentKey(): string =
  ## A stable string that changes iff the file we want to preview changed.
  ## Embeds the cwd so refreshes / cd's also trigger a reload.
  let t = state.activeTab()
  if t == nil or t.entries.len == 0:
    return "<none>"
  return t.cwd & "\x00" & t.entries[t.selectedIdx].name

proc currentSelectionPath(): string =
  let t = state.activeTab()
  if t == nil or t.entries.len == 0: return ""
  t.cwd / t.entries[t.selectedIdx].name

# ---------- suggestion text ----------

proc openTextHandlerSuggestion*(path: string): string =
  let h = opener.handlerFor(path)
  if h.len > 0: h
  else: "(set open.<category> in config)"

# ---------- editor housekeeping ----------

proc reapInactive(ed: ptr Editor) =
  ## Keep exactly one tab — preview is a single window onto whatever's
  ## selected. editorOpenFile/editorOpenSynthetic both append; we strip
  ## everything except the active one. Iterates by index because each
  ## close shifts indexes.
  while editorTabCount(ed) > 1:
    var dropIdx = -1
    let keep = editorActiveIdx(ed)
    for i in 0 ..< editorTabCount(ed):
      if i != keep: dropIdx = i; break
    if dropIdx < 0: break
    editorTabCloseForce(ed, dropIdx)

# ---------- reload ----------

proc reload(p: var Preview) =
  if p.ed == nil: return
  if not p.enabled:
    return
  let key = currentKey()
  if key == p.lastKey: return
  p.lastKey = key
  let path = currentSelectionPath()
  let sz: int64 =
    if path.len > 0 and fileExists(path):
      try: getFileSize(path)
      except OSError: 0
    else: 0
  let kind = classify(path, sz)
  case kind
  of pkEmpty:
    editorOpenSynthetic(p.ed, "preview://empty", "[no selection]")
  of pkDir:
    editorOpenSynthetic(p.ed, "preview://dir", "[directory]")
  of pkBinary:
    let handler = openTextHandlerSuggestion(path)
    editorOpenSynthetic(p.ed, "preview://bin",
                        "[binary file]\nopen with: " & handler)
  of pkTooBig:
    editorOpenSynthetic(p.ed, "preview://big",
                        "[file too large to preview]\nsize: " & $sz & " bytes")
  of pkUnreadable:
    editorOpenSynthetic(p.ed, "preview://err", "[unreadable]")
  of pkText:
    editorOpenFile(p.ed, path)
  reapInactive(p.ed)

# ---------- creation ----------

proc previewSetEnabled*(p: var Preview, on: bool) =
  p.enabled = on
  if on:
    p.lastKey = ""        # force one reload after a toggle-back-on
    reload(p)
  elif p.ed != nil:
    editorOpenSynthetic(p.ed, "preview://off", "[preview off]")
    reapInactive(p.ed)

proc previewTitleHeight*(): cint =
  ## Matches tabs.stripHeight() so the preview title bar sits at the same
  ## vertical level as the file list's tab strip on the left.
  let (_, gH) = glyphDims()
  gH + 4

proc previewTitleText(): string =
  ## Basename of the entry currently selected in the active tab. Empty when
  ## the tab is empty (e.g. unreadable cwd).
  let t = state.activeTab()
  if t == nil or t.entries.len == 0: return ""
  t.entries[t.selectedIdx].name

proc previewTitleMessage(element: ptr Element, message: Message,
                         di: cint, dp: pointer): cint {.cdecl.} =
  if message == msgGetHeight:
    return previewTitleHeight()
  elif message == msgPaint:
    let painter = cast[ptr Painter](dp)
    drawBlock(painter, element.bounds, ui.theme.panel2)
    let txt = previewTitleText()
    if txt.len > 0:
      drawString(painter, element.bounds, txt.cstring, txt.len,
                 ui.theme.text, cint(ALIGN_CENTER), nil)
    return 1
  return 0

proc previewTitleCreate*(parent: ptr Element): ptr PreviewTitle =
  let e = elementCreate(csize_t(sizeof(PreviewTitle)), parent, 0,
                        previewTitleMessage, "PreviewTitle")
  let t = cast[ptr PreviewTitle](e)
  thePreviewTitle = t
  state.subscribe(proc() =
    if thePreviewTitle != nil and thePreviewTitle.e.window != nil:
      elementRepaint(addr thePreviewTitle.e, nil))
  return t

proc previewCreate*(parent: ptr Element): ptr Editor =
  ## Returns the underlying editor so callers can position / size it.
  let host = EditorHost(
    indentString:    proc(): string         = "    ",
    lineNumbers:     proc(): LineNumberMode = lnmOff,
    cursorMode:      proc(): CursorMode     = cmNormal,
    cursorJumpLines: proc(): int            = 10,
    recordOpen:      proc(p: string)        = discard,
    onTabsChanged:   proc()                 = discard)
  let ed = editorCreate(parent, ELEMENT_V_FILL or ELEMENT_H_FILL, host)
  thePreview.ed = ed
  thePreview.enabled = config.previewOn
  thePreview.lastKey = ""

  # React to selection / cwd / refresh notifications. Cheap when the key
  # hasn't moved (early return after the equality check).
  state.subscribe(proc() = reload(thePreview))

  # Toggle command — milestone 4 left this as a stub callback. Wire it now.
  commands.previewToggleCb = proc() = previewSetEnabled(thePreview, config.previewOn)

  reload(thePreview)
  return ed
