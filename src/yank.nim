## Yank queue — global (not per-tab) ordered set of file paths queued for
## paste. Populated by the c-y chord (plain / ctrl-additive) and by
## shift-held cursor moves in the file list; consumed by `:paste`.
##
## Persists across cwd changes — the whole point is "yank here, paste
## somewhere else". Cleared on explicit replace, on paste-completed, or
## via `:yank.clear`.

import std/[sets]

var
  queue:    seq[string]
  inQueue:  HashSet[string]
  onChange*: proc() {.closure.}

proc count*(): int = queue.len
proc paths*(): seq[string] = queue
proc contains*(p: string): bool = p in inQueue

proc fire() =
  if onChange != nil: onChange()

proc clear*() =
  if queue.len == 0 and inQueue.len == 0: return
  queue.setLen(0)
  inQueue.clear()
  fire()

proc add*(p: string) =
  if p.len == 0 or p in inQueue: return
  queue.add(p)
  inQueue.incl(p)
  fire()

proc replaceWith*(p: string) =
  queue.setLen(0)
  inQueue.clear()
  add(p)
