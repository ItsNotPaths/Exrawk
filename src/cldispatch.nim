## clDispatch — parse one palette line, route to the registry, fall through
## to the shell on a miss.
##
## Tokenizer is quote-aware: single quotes are literal (no escapes), double
## quotes honor `\\` and `\"`. Necessary so the chord-leader and future
## drag-and-drop can inject paths with spaces (e.g. `:fs.yank "/home/foo
## bar/baz"`).
##
## Shell fallthrough lands in milestone 9 — for now misses log to stderr.

import std/strutils
import commands, shell

proc splitLineArgs*(s: string): seq[string] =
  ## Lightweight POSIX-ish tokenizer. Recognized constructs:
  ##   '...'   literal (no escapes, no nesting)
  ##   "..."   honors `\\` and `\"`
  ##   \c      unquoted backslash escapes the next char
  result = @[]
  var cur = ""
  var inSingle = false
  var inDouble = false
  var sawAny = false
  var i = 0
  while i < s.len:
    let c = s[i]
    if inSingle:
      if c == '\'': inSingle = false
      else: cur.add(c)
    elif inDouble:
      if c == '"': inDouble = false
      elif c == '\\' and i + 1 < s.len:
        cur.add(s[i + 1]); inc i
      else: cur.add(c)
    elif c == '\'': inSingle = true; sawAny = true
    elif c == '"':  inDouble = true; sawAny = true
    elif c == '\\' and i + 1 < s.len:
      cur.add(s[i + 1]); inc i; sawAny = true
    elif c == ' ' or c == '\t':
      if sawAny:
        result.add(cur); cur = ""; sawAny = false
    else:
      cur.add(c); sawAny = true
    inc i
  if sawAny: result.add(cur)

proc quoteForPalette*(s: string): string =
  ## Inverse of splitLineArgs (for the double-quote path). Used when chord
  ## bindings prefill the palette with a path argument: the user sees a
  ## still-editable line, and pressing Enter parses back to the original
  ## string.
  if s.len == 0: return "\"\""
  var needs = false
  for c in s:
    if c in {' ', '\t', '"', '\\', '\''}: needs = true; break
  if not needs: return s
  result = "\""
  for c in s:
    if c == '"' or c == '\\': result.add('\\')
    result.add(c)
  result.add('"')

proc splitOnAnd*(s: string): seq[string] =
  ## Splits `s` on `&&` outside single/double quotes. Each returned segment
  ## is whitespace-trimmed; empty segments are dropped. Lets the user chain
  ## registry and shell commands (`cd /tmp && tab.new`) instead of bash
  ## seeing `tab.new` as a missing binary.
  result = @[]
  var cur = ""
  var inSingle = false
  var inDouble = false
  var i = 0
  while i < s.len:
    let c = s[i]
    if inSingle:
      cur.add(c)
      if c == '\'': inSingle = false
      inc i
    elif inDouble:
      cur.add(c)
      if c == '"': inDouble = false
      elif c == '\\' and i + 1 < s.len:
        cur.add(s[i + 1]); inc i
      inc i
    elif c == '\'':
      cur.add(c); inSingle = true; inc i
    elif c == '"':
      cur.add(c); inDouble = true; inc i
    elif c == '&' and i + 1 < s.len and s[i + 1] == '&':
      let t = cur.strip()
      if t.len > 0: result.add(t)
      cur = ""
      i += 2
    else:
      cur.add(c); inc i
  let t = cur.strip()
  if t.len > 0: result.add(t)

proc dispatchOne(segment: string) =
  let trimmed = segment.strip()
  if trimmed.len == 0: return
  let parts = splitLineArgs(trimmed)
  if parts.len == 0: return
  let name = parts[0]
  let args = if parts.len > 1: parts[1 .. ^1] else: @[]
  if runCommand(name, args):
    return
  # Registry miss → shell. The split between intercept and shell is
  # whitelist-based by design: anything the UI doesn't own state for
  # belongs in bash, not in our registry.
  shell.spawnHere(trimmed)

proc clDispatch*(line: string) =
  for seg in splitOnAnd(line):
    dispatchOne(seg)
