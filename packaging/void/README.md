# Void packaging

`template` is an xbps `-bin` template for the [unrawk] overlay. It installs the
prebuilt GitHub release tarball (`Exrawk-<version>-linux.tar.xz`, produced by
`.github/workflows/release.yml`) rather than building from source.

## Release → package loop

1. Cut a release: `./release.sh --public --version vX.Y.Z` (triggers the CI
   workflow, which builds both GUI flavors + the portal daemon and uploads
   `Exrawk-X.Y.Z-linux.tar.xz`).
2. Copy `template` into your overlay at `srcpkgs/Exrawk/template`.
3. Bump `version=X.Y.Z` and refresh the checksum:
   `cd void-packages && ./xbps-src update-check Exrawk` then
   `xgensum -f srcpkgs/Exrawk/template` (or paste the tarball's sha256).
4. Build + install: `./xbps-src pkg Exrawk && xi Exrawk`.

## What it installs

| Path | Contents |
|------|----------|
| `/opt/Exrawk/` | `Exrawk`, `Exrawk-wayland`, `exrawk-portal`, `themes/`, `yazi-icons.toml` |
| `/usr/bin/Exrawk`, `/usr/bin/Exrawk-wayland` | symlinks into the bundle |
| `/usr/share/xdg-desktop-portal/portals/exrawk.portal` | backend declaration |
| `/usr/share/dbus-1/services/…desktop.exrawk.service` | D-Bus activation |
| `/etc/xdg-desktop-portal/portals.conf` | `FileChooser=exrawk` (conf_file) |

After install, the portal picks up the backend on next activation; force it now
with `pkill xdg-desktop-portal` (re-activates on demand) or just re-login.
