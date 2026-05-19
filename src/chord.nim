## Chord-leader — helix/yazi-style "press `c`, then a follower" shortcut
## table. The leader is the bare letter `c` while the filelist is focused;
## the follower runs an immediate command or injects a prefill into the
## palette for the user to review and Enter.
##
## Bindings split into two kinds:
##   ckImmediate — payload is dispatched at chord-press time. Safe ops
##                 like clipboard writes and toggles. No confirmation.
##   ckInject    — payload is loaded into the palette with the rawk-red
##                 injected border. The user reviews, optionally edits,
##                 and presses Enter to execute. Destructive ops (rm,
##                 mv, cp) live here, plus arg-template ones like
##                 `touch ` and `mkdir ` where the user supplies the name.
##
## All payloads go through the same cldispatch path Enter on the palette
## uses — registry hit for whitelisted commands, shell fallthrough for
## everything else. The chord is just a quick-pick over the CL surface.
##
## UI: while chord is active, the left pane swaps from the bookmarks list
## to a chord-help widget. Exit on Esc or any unbound key.

import std/os
import rawk_luigi, rawk_bufferlib
import state, commands, cldispatch

type
  ChordKind* = enum ckImmediate, ckInject

  ChordSpec = object
    key:   char
    label: string
    kind:  ChordKind

  ChordHelp* = object
    e*: Element

const chordTable: array[10, ChordSpec] = [
  ChordSpec(key: 'c', label: "copy path to clipboard",   kind: ckImmediate),
  ChordSpec(key: 'f', label: "copy folder to clipboard", kind: ckImmediate),
  ChordSpec(key: 'b', label: "bookmark this folder",     kind: ckImmediate),
  ChordSpec(key: 'r', label: "refresh listing",          kind: ckImmediate),
  ChordSpec(key: 'h', label: "toggle hidden files",      kind: ckImmediate),
  ChordSpec(key: 'd', label: "delete  (rm -rf …)",       kind: ckInject),
  ChordSpec(key: 'y', label: "copy    (cp src dst)",     kind: ckInject),
  ChordSpec(key: 'x', label: "move    (mv src dst)",     kind: ckInject),
  ChordSpec(key: 'n', label: "new file   (touch …)",     kind: ckInject),
  ChordSpec(key: 'N', label: "new dir    (mkdir …)",     kind: ckInject),
]

var
  active*:    bool
  prevFocus:  ptr Element
  theHelp*:   ptr ChordHelp
  theBookmarksEl*: ptr Element   # set by Exrawk.nim wiring; used to swap
                                 # visibility on chord enter/exit.

# ---------- payload synthesis ----------

proc selectionPath(): string =
  let t = state.activeTab()
  if t == nil or t.entries.len == 0: return ""
  t.cwd / t.entries[t.selectedIdx].name

proc cwdPath(): string =
  let t = state.activeTab()
  if t == nil: "" else: t.cwd

proc payloadFor(c: char): string =
  ## Returns the line that would be dispatched (immediate kinds) or
  ## prefilled into the palette (inject kinds). Empty string => no useful
  ## payload (e.g. nothing selected).
  let selQ = quoteForPalette(selectionPath())
  let cwdQ = quoteForPalette(cwdPath())
  case c
  of 'c': "wl-copy " & selQ
  of 'f': "wl-copy " & cwdQ
  of 'b': "bookmark.add"
  of 'r': "refresh"
  of 'h': "hidden.toggle"
  of 'd': "rm -rf " & selQ
  of 'y': "cp " & selQ & " "
  of 'x': "mv " & selQ & " "
  of 'n': "touch "
  of 'N': "mkdir "
  else:   ""

# ---------- enter / exit ----------

proc swap(showHelp: bool) =
  ## Toggle the ELEMENT_HIDE bit on both panes via direct flag mutation.
  ## elementRefresh on the parent re-runs layout so the visible one fills.
  if theHelp == nil or theBookmarksEl == nil: return
  let helpE = addr theHelp.e
  if showHelp:
    helpE.flags = helpE.flags and not ELEMENT_HIDE
    theBookmarksEl.flags = theBookmarksEl.flags or ELEMENT_HIDE
  else:
    helpE.flags = helpE.flags or ELEMENT_HIDE
    theBookmarksEl.flags = theBookmarksEl.flags and not ELEMENT_HIDE
  if helpE.parent != nil:
    elementRefresh(helpE.parent)

proc enter*() =
  if active: return
  active = true
  swap(showHelp = true)

proc exit*() =
  if not active: return
  active = false
  swap(showHelp = false)
  if theHelp != nil and theHelp.e.window != nil:
    elementRepaint(addr theHelp.e, nil)

proc handleFollower*(c: char): bool =
  ## Routes the follower keystroke. Returns true if we recognized it (the
  ## filelist should then suppress its normal handling); false otherwise
  ## (caller exits chord mode and lets the key fall through).
  for spec in chordTable:
    if spec.key != c: continue
    let payload = payloadFor(c)
    if payload.len == 0:
      exit(); return true
    case spec.kind
    of ckImmediate:
      exit()
      clDispatch(payload)
    of ckInject:
      exit()
      if openPaletteWithCb != nil:
        openPaletteWithCb(payload)
    return true
  return false

# ---------- chord-help element ----------

const helpHeader = "chord mode  (esc to leave)"

proc helpMessage(element: ptr Element, message: Message,
                 di: cint, dp: pointer): cint {.cdecl.} =
  if message == msgPaint:
    let painter = cast[ptr Painter](dp)
    drawBlock(painter, element.bounds, ui.theme.panel1)
    let (gW, gH) = glyphDims()
    let pad: cint = 6
    var y = element.bounds.t + pad
    let headRect = Rectangle(l: element.bounds.l + pad,
                             r: element.bounds.r - pad,
                             t: y, b: y + gH)
    drawString(painter, headRect, helpHeader.cstring, helpHeader.len,
               ui.theme.textDisabled, cint(ALIGN_LEFT), nil)
    y += gH + gH div 2
    for spec in chordTable:
      let kindMark: cstring =
        if spec.kind == ckImmediate: cstring"  c " else: cstring"  c "
      let row = Rectangle(l: element.bounds.l + pad,
                          r: element.bounds.r - pad,
                          t: y, b: y + gH)
      var line = "c "
      line.add(spec.key)
      line.add("   ")
      line.add(spec.label)
      let color =
        if spec.kind == ckImmediate: ui.theme.text
        else: ui.theme.textDisabled
      drawString(painter, row, line.cstring, line.len,
                 color, cint(ALIGN_LEFT), nil)
      y += gH
    return 1
  return 0

proc chordHelpCreate*(parent: ptr Element): ptr ChordHelp =
  let e = elementCreate(csize_t(sizeof(ChordHelp)), parent,
                        ELEMENT_V_FILL or ELEMENT_H_FILL or ELEMENT_HIDE,
                        helpMessage, "ExrawkChordHelp")
  let h = cast[ptr ChordHelp](e)
  theHelp = h
  return h
