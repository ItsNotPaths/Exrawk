## Icons — vendored yazi icon mapping, rendered via FreeType glyph blits.
##
## Source: `vendor/yazi-icons.toml` (MIT, sxyazi/yazi), refreshed by
## download-deps.sh from yazi's `yazi-config/preset/theme-dark.toml`. The
## file's `[icon]` section has four arrays we read:
##   dirs  — exact directory-name matches (".config", "Downloads", …)
##   files — exact filename matches ("cmakelists.txt", ".gitignore", …)
##   exts  — extension matches (no leading dot)
##   conds — fallback predicates (`dir`, `link`, `!dir`, `exec`, …)
##
## Match precedence: dirs/files (exact) → exts → conds.
##
## Each rule contributes one codepoint + an RGB color. Codepoints are
## taken from the first rune of the `text` field, so a nerd font is
## required for the high PUA codepoints to render — we don't ship one.

import std/[os, strutils, tables, unicode]
import parsetoml
import rawk_luigi
import config

type
  IconRule* = object
    cp*:    int32
    color*: uint32

  CondKind* = enum ccDir, ccLink, ccExec, ccNotDir, ccOrphan, ccOther

  CondRule = object
    kind:  CondKind
    rule:  IconRule

var
  byDirName:  Table[string, IconRule]
  byFileName: Table[string, IconRule]
  byExt:      Table[string, IconRule]
  conds:      seq[CondRule]
  fallback:   IconRule = IconRule(cp: int32(0x2022), color: 0xcccccc'u32)
                                                  # • — bullet, neutral.
  textFont*:  ptr Font                            # active for all text
  iconFont*:  ptr Font                            # swapped in only during
                                                  # drawGlyphCp — text font
                                                  # has no nerd glyphs.

# ---------- low-level helpers ----------

proc parseHexColor(s: string): uint32 =
  ## Accepts `"#RRGGBB"`; returns 0x00RRGGBB (alpha ignored — luigi uses
  ## opaque-on-fill).
  let t = s.strip().strip(chars = {'#'})
  if t.len != 6: return 0
  try: result = uint32(parseHexInt(t))
  except ValueError: result = 0

proc firstCodepoint(s: string): int32 =
  if s.len == 0: return 0
  var r: Rune
  fastRuneAt(s, 0, r, doInc = false)
  int32(r)

proc parseRule(v: TomlValueRef): IconRule =
  let text =
    if v.hasKey("text"): v["text"].getStr() else: ""
  let fg =
    if v.hasKey("fg"): v["fg"].getStr() else: "#ffffff"
  IconRule(cp: firstCodepoint(text), color: parseHexColor(fg))

proc parseCondKind(expr: string): CondKind =
  ## yazi's `if = "..."` strings are small expressions; we recognize the
  ## standalone tokens and ignore `&`-compounded refinements (`dir & hovered`
  ## just lands as `dir`).
  let head = expr.split('&')[0].strip()
  case head
  of "dir":       ccDir
  of "link":      ccLink
  of "exec":      ccExec
  of "!dir":      ccNotDir
  of "orphan":    ccOrphan
  else:           ccOther

# ---------- load ----------

proc loadFromFile*(path: string) =
  byDirName.clear()
  byFileName.clear()
  byExt.clear()
  conds.setLen(0)
  if not fileExists(path): return
  var doc: TomlValueRef
  try:
    doc = parsetoml.parseFile(path)
  except:
    stderr.writeLine("[Exrawk] failed to parse " & path)
    return
  if not doc.hasKey("icon"): return
  let icon = doc["icon"]

  proc tableEntries(arr: TomlValueRef): seq[TomlValueRef] =
    if arr.kind != TomlValueKind.Array: return @[]
    for v in arr.getElems():
      if v.kind == TomlValueKind.Table: result.add(v)

  if icon.hasKey("dirs"):
    for v in tableEntries(icon["dirs"]):
      if not v.hasKey("name"): continue
      byDirName[v["name"].getStr().toLowerAscii] = parseRule(v)
  if icon.hasKey("files"):
    for v in tableEntries(icon["files"]):
      if not v.hasKey("name"): continue
      byFileName[v["name"].getStr().toLowerAscii] = parseRule(v)
  if icon.hasKey("exts"):
    for v in tableEntries(icon["exts"]):
      if not v.hasKey("name"): continue
      byExt[v["name"].getStr().toLowerAscii] = parseRule(v)
  if icon.hasKey("conds"):
    for v in tableEntries(icon["conds"]):
      if not v.hasKey("if"): continue
      conds.add(CondRule(kind: parseCondKind(v["if"].getStr()),
                         rule: parseRule(v)))

proc iconsPath*(): string =
  ## Lookup order, first hit wins:
  ##   1. user override under ~/.config/Exrawk/
  ##   2. flat next to the binary (release bundle layout)
  ##   3. vendor/ subdirectory (dev / source-tree layout)
  let candidates = [
    config.configDir() / "yazi-icons.toml",
    getAppDir() / "yazi-icons.toml",
    getAppDir() / "vendor" / "yazi-icons.toml",
  ]
  for p in candidates:
    if fileExists(p): return p
  ""

proc installIcons*() =
  ## Best-effort: load vendored TOML, then create text+icon FreeType faces.
  ## Text font stays active; the icon font gets swapped in only around
  ## drawGlyphCp calls (see withIconFont below). Either font can fail to
  ## load — fallback path is luigi's bitmap font, and a tofu glyph for
  ## icons, both of which keep the explorer usable.
  loadFromFile(iconsPath())
  if config.fontPath.len > 0 and fileExists(config.fontPath):
    textFont = fontCreate(config.fontPath.cstring, config.fontSize)
    if textFont != nil:
      discard fontActivate(textFont)
  if config.iconFontPath.len > 0 and fileExists(config.iconFontPath):
    iconFont = fontCreate(config.iconFontPath.cstring, config.fontSize)

proc nerdGlyphsAvailable*(): bool =
  iconFont != nil

template withIconFont*(body: untyped) =
  ## Temporarily activates the nerd-symbols font for a glyph draw, then
  ## restores whatever was active before. No-ops cleanly when iconFont is
  ## nil — caller can paint regardless and just get a tofu, which is fine.
  if iconFont != nil:
    let prev = fontActivate(iconFont)
    body
    discard fontActivate(prev)
  else:
    body

# ---------- lookup ----------

type
  EntryHint* = object
    ## What the caller knows about the entry — kept tiny so we don't drag
    ## state.nim into icons.nim.
    isDir*:    bool
    isLink*:   bool
    isExec*:   bool
    name*:     string

proc lookupRule*(h: EntryHint): IconRule =
  let lower = h.name.toLowerAscii
  if h.isDir:
    if byDirName.hasKey(lower): return byDirName[lower]
  else:
    if byFileName.hasKey(lower): return byFileName[lower]
  # extension match
  let dot = lower.rfind('.')
  if dot > 0 and dot < lower.len - 1:
    let ext = lower[dot + 1 .. ^1]
    if byExt.hasKey(ext): return byExt[ext]
  # cond fallbacks — yazi declares them in fallback-priority order.
  for c in conds:
    let hit =
      case c.kind
      of ccDir:    h.isDir
      of ccLink:   h.isLink
      of ccExec:   h.isExec and not h.isDir
      of ccNotDir: not h.isDir
      of ccOrphan: false
      of ccOther:  false
    if hit: return c.rule
  fallback
