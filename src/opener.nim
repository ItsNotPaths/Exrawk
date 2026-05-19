## Opener — spawn an external handler for the selected file.
##
## Looks at the file's extension, picks the matching `open.<category>`
## config value, tokenizes it (so `"mpv --no-config"` works), and execs
## the handler via a double-fork: the grandchild is reparented to init,
## so it survives Exrawk exit and never becomes a zombie we'd have to
## reap. The parent only waits for the short-lived intermediate fork,
## which leaves SIGCHLD default — important so shell.nim's `waitForExit`
## still works.
##
## Categories are deliberately coarse — text / image / video / audio. Any
## extension that doesn't match an image/video/audio whitelist falls into
## "text" (covers source code, configs, plain dot-prefixed files, etc).

import std/[os, strutils]
import posix
import commands, config

type FileCategory* = enum fcText, fcImage, fcVideo, fcAudio

# ---------- ext tables ----------
#
# Kept small and explicit. Add as the user reports gaps — the rawk style
# is to grow these from concrete demand rather than ship "everything".

const
  imageExts = ["png", "jpg", "jpeg", "gif", "bmp", "webp", "svg",
               "tiff", "tif", "heic", "avif", "ico"]
  videoExts = ["mp4", "mkv", "avi", "mov", "wmv", "flv", "webm",
               "m4v", "mpg", "mpeg", "ogv"]
  audioExts = ["mp3", "flac", "wav", "ogg", "opus", "m4a", "aac", "wma"]

proc classify*(path: string): FileCategory =
  let (_, _, ext) = splitFile(path)
  let e = ext.toLowerAscii.strip(leading = true, trailing = false, chars = {'.'})
  if e.len == 0: return fcText
  if e in imageExts: return fcImage
  if e in videoExts: return fcVideo
  if e in audioExts: return fcAudio
  fcText

proc handlerForCategory*(c: FileCategory): string =
  case c
  of fcText:  config.openText
  of fcImage: config.openImage
  of fcVideo: config.openVideo
  of fcAudio: config.openAudio

proc handlerFor*(path: string): string =
  handlerForCategory(classify(path))

# ---------- spawn ----------

proc spawnDetached(handler, path: string) =
  ## Double-fork detach: parent waits only on the short-lived first child;
  ## the grandchild execs the handler and is reparented to init, so we
  ## never see it again and don't need waitpid on it later.
  if handler.len == 0:
    stderr.writeLine("[Exrawk] no handler configured for " & path)
    return
  let tokens = handler.splitWhitespace()
  if tokens.len == 0: return
  let argvSeq: seq[string] = @[tokens[0]] & (if tokens.len > 1: tokens[1 .. ^1] else: @[]) & @[path]

  let pid1 = fork()
  if pid1 < 0:
    stderr.writeLine("[Exrawk] fork failed for " & handler)
    return
  if pid1 == 0:
    # First child — break out of our session so the grandchild doesn't
    # die with our terminal, then fork the actual handler.
    discard setsid()
    let pid2 = fork()
    if pid2 < 0: quit(127)
    if pid2 != 0: quit(0)             # first child exits, frees the parent's wait
    # Grandchild — exec the handler. PATH lookup via execvp.
    var carr = allocCStringArray(argvSeq)
    discard execvp(tokens[0].cstring, carr)
    # execvp returned: handler not found or unrunnable. Emit a hint and die.
    stderr.writeLine("[Exrawk] exec failed for " & handler)
    deallocCStringArray(carr)
    quit(127)
  # Parent — reap the intermediate child immediately. SIGCHLD stays
  # default so shell.nim's waitForExit isn't disturbed.
  var status: cint
  discard waitpid(pid1, status, 0)

proc openPath*(path: string) =
  spawnDetached(handlerFor(path), path)

# ---------- init ----------

proc openerInstall*() =
  commands.openPathCb = openPath
