## Alt-hints — the left-pane cheat-sheet shown while Alt is held.
##
## "rawk alt" model: Alt is a held modifier, not a toggled mode (it replaced
## the old `c`-leader chord). Pressing Alt swaps the left pane from the
## bookmarks list to this hint panel — a flat list of every `Alt+<key>`
## binding, grouped; releasing Alt swaps it back. The actual actions are
## window-level shortcuts registered in Exrawk.nim; this module owns only
## the reveal panel and the bookmarks↔hints swap.
##
## How the held-state is observed: luigi sets `window.alt` on the X11
## KeyPress/KeyRelease of Alt, and on each transition fires a mouse-move to
## the hovered element plus (on press) a key-typed (code = Alt) to the
## window element. reconcile() is called from those handlers — the window
## key-typed hook in Exrawk.nim catches the press, and each pane's
## msgMouseMove catches the release wherever the cursor rests — and flips
## the ELEMENT_HIDE bits only when the held-state actually changes.

import rawk_luigi, rawk_bufferlib
import std/strutils

type
  HintRow = object
    combo: string         # "" => section header (label holds the heading)
    label: string

  AltHints* = object
    e*: Element

const rows: seq[HintRow] = @[
  HintRow(combo: "",         label: "selection"),
  HintRow(combo: "alt y",    label: "yank (replace)"),
  HintRow(combo: "alt p",    label: "paste into cwd"),
  HintRow(combo: "alt d",    label: "delete  (rm -rf)"),
  HintRow(combo: "alt x",    label: "move    (mv)"),
  HintRow(combo: "alt n",    label: "new  (name/ = dir)"),
  HintRow(combo: "alt w",    label: "copy path"),
  HintRow(combo: "alt W",    label: "copy folder"),
  HintRow(combo: "alt b",    label: "bookmark cwd"),
  HintRow(combo: "alt r",    label: "refresh"),
  HintRow(combo: "alt h",    label: "toggle hidden"),
  HintRow(combo: "",         label: "tabs / menus"),
  HintRow(combo: "alt t",    label: "new tab"),
  HintRow(combo: "alt q",    label: "close tab"),
  HintRow(combo: "alt+S <>", label: "prev / next tab"),
  HintRow(combo: "alt c",    label: "command palette"),
  HintRow(combo: "alt f",    label: "file menu"),
  HintRow(combo: "alt e",    label: "edit menu"),
  HintRow(combo: "alt v",    label: "view menu"),
]

const headerText = "alt menu — release to dismiss"

# ---------- swap / reconcile ----------

var
  theHints*:       ptr AltHints
  theBookmarksEl*: ptr Element   # set by Exrawk.nim wiring
  shown:           bool

proc swap(showHints: bool) =
  ## Flip the ELEMENT_HIDE bit on both panes; elementRefresh re-runs layout
  ## on the parent so the visible one fills the column.
  if theHints == nil or theBookmarksEl == nil: return
  let hintsE = addr theHints.e
  if showHints:
    hintsE.flags = hintsE.flags and not ELEMENT_HIDE
    theBookmarksEl.flags = theBookmarksEl.flags or ELEMENT_HIDE
  else:
    hintsE.flags = hintsE.flags or ELEMENT_HIDE
    theBookmarksEl.flags = theBookmarksEl.flags and not ELEMENT_HIDE
  if hintsE.parent != nil:
    elementRefresh(hintsE.parent)

proc setHeld*(held: bool) =
  ## Force the reveal on/off. Idempotent — no-op (and no relayout) unless the
  ## shown-state actually changes. Used directly when we know Alt just went
  ## down but `window.alt` hasn't been updated yet (the Wayland modifiers
  ## event can lag the key event).
  if held == shown: return
  shown = held
  swap(held)
  # While shown, self-animate so the message loop polls window.alt every
  # frame (msgAnimate → reconcile) and catches the release reliably. This is
  # the load-bearing path on Wayland: the modifiers event that clears alt
  # only fires a mouse-move to the *hovered* element, which may be a pane we
  # don't hook — or none at all when the pointer is off-window — so the
  # mouse-move hooks alone miss releases. Polling sidesteps that routing.
  # The single ui.animating slot is free here: no other element animates
  # (the preview editor only blinks while focused, which it never is).
  if theHints != nil and theHints.e.window != nil:
    discard elementAnimate(addr theHints.e, stop = not held)

proc reconcile*(w: ptr Window) =
  ## Show the hint panel iff Alt is currently held. Cheap to call on every
  ## mouse-move / key-typed.
  setHeld(w != nil and w.alt)

# ---------- paint element ----------

proc hintsMessage(element: ptr Element, message: Message,
                  di: cint, dp: pointer): cint {.cdecl.} =
  if message == msgPaint:
    let painter = cast[ptr Painter](dp)
    drawBlock(painter, element.bounds, ui.theme.panel1)
    let (_, gH) = glyphDims()
    let pad: cint = 6
    var y = element.bounds.t + pad
    let headRect = Rectangle(l: element.bounds.l + pad,
                             r: element.bounds.r - pad,
                             t: y, b: y + gH)
    drawString(painter, headRect, headerText.cstring, headerText.len,
               ui.theme.textDisabled, cint(ALIGN_LEFT), nil)
    y += gH + gH div 2
    for r in rows:
      if r.combo.len == 0:
        # Section header — a little leading gap, dimmed.
        y += gH div 2
        let hr = Rectangle(l: element.bounds.l + pad,
                           r: element.bounds.r - pad,
                           t: y, b: y + gH)
        drawString(painter, hr, r.label.cstring, r.label.len,
                   ui.theme.textDisabled, cint(ALIGN_LEFT), nil)
        y += gH
        continue
      let line = r.combo.alignLeft(10) & r.label
      let row = Rectangle(l: element.bounds.l + pad,
                          r: element.bounds.r - pad,
                          t: y, b: y + gH)
      drawString(painter, row, line.cstring, line.len,
                 ui.theme.text, cint(ALIGN_LEFT), nil)
      y += gH
    return 1
  elif message == msgAnimate:
    # Active only while shown (see setHeld) — polls for the Alt release.
    reconcile(element.window)
    return 0
  elif message == msgMouseMove:
    # Alt-release fires a mouse-move to the hovered element; if that's us,
    # reconcile here so the panel dismisses itself.
    reconcile(element.window)
    return 0
  return 0

proc altHintsCreate*(parent: ptr Element): ptr AltHints =
  let e = elementCreate(csize_t(sizeof(AltHints)), parent,
                        ELEMENT_V_FILL or ELEMENT_H_FILL or ELEMENT_HIDE,
                        hintsMessage, "ExrawkAltHints")
  let h = cast[ptr AltHints](e)
  theHints = h
  return h
