version       = "0.1.0"
author        = "Paths"
description   = "Yazi-style file explorer applet for the rawk suite."
license       = "GPL-3.0-only"
srcDir        = "src"
bin           = @["Exrawk"]

requires "nim >= 2.0.0"
requires "rawk_luigi"
requires "rawk_bufferlib"
requires "parsetoml"
