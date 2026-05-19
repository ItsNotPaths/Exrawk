switch("mm", "arc")
switch("panics", "on")

# Point rawk-luigi at our flat vendor/wayluigi so we don't end up with a
# nested vendor/rawk-luigi/vendor/wayluigi layout.
switch("define", "rawkLuigiVendor=" & thisDir() & "/vendor/wayluigi")

when defined(release):
  switch("opt", "size")
  switch("passC", "-Os -flto -ffunction-sections -fdata-sections -fno-strict-aliasing -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-stack-protector")
  switch("passL", "-flto -s -Wl,--gc-sections -Wl,--as-needed")

# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
