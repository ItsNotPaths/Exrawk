#!/usr/bin/env bash
# Fetches third-party deps into vendor/. Run once before building.
#
# Layout (flat — no nested vendor/<pkg>/vendor/):
#   vendor/rawk-luigi/         Xrawk Nim FFI to wayluigi
#   vendor/rawk-bufferlib/     Xrawk text-buffer + editor widget (preview pane)
#   vendor/wayluigi/           luigi.h fork (rawk-luigi reads this via
#                              -d:rawkLuigiVendor — see config.nims)
#   vendor/wayluigi/freetype/  freetype headers for luigi.h's freetype path
#
# After fetching, registers rawk-luigi and rawk-bufferlib via `nimble develop`
# and runs `nimble setup` so plain `nim c` resolves them through nimble.paths.
# Idempotent — safe to re-run.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENDOR="$PROJECT_DIR/vendor"

fetch_repo() {
    local name="$1" url="$2"
    local dest="$VENDOR/$name"
    if [ -d "$dest/.git" ]; then
        # Existing clone (often from CI cache restore). Always refresh to
        # origin/HEAD so a stale cache can't bake an old dep into a release.
        echo "  refreshing $name..."
        git -C "$dest" fetch --depth=1 origin HEAD
        git -C "$dest" reset --hard FETCH_HEAD
    else
        echo "  cloning $name..."
        mkdir -p "$VENDOR"
        git clone --depth=1 "$url" "$dest"
    fi
}

echo "==> rawk-luigi (Xrawk Nim FFI to wayluigi)"
fetch_repo "rawk-luigi" "https://github.com/ItsNotPaths/rawk-luigi.git"

echo "==> rawk-bufferlib (Xrawk text-buffer + editor widget)"
fetch_repo "rawk-bufferlib" "https://github.com/ItsNotPaths/rawk-bufferlib.git"

echo "==> wayluigi (luigi.h fork — flat, not nested under rawk-luigi)"
fetch_repo "wayluigi" "https://github.com/ItsNotPaths/wayluigi.git"

echo "==> yazi icon mapping (vendored from sxyazi/yazi, MIT)"
YAZI_ICONS="$VENDOR/yazi-icons.toml"
# Pinned at yazi main; bump intentionally when their icon list materially
# changes. Re-fetched on every run so a stale cache can't lock us to old
# globs — yazi's theme-dark.toml carries the [icon] section verbatim.
curl -fsSL --retry 2 \
  "https://raw.githubusercontent.com/sxyazi/yazi/main/yazi-config/preset/theme-dark.toml" \
  -o "$YAZI_ICONS"
echo "  done."

echo "==> freetype headers (for luigi.h freetype path)"
FT_HEADERS="$VENDOR/wayluigi/freetype"
if [ -d "$FT_HEADERS" ] && [ -f "$FT_HEADERS/ft2build.h" ]; then
    echo "  already present: freetype headers"
else
    echo "  cloning freetype..."
    TMP=$(mktemp -d)
    git clone --depth=1 -q "https://gitlab.freedesktop.org/freetype/freetype.git" "$TMP/freetype"
    mkdir -p "$FT_HEADERS"
    cp -r "$TMP/freetype/include/." "$FT_HEADERS/"
    rm -rf "$TMP"
    echo "  done."
fi

echo "==> registering develop links (nimble.paths)"
# `nimble develop -a` is idempotent for same-path entries; if the user has
# their own sibling-repo dev setup, the duplicate warning is harmless.
# `nimble setup` then regenerates nimble.paths so plain `nim c` (used by
# release.sh / CI) finds the deps via config.nims.
( cd "$PROJECT_DIR" && \
    nimble develop -a:"$VENDOR/rawk-luigi"      -y || true; \
    nimble develop -a:"$VENDOR/rawk-bufferlib"  -y || true; \
    nimble setup -y )

echo ""
echo "All deps ready."
