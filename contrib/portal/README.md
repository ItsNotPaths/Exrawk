# XDG Desktop Portal integration

Files that make Exrawk the system file-chooser via `xdg-desktop-portal`. An
app's Open…/Save… reaches the `org.freedesktop.portal.Desktop` frontend, which
routes `FileChooser` to the `exrawk-portal` daemon; the daemon spawns
`Exrawk --dialog …`, reads the chosen path(s) from its stdout, and returns
`file://` URIs.

The Void package (`packaging/void/template`) installs these into system paths.
For a manual install, copy them as root:

| File | Destination | Purpose |
|------|-------------|---------|
| `exrawk.portal` | `/usr/share/xdg-desktop-portal/portals/` | declares the backend serves `FileChooser` |
| `org.freedesktop.impl.portal.desktop.exrawk.service` | `/usr/share/dbus-1/services/` | D-Bus activation → `/opt/Exrawk/exrawk-portal` |
| `portals.conf` | `/etc/xdg-desktop-portal/` | sets `FileChooser=exrawk` system-wide |

The `.service` `Exec=` and the daemon's picker lookup both assume the bundle at
`/opt/Exrawk/` (override the picker path with `$EXRAWK_BIN`). After installing,
restart the portal: `pkill xdg-desktop-portal` (it re-activates on demand).

Notes:
- We deliberately do **not** ship `/usr/share/xdg-desktop-portal/portals.conf`
  (owned by `xdg-desktop-portal`); the `/etc` copy overrides it without a file
  conflict.
- No `UseIn=` key: the explicit `FileChooser=exrawk` preference is authoritative
  regardless of `XDG_CURRENT_DESKTOP`, so the backend works on any session.
