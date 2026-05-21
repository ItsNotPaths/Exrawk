## exrawk-portal — XDG Desktop Portal FileChooser backend.
##
## A headless D-Bus service implementing org.freedesktop.impl.portal.FileChooser.
## The xdg-desktop-portal frontend (org.freedesktop.portal.Desktop) routes an
## app's Open…/Save… to this backend; we spawn the Exrawk picker
## (`Exrawk --dialog …`), read the chosen path(s) from its stdout, and return
## them as `file://` URIs.
##
## No wayluigi/bufferlib imports — this is a separate single-purpose binary.
## basu (libbasu.so.0) is bound via FFI with hand-declared sd_bus prototypes
## (no basu-devel needed). Dispatch is manual via sd_bus_add_filter, so we
## avoid the SD_BUS_VTABLE_* C macros entirely.
##
## Reference: xdg-desktop-portal-termfilechooser (same backend pattern).

import std/[os, osproc, strutils, streams]

# ---------- basu / sd-bus FFI ----------

type
  SdBus = pointer
  SdBusMessage = pointer
  SdBusSlot = pointer

const
  # D-Bus / sd-bus type chars (see sd-bus.h enum).
  tBOOLEAN     = 'b'
  tSTRING      = 's'
  tBYTE        = 'y'
  tUINT32      = 'u'
  tARRAY       = 'a'
  tVARIANT     = 'v'
  tDICT_ENTRY  = 'e'

{.push dynlib: "libbasu.so.0", importc.}
proc sd_bus_open_user(ret: ptr SdBus): cint
proc sd_bus_request_name(bus: SdBus, name: cstring, flags: uint64): cint
proc sd_bus_add_filter(bus: SdBus, slot: ptr SdBusSlot, cb: pointer,
                       userdata: pointer): cint
proc sd_bus_process(bus: SdBus, r: ptr SdBusMessage): cint
proc sd_bus_wait(bus: SdBus, timeout: uint64): cint
proc sd_bus_message_is_method_call(m: SdBusMessage, iface, member: cstring): cint
proc sd_bus_message_read_basic(m: SdBusMessage, typ: char, p: pointer): cint
proc sd_bus_message_enter_container(m: SdBusMessage, typ: char,
                                    contents: cstring): cint
proc sd_bus_message_exit_container(m: SdBusMessage): cint
proc sd_bus_message_peek_type(m: SdBusMessage, typ: ptr char,
                              contents: ptr cstring): cint
proc sd_bus_message_skip(m: SdBusMessage, types: cstring): cint
proc sd_bus_message_new_method_return(call: SdBusMessage,
                                      m: ptr SdBusMessage): cint
proc sd_bus_message_append(m: SdBusMessage, types: cstring): cint {.varargs.}
proc sd_bus_message_append_strv(m: SdBusMessage, l: ptr cstring): cint
proc sd_bus_message_open_container(m: SdBusMessage, typ: char,
                                   contents: cstring): cint
proc sd_bus_message_close_container(m: SdBusMessage): cint
proc sd_bus_send(bus: SdBus, m: SdBusMessage, cookie: ptr uint64): cint
proc sd_bus_message_unref(m: SdBusMessage): SdBusMessage
{.pop.}

const
  BusName   = "org.freedesktop.impl.portal.desktop.exrawk"
  IfaceFC   = "org.freedesktop.impl.portal.FileChooser"
  IfaceProp = "org.freedesktop.DBus.Properties"
  PortalVersion = 3'u32

var gBus: SdBus

# ---------- helpers ----------

proc log(msg: string) = stderr.writeLine("[exrawk-portal] " & msg)

proc pickerExe(): string =
  ## The picker binary. Honor $EXRAWK_BIN, else prefer the installed Wayland
  ## build when in a Wayland session, else fall back to whatever `Exrawk`
  ## resolves to on PATH.
  let envBin = getEnv("EXRAWK_BIN")
  if envBin.len > 0: return envBin
  if getEnv("WAYLAND_DISPLAY").len > 0:
    for c in ["/opt/Exrawk/Exrawk-wayland", "Exrawk-wayland"]:
      let f = if '/' in c: (if fileExists(c): c else: "") else: findExe(c)
      if f.len > 0: return f
  let onPath = findExe("Exrawk")
  if onPath.len > 0: return onPath
  return "/opt/Exrawk/Exrawk-wayland"

proc pathToFileUri(p: string): string =
  ## RFC-3986 percent-encode, preserving '/' so we emit file:///abs/path.
  const safe = {'A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~', '/'}
  result = "file://"
  for ch in p:
    if ch in safe: result.add(ch)
    else: result.add('%' & toHex(int(uint8(ch)), 2))

