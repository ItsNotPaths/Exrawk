## Shell fallthrough — runs anything the registry didn't claim.
##
## `bash -c '<line>'` with cwd = active tab's directory, output streamed
## straight to our terminal (poParentStreams). Synchronous — the UI blocks
## while the command runs. That's fine for the file-manager surface
## (rm/mv/cp/touch/mkdir all return immediately); slow commands belong in
## a real terminal, not the explorer's CL.
##
## After exit, we refresh the active tab so newly-created/deleted/renamed
## entries appear. Exit code is logged but not surfaced in the UI yet.

import std/[os, osproc, strutils]
import state

proc spawnHere*(line: string) =
  let trimmed = line.strip()
  if trimmed.len == 0: return
  let t = state.activeTab()
  let cwd = if t != nil: t.cwd else: getCurrentDir()
  stderr.writeLine("[Exrawk] $ " & trimmed)
  try:
    let p = startProcess("/bin/bash",
                         args = @["-c", trimmed],
                         workingDir = cwd,
                         options = {poParentStreams})
    let code = waitForExit(p)
    p.close()
    if code != 0:
      stderr.writeLine("[Exrawk] exit " & $code)
  except OSError as e:
    stderr.writeLine("[Exrawk] shell spawn failed: " & e.msg)
  # File-system might have moved underneath us. Refresh unconditionally —
  # cheap, and avoids guessing which commands mutate.
  state.refreshActive()
