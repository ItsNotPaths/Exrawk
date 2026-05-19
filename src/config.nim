## Config — ~/.config/Exrawk/config (key: value, # comments).
##
## On first run (file absent), we *seed* the file with sensible defaults and
## a probed nerd-font path. On subsequent runs the file is the source of
## truth; unknown keys are kept (they round-trip via setConfigKey) but
## ignored.
##
## Defaults are module-level `var`s so callers can read them directly.

import std/[os, strutils, osproc]

type
  SortMode* = enum smDirsFirst, smName, smMTime

var
  # appearance
  fontPath*:     string  = ""         # empty → use luigi's bitmap font
  iconFontPath*: string  = ""         # empty → no nerd-icon rendering
  fontSize*:     uint32  = 14
  themePref*:    string  = "default"
  # behavior
  showHidden*: bool    = false
  previewOn*: bool     = true
  sortMode*:  SortMode = smDirsFirst
  # external openers (per category — extension classification lives in opener.nim)
  openText*:  string   = "edrawk"
  openImage*: string   = ""
  openVideo*: string   = ""
  openAudio*: string   = ""

# ---------- paths ----------

proc configDir*(): string = getConfigDir() / "Exrawk"
proc configPath*(): string = configDir() / "config"
proc bookmarksPath*(): string = configDir() / "bookmarks"
proc recentsPath*(): string = configDir() / "recents.dirs"

# ---------- font probe ----------

const nerdFontProbes = [
  "/usr/share/fonts/TTF/HackNerdFont-Regular.ttf",
  "/usr/share/fonts/TTF/Hack-Regular.ttf",
  "/usr/share/fonts/hack/HackNerdFont-Regular.ttf",
  "/usr/share/fonts/hack/Hack-Regular.ttf",
  "/usr/share/fonts/truetype/hack/Hack-Regular.ttf",
  "/usr/share/fonts/TTF/FiraCodeNerdFont-Regular.ttf",
  "/usr/share/fonts/FiraCode/FiraCodeNerdFont-Regular.ttf",
  "/usr/share/fonts/firacode/FiraCode-Regular.ttf",
  "/usr/share/fonts/truetype/firacode/FiraCode-Regular.ttf",
  "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
  "/usr/share/fonts/jetbrains-mono/JetBrainsMono-Regular.ttf",
  "/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Regular.ttf",
]

proc fcMatch(family: string): string =
  ## Wrap `fc-match --format=%{file}`. Returns "" if fontconfig isn't
  ## available or the family resolves to a different one (fontconfig
  ## happily substitutes on a miss — we reject substitutions by checking
  ## that the resolved path's basename mentions the requested family).
  try:
    let (output, code) = execCmdEx("fc-match --format=%{file} " & quoteShell(family))
    if code != 0: return ""
    let p = output.strip()
    if p.len == 0 or not fileExists(p): return ""
    let head = family.split(' ')[0].toLowerAscii
    if head notin p.toLowerAscii: return ""
    return p
  except CatchableError:
    return ""

proc probeIconFontPath*(): string =
  ## Best-effort discovery of a nerd-symbols font. Prefer the dedicated
  ## "Symbols Nerd Font Mono" (small file, exists purely to backfill the
  ## PUA glyphs yazi's table references); otherwise any matching .ttf
  ## under common font dirs.
  for q in ["Symbols Nerd Font Mono", "Symbols Nerd Font"]:
    let p = fcMatch(q)
    if p.len > 0: return p
  let roots = [
    "/usr/share/fonts",
    "/usr/local/share/fonts",
    getHomeDir() / ".local" / "share" / "fonts",
    getHomeDir() / ".fonts",
  ]
  for root in roots:
    if not dirExists(root): continue
    for path in walkDirRec(root, yieldFilter = {pcFile}):
      let lower = path.extractFilename.toLowerAscii
      if not lower.endsWith(".ttf") and not lower.endsWith(".otf"): continue
      if "symbols" in lower and "nerd" in lower: return path
  for root in roots:
    if not dirExists(root): continue
    for path in walkDirRec(root, yieldFilter = {pcFile}):
      let lower = path.extractFilename.toLowerAscii
      if not lower.endsWith(".ttf") and not lower.endsWith(".otf"): continue
      if "nerd" in lower and ("regular" in lower or "mono" in lower):
        return path
  ""

proc probeFontPath*(): string =
  ## Best-effort scan of common nerd-font install paths. Returns "" if
  ## nothing's found — Exrawk runs fine with the bitmap font; icons just
  ## won't render until the user points font_path at a real .ttf.
  # 1) common system paths.
  for p in nerdFontProbes:
    if fileExists(p): return p
  # 2) per-user fonts dirs. Walk for any *NerdFont*Regular*.ttf.
  let userDirs = [getHomeDir() / ".local" / "share" / "fonts",
                  getHomeDir() / ".fonts"]
  for dir in userDirs:
    if not dirExists(dir): continue
    for kind, path in walkDir(dir, relative = false):
      if kind != pcFile: continue
      let name = path.extractFilename
      if name.endsWith(".ttf") and "NerdFont" in name and "Regular" in name:
        return path
  ""

# ---------- parse ----------

proc parseBoolish(s: string, default: bool): bool =
  case s.toLowerAscii
  of "on", "true", "yes", "1": true
  of "off", "false", "no", "0": false
  else: default

proc parseSortMode(s: string, default: SortMode): SortMode =
  case s.toLowerAscii
  of "dirs-first", "dirsfirst", "dirs_first": smDirsFirst
  of "name": smName
  of "mtime", "modified": smMTime
  else: default

