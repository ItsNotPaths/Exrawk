# Void packaging

`template` is an xbps `-bin` template for the [unrawk] overlay. It installs a
prebuilt GitHub release tarball rather than building from source.

## Release artifacts

`.github/workflows/release.yml` publishes four `.tar.xz` bundles per release:

| Asset | Contents |
|-------|----------|
| `Exrawk-<ver>-wayland-full.tar.xz` | Wayland GUI + `exrawk-portal` + `portal/` glue |
| `Exrawk-<ver>-wayland-app.tar.xz` | Wayland GUI only |
| `Exrawk-<ver>-x11-full.tar.xz` | X11 GUI + `exrawk-portal` + `portal/` glue |
| `Exrawk-<ver>-x11-app.tar.xz` | X11 GUI only |

The template consumes `wayland-full` (the overlay is Wayland); switch the
`distfiles` line for an X11 overlay.

## Release → package loop

1. Cut a release: `./release.sh --public --version X.Y.Z` (triggers the CI
   workflow that builds both GUI flavors + the portal daemon and uploads the
   four bundles above).
2. Copy `template` into your overlay at `srcpkgs/Exrawk/template`.
3. Bump `version=X.Y.Z` and refresh the checksum:
   `cd void-packages && ./xbps-src update-check Exrawk` then
   `xgensum -f srcpkgs/Exrawk/template` (or paste the tarball's sha256).
4. Build + install: `./xbps-src pkg Exrawk && xi Exrawk`.

## What it installs

| Path | Contents |
|------|----------|
| `/opt/Exrawk/` | `Exrawk-wayland`, `exrawk-portal`, `themes/`, `yazi-icons.toml` |
| `/usr/bin/Exrawk`, `/usr/bin/Exrawk-wayland` | symlinks → the bundled wayland binary |
| `/usr/share/xdg-desktop-portal/portals/exrawk.portal` | backend declaration |
| `/usr/share/dbus-1/services/…desktop.exrawk.service` | D-Bus activation |
| `/etc/xdg-desktop-portal/portals.conf` | `FileChooser=exrawk` (conf_file) |

After install, the portal picks up the backend on next activation; force it now
with `pkill xdg-desktop-portal` (re-activates on demand) or just re-login.