proc runPicker(args: seq[string]): tuple[resp: uint32, uris: seq[string]] =
  ## Spawn the picker, capture stdout. exit 0 → success (uris), 1 → cancelled,
  ## anything else → other/error. The picker writes only a few path lines then
  ## exits, so the pipe never fills — read after exit is safe.
  let exe = pickerExe()
  log("spawn: " & exe & " " & args.join(" "))
  try:
    let p = startProcess(exe, args = args, options = {poStdErrToStdOut})
    let code = waitForExit(p)
    let outData = p.outputStream.readAll()
    p.close()
    if code == 0:
      var uris: seq[string]
      for line in outData.splitLines():
        let s = line.strip()
        if s.len > 0 and s.startsWith("/"): uris.add(pathToFileUri(s))
      if uris.len > 0: return (0'u32, uris)
      return (1'u32, @[])          # exit 0 but nothing emitted = treat as cancel
    elif code == 1:
      return (1'u32, @[])
    else:
      log("picker exit " & $code)
      return (2'u32, @[])
  except OSError as e:
    log("spawn failed: " & e.msg)
    return (2'u32, @[])

# ---------- option parsing (a{sv}) ----------

type Options = object
  directory:     bool
  multiple:      bool
  currentFolder: string
  currentName:   string

proc readByteArray(m: SdBusMessage): string =
  ## Read an `ay` (NUL-terminated path) into a string, dropping the NUL.
  if sd_bus_message_enter_container(m, tARRAY, "y") < 0: return ""
  var b: uint8
  while sd_bus_message_read_basic(m, tBYTE, addr b) > 0:
    if b != 0: result.add(char(b))
  discard sd_bus_message_exit_container(m)

proc parseOptions(m: SdBusMessage): Options =
  ## Walk the trailing a{sv} options dict, picking out the keys we honor.
  if sd_bus_message_enter_container(m, tARRAY, "{sv}") < 0: return
  while sd_bus_message_enter_container(m, tDICT_ENTRY, "sv") > 0:
    var key: cstring
    if sd_bus_message_read_basic(m, tSTRING, addr key) < 0:
      discard sd_bus_message_exit_container(m); break
    let k = $key
    var vt: char
    var vc: cstring
    if sd_bus_message_peek_type(m, addr vt, addr vc) <= 0:
      discard sd_bus_message_exit_container(m); break
    let sig = $vc
    discard sd_bus_message_enter_container(m, tVARIANT, vc)
    case k
    of "directory":
      if sig == "b":
        var v: cint
        discard sd_bus_message_read_basic(m, tBOOLEAN, addr v)
        result.directory = v != 0
      else: discard sd_bus_message_skip(m, vc)
    of "multiple":
      if sig == "b":
        var v: cint
        discard sd_bus_message_read_basic(m, tBOOLEAN, addr v)
        result.multiple = v != 0
      else: discard sd_bus_message_skip(m, vc)
    of "current_folder":
      if sig == "ay": result.currentFolder = readByteArray(m)
      else: discard sd_bus_message_skip(m, vc)
    of "current_name":
      if sig == "s":
        var s: cstring
        discard sd_bus_message_read_basic(m, tSTRING, addr s)
        result.currentName = $s
      else: discard sd_bus_message_skip(m, vc)
    else:
      discard sd_bus_message_skip(m, vc)
    discard sd_bus_message_exit_container(m)   # variant
    discard sd_bus_message_exit_container(m)   # dict entry
  discard sd_bus_message_exit_container(m)     # array

# ---------- replies ----------

proc replyResult(call: SdBusMessage, resp: uint32, uris: seq[string]) =
  ## Build (u response, a{sv} results) with results = {"uris": <as>}.
  var reply: SdBusMessage
  if sd_bus_message_new_method_return(call, addr reply) < 0:
    log("new_method_return failed"); return
  discard sd_bus_message_append(reply, "u", resp)
  discard sd_bus_message_open_container(reply, tARRAY, "{sv}")
  if resp == 0 and uris.len > 0:
    discard sd_bus_message_open_container(reply, tDICT_ENTRY, "sv")
    discard sd_bus_message_append(reply, "s", "uris".cstring)
    discard sd_bus_message_open_container(reply, tVARIANT, "as")
    # NUL-terminated char** for append_strv.
    var arr: seq[cstring]
    for u in uris: arr.add(u.cstring)
    arr.add(nil)
    discard sd_bus_message_append_strv(reply, addr arr[0])
    discard sd_bus_message_close_container(reply)   # variant
    discard sd_bus_message_close_container(reply)   # dict entry
  discard sd_bus_message_close_container(reply)     # array
  discard sd_bus_send(gBus, reply, nil)
  discard sd_bus_message_unref(reply)

proc replyVersionVariant(call: SdBusMessage) =
  ## org.freedesktop.DBus.Properties.Get("…FileChooser","version") → v<u 3>.
  var reply: SdBusMessage
  if sd_bus_message_new_method_return(call, addr reply) < 0: return
  discard sd_bus_message_open_container(reply, tVARIANT, "u")
  discard sd_bus_message_append(reply, "u", PortalVersion)
  discard sd_bus_message_close_container(reply)
  discard sd_bus_send(gBus, reply, nil)
  discard sd_bus_message_unref(reply)

proc replyAllProps(call: SdBusMessage) =
  ## GetAll → a{sv} = {"version": <u 3>}.
  var reply: SdBusMessage
  if sd_bus_message_new_method_return(call, addr reply) < 0: return
  discard sd_bus_message_open_container(reply, tARRAY, "{sv}")
  discard sd_bus_message_open_container(reply, tDICT_ENTRY, "sv")
  discard sd_bus_message_append(reply, "s", "version".cstring)
  discard sd_bus_message_open_container(reply, tVARIANT, "u")
  discard sd_bus_message_append(reply, "u", PortalVersion)
  discard sd_bus_message_close_container(reply)
  discard sd_bus_message_close_container(reply)
  discard sd_bus_message_close_container(reply)
  discard sd_bus_send(gBus, reply, nil)
  discard sd_bus_message_unref(reply)

# ---------- method handlers ----------

proc readHeaderArgs(m: SdBusMessage): string =
  ## Both OpenFile/SaveFile start with (o handle, s app_id, s parent, s title).
  ## We only need the title; consume the rest. Returns the title.
  var handle, appId, parent, title: cstring
  discard sd_bus_message_read_basic(m, 'o', addr handle)
  discard sd_bus_message_read_basic(m, tSTRING, addr appId)
  discard sd_bus_message_read_basic(m, tSTRING, addr parent)
  discard sd_bus_message_read_basic(m, tSTRING, addr title)
  result = $title

proc handleOpenFile(m: SdBusMessage) =
  let title = readHeaderArgs(m)
  let opt = parseOptions(m)
  var args = @["--dialog",
               (if opt.directory: "dir" elif opt.multiple: "multi" else: "open")]
  if title.len > 0: args.add(@["--title", title])
  if opt.currentFolder.len > 0: args.add(opt.currentFolder)
  let (resp, uris) = runPicker(args)
  replyResult(m, resp, uris)

proc handleSaveFile(m: SdBusMessage) =
  let title = readHeaderArgs(m)
  let opt = parseOptions(m)
  var args = @["--dialog", "save"]
  if title.len > 0: args.add(@["--title", title])
  if opt.currentName.len > 0: args.add(@["--name", opt.currentName])
  if opt.currentFolder.len > 0: args.add(opt.currentFolder)
  let (resp, uris) = runPicker(args)
  replyResult(m, resp, uris)

proc handleProperties(m: SdBusMessage): bool =
  ## Returns true if we replied (Get/GetAll for the FileChooser version).
  if sd_bus_message_is_method_call(m, IfaceProp, "Get") > 0:
    var iface, prop: cstring
    discard sd_bus_message_read_basic(m, tSTRING, addr iface)
    discard sd_bus_message_read_basic(m, tSTRING, addr prop)
    if $prop == "version":
      replyVersionVariant(m); return true
  elif sd_bus_message_is_method_call(m, IfaceProp, "GetAll") > 0:
    replyAllProps(m); return true
  return false

proc onMessage(m: SdBusMessage, userdata: pointer,
               retError: pointer): cint {.cdecl.} =
  if sd_bus_message_is_method_call(m, IfaceFC, "OpenFile") > 0:
    handleOpenFile(m); return 1
  if sd_bus_message_is_method_call(m, IfaceFC, "SaveFile") > 0:
    handleSaveFile(m); return 1
  if handleProperties(m): return 1
  return 0   # not ours — let sd-bus handle (e.g. error reply)

# ---------- main ----------

proc main() =
  if sd_bus_open_user(addr gBus) < 0:
    log("cannot connect to user bus"); quit(1)
  var slot: SdBusSlot
  if sd_bus_add_filter(gBus, addr slot, cast[pointer](onMessage), nil) < 0:
    log("add_filter failed"); quit(1)
  if sd_bus_request_name(gBus, BusName, 0) < 0:
    log("cannot acquire name " & BusName & " (already running?)"); quit(1)
  log("ready as " & BusName & " (picker: " & pickerExe() & ")")
  while true:
    let r = sd_bus_process(gBus, nil)
    if r < 0:
      log("sd_bus_process error"); break
    if r > 0: continue            # handled an event; drain before waiting
    if sd_bus_wait(gBus, high(uint64)) < 0:
      log("sd_bus_wait error"); break

main()