proc applyKey(key, val: string) =
  case key
  of "font_path":      fontPath = val
  of "icon_font_path": iconFontPath = val
  of "font_size":
    try:
      let n = parseInt(val)
      if n >= 6 and n <= 64: fontSize = uint32(n)
    except ValueError: discard
  of "theme":
    if val.len > 0: themePref = val
  of "hidden":     showHidden = parseBoolish(val, showHidden)
  of "preview":    previewOn  = parseBoolish(val, previewOn)
  of "sort":       sortMode   = parseSortMode(val, sortMode)
  of "open.text":  openText  = val
  of "open.image": openImage = val
  of "open.video": openVideo = val
  of "open.audio": openAudio = val
  else: discard

proc parseConfigFile(path: string) =
  for raw in lines(path):
    let line = raw.strip()
    if line.len == 0 or line.startsWith('#'): continue
    let colon = line.find(':')
    if colon <= 0: continue
    let key = line[0 ..< colon].strip()
    var rest = line[colon+1 .. ^1]
    let hash = rest.find('#')
    if hash >= 0: rest = rest[0 ..< hash]
    let val = rest.strip()
    applyKey(key, val)

# ---------- write ----------

proc seededTemplate(): string =
  ## The on-disk template we write on first run. Keep the layout stable so
  ## setConfigKey's line-rewrite stays predictable (whole-line replace by
  ## leading `<key>:`).
  result = "# Exrawk config\n"
  result.add "# Generated on first run; edit freely. Keys round-trip; the\n"
  result.add "# rawk commandline persists changes via setConfigKey.\n"
  result.add "\n"
  result.add "# Primary monospace .ttf (filenames, palette, menubar). Empty\n"
  result.add "# → luigi's bitmap font.\n"
  result.add "font_path:        " & fontPath & "\n"
  result.add "# Icon font (file-type glyphs only). Activated only during\n"
  result.add "# glyph rendering, then deactivated — won't affect text.\n"
  result.add "icon_font_path:   " & iconFontPath & "\n"
  result.add "font_size:        " & $fontSize & "\n"
  result.add "theme:        " & themePref & "\n"
  result.add "\n"
  result.add "# Show dotfiles in the file list? (on | off)\n"
  result.add "hidden:       " & (if showHidden: "on" else: "off") & "\n"
  result.add "# Right-pane preview on selection change.\n"
  result.add "preview:      " & (if previewOn: "on" else: "off") & "\n"
  result.add "# File-list sort: dirs-first | name | mtime\n"
  result.add "sort:         " & (case sortMode
                                 of smDirsFirst: "dirs-first"
                                 of smName: "name"
                                 of smMTime: "mtime") & "\n"
  result.add "\n"
  result.add "# External handlers per file category. Blank → no handler\n"
  result.add "# (binary files show a stub in the preview pane).\n"
  result.add "open.text:    " & openText & "\n"
  result.add "open.image:   " & openImage & "\n"
  result.add "open.video:   " & openVideo & "\n"
  result.add "open.audio:   " & openAudio & "\n"

proc atomicWrite(path, body: string) =
  ## tmp+rename so a crash mid-write doesn't truncate the config.
  let tmp = path & ".tmp"
  writeFile(tmp, body)
  moveFile(tmp, path)

proc seedFirstRun(path: string) =
  ## Probe a font, persist the seeded template, also seed the bookmarks
  ## file with $HOME so the left pane isn't empty on first launch.
  fontPath = probeFontPath()
  iconFontPath = probeIconFontPath()
  createDir(configDir())
  atomicWrite(path, seededTemplate())
  let bmPath = bookmarksPath()
  if not fileExists(bmPath):
    atomicWrite(bmPath, getHomeDir() & "\n")
  stderr.writeLine("[Exrawk] seeded " & path &
                   (if fontPath.len > 0: " (font: " & fontPath & ")"
                    else: " (font: <none found — set font_path to a nerd-font .ttf>)"))

proc loadConfig*() =
  let path = configPath()
  if not fileExists(path):
    seedFirstRun(path)
    return
  parseConfigFile(path)
  # Backfill the icon-font probe for users on a config from before
  # icon_font_path was a thing. In-memory only — we don't rewrite the
  # file behind the user's back; they'd see the value next time they
  # round-trip with setConfigKey.
  if iconFontPath.len == 0:
    iconFontPath = probeIconFontPath()

# ---------- persistence ----------

proc setConfigKey*(key, value: string) =
  ## Read the file, find/replace the matching `<key>:` line (preserving
  ## leading whitespace), append if absent, atomic-write back. Mirrors
  ## Prawk config.nim's behavior.
  let path = configPath()
  if not fileExists(path):
    # No file yet — seed first so we have something to amend.
    seedFirstRun(path)
  var lines: seq[string] = @[]
  for l in lines(path): lines.add(l)
  var found = false
  let prefix = key & ":"
  for i in 0 ..< lines.len:
    let stripped = lines[i].strip(leading = true, trailing = false)
    if stripped.startsWith(prefix):
      # Preserve original indentation; rewrite from `key:` onward.
      let indent = lines[i][0 ..< lines[i].len - stripped.len]
      lines[i] = indent & key & ":    " & value
      found = true
      break
  if not found:
    if lines.len > 0 and lines[^1].len > 0: lines.add("")
    lines.add(key & ":    " & value)
  atomicWrite(path, lines.join("\n") & "\n")
  applyKey(key, value)
