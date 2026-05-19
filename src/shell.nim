## Shell fallthrough — runs anything the registry didn't claim.
##
## Two modes:
##   default        `bash -c '<line>'` with cwd = active tab's dir, sync
##                  via waitForExit. We see the exit code, the FS has
##                  finished mutating by the time we refresh. Good for
##                  rm / mv / cp / touch / mkdir — fast commands where
##                  knowing-it-finished matters.
##   `dt ` prefix   "detach" — same line, but double-forked so the
##                  grandchild is reparented to init. Parent unblocks
##                  immediately; UI stays responsive. Use for long-
##                  running or interactive launches: `dt feh foo.png`,
##                  `dt Prawk`, `dt mpv ./clip.mkv`. We auto-refresh
##                  right after spawning, which is best-effort — if the
##                  command mutates the FS, the user might need to
##                  `:refresh` (c-r) once it actually finishes.

import std/[os, osproc, strutils]
import posix
import state

proc spawnDetached(line, cwd: string) =
  let pid1 = fork()
  if pid1 < 0:
    stderr.writeLine("[Exrawk] dt fork failed")
    return
  if pid1 == 0:
    # Intermediate child — setsid + second fork. exitnow (= libc _exit)
    # avoids Nim teardown that would trample the parent's heap and
    # wayluigi display state (same hazard opener.nim hit).
    discard setsid()
    if cwd.len > 0:
      discard chdir(cwd.cstring)
    let pid2 = fork()
    if pid2 < 0: exitnow(127)
    if pid2 != 0: exitnow(0)
    let argvSeq = @["bash", "-c", line]
    var carr = allocCStringArray(argvSeq)
    discard execvp("bash".cstring, carr)
    stderr.writeLine("[Exrawk] dt exec bash failed")
    deallocCStringArray(carr)
    exitnow(127)
  # Reap the intermediate child. It exited right after its second fork
  # so this is ~instantaneous and SIGCHLD stays at default disposition
  # (waitForExit in the attached path keeps working).
  var status: cint
  discard waitpid(pid1, status, 0)

proc spawnAttached(line, cwd: string) =
  try:
    let p = startProcess("/bin/bash",
                         args = @["-c", line],
                         workingDir = cwd,
                         options = {poParentStreams})
    let code = waitForExit(p)
    p.close()
    if code != 0:
      stderr.writeLine("[Exrawk] exit " & $code)
  except OSError as e:
    stderr.writeLine("[Exrawk] shell spawn failed: " & e.msg)

proc spawnHere*(line: string) =
  let trimmed = line.strip()
  if trimmed.len == 0: return
  let t = state.activeTab()
  let cwd = if t != nil: t.cwd else: getCurrentDir()
  # `dt ` prefix → detached. Strip the prefix before passing to bash.
  if trimmed.len > 3 and trimmed[0 .. 2] == "dt ":
    let body = trimmed[3 .. ^1].strip()
    if body.len == 0: return
    stderr.writeLine("[Exrawk] dt $ " & body)
    spawnDetached(body, cwd)
  else:
    stderr.writeLine("[Exrawk] $ " & trimmed)
    spawnAttached(trimmed, cwd)
  # Refresh either way. Attached: FS work has completed. Detached: best-
  # effort; slow commands may need a manual :refresh once they finish.
  state.refreshActive()
