#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
RELEASE_DIR="$(cd "$PROJECT_DIR/.." && pwd)/${PROJECT_NAME}-release"

usage() {
    cat <<EOF
usage: $(basename "$0") [--local] [--public --version vX.Y.Z [--notes "text"]]

  --local               build locally into <project>-release/ next to the project
  --public              trigger release.yml workflow via gh CLI
  --version <tag>       required when --public is used
  --notes <text>        optional release notes / body
EOF
}

DO_LOCAL=0
DO_PUBLIC=0
VERSION=""
NOTES=""

while [ $# -gt 0 ]; do
    case "$1" in
        --local)   DO_LOCAL=1; shift ;;
        --public)  DO_PUBLIC=1; shift ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --notes)   NOTES="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown flag: $1" >&2; usage; exit 1 ;;
    esac
done

if [ $DO_LOCAL -eq 0 ] && [ $DO_PUBLIC -eq 0 ]; then
    usage
    exit 1
fi

if [ $DO_LOCAL -eq 1 ]; then
    echo "==> Local build: $PROJECT_NAME -> $RELEASE_DIR"
    rm -rf "$RELEASE_DIR"
    mkdir -p "$RELEASE_DIR"

    # Size-trimming flag set (same as Prawk's, see prawk/release.sh):
    #   -d:danger                — drops bounds/nil/overflow checks. Atomic
    #                              config + bookmarks writes mean a silent
    #                              crash can't corrupt user files.
    #   -d:strip / -d:lto        — strip debug, link-time-optimize.
    #   -d:noSignalHandler       — drop Nim's SIGSEGV/SIGINT handler.
    #   --threads:off            — we never createThread.
    #   --panics:on              — exceptions → panics; smaller .text.
    #   --stackTrace:off
    #     --lineTrace:off        — drop file:line strings.
    #   -fno-pie / -no-pie       — drops .rela.dyn relocations (~10 KB win).
    #   -ffunction-sections /
    #     -fdata-sections /
    #     --gc-sections          — discard unreachable funcs/data.
    #   -fno-asynchronous-unwind-tables /
    #     -fno-unwind-tables     — drop .eh_frame.
    #   -fno-stack-protector     — desktop tool, no canary.
    #   --build-id=none          — drops the build-id note.
    #   -z,norelro               — minor; relro section trim.
    build_flavor() {
        local out="$1"; shift
        ( cd "$PROJECT_DIR" && \
          nim c --opt:size -d:danger -d:strip -d:lto \
                -d:noSignalHandler \
                --threads:off --panics:on \
                --stackTrace:off --lineTrace:off \
                --passC:-fno-pie --passL:-no-pie \
                --passC:-ffunction-sections --passC:-fdata-sections \
                --passC:-fno-asynchronous-unwind-tables \
                --passC:-fno-unwind-tables \
                --passC:-fno-stack-protector \
                --passL:-Wl,--gc-sections \
                --passL:-Wl,--build-id=none \
                --passL:-Wl,-z,norelro \
                --nimcache:"$RELEASE_DIR/.nimcache-$(basename "$out")" \
                "$@" \
                --out:"$out" "src/${PROJECT_NAME}.nim" )
    }

    # The portal daemon is backend-agnostic (no rawk_luigi import) and binds
    # basu at runtime via {.dynlib.}, so it needs no X11/Wayland/basu headers
    # — just nim + std. One binary serves both GUI flavors.
    build_portal() {
        local out="$1"
        ( cd "$PROJECT_DIR" && \
          nim c --opt:size -d:danger -d:strip -d:lto \
                -d:noSignalHandler \
                --threads:off --panics:on \
                --stackTrace:off --lineTrace:off \
                --passC:-fno-pie --passL:-no-pie \
                --passC:-ffunction-sections --passC:-fdata-sections \
                --passC:-fno-asynchronous-unwind-tables \
                --passC:-fno-unwind-tables \
                --passC:-fno-stack-protector \
                --passL:-Wl,--gc-sections \
                --passL:-Wl,--build-id=none \
                --passL:-Wl,-z,norelro \
                --nimcache:"$RELEASE_DIR/.nimcache-$(basename "$out")" \
                --out:"$out" "src/exrawk_portal.nim" )
    }

    BIN_X11="$RELEASE_DIR/$PROJECT_NAME"
    BIN_WL="$RELEASE_DIR/${PROJECT_NAME}-wayland"
    BIN_PORTAL="$RELEASE_DIR/exrawk-portal"

    # Detect which backends the host can actually compile against; the
    # public CI image has both, but a wayland-only dev box won't have
    # libX11 dev headers. Skip with a notice rather than failing.
    HAS_X11=0
    HAS_WL=0
    [ -f /usr/include/X11/Xlib.h ] && HAS_X11=1
    [ -f /usr/include/wayland-client.h ] && HAS_WL=1
    pkg-config --exists x11 2>/dev/null && HAS_X11=1
    pkg-config --exists wayland-client 2>/dev/null && HAS_WL=1

    if [ $HAS_X11 -eq 1 ]; then
        echo "  -> X11 build"
        build_flavor "$BIN_X11"
    else
        echo "  -> X11 skipped (libX11 headers not found)"
    fi
    if [ $HAS_WL -eq 1 ]; then
        echo "  -> Wayland build"
        build_flavor "$BIN_WL" -d:wayland
    else
        echo "  -> Wayland skipped (wayland-client headers not found)"
    fi
    echo "  -> portal daemon build"
    build_portal "$BIN_PORTAL"

    # Bundle runtime assets next to the binary. iconsPath()/themeDirs()
    # both check getAppDir() so this layout works without a config tweak.
    [ -f "$PROJECT_DIR/README.md" ] && cp -f "$PROJECT_DIR/README.md" "$RELEASE_DIR/" || true
    [ -f "$PROJECT_DIR/LICENSE" ]   && cp -f "$PROJECT_DIR/LICENSE"   "$RELEASE_DIR/" || true
    [ -f "$PROJECT_DIR/LICENSE.txt" ] && cp -f "$PROJECT_DIR/LICENSE.txt" "$RELEASE_DIR/" || true
    if [ -d "$PROJECT_DIR/themes" ]; then
        rm -rf "$RELEASE_DIR/themes"
        cp -R "$PROJECT_DIR/themes" "$RELEASE_DIR/themes"
    fi
    if [ -f "$PROJECT_DIR/vendor/yazi-icons.toml" ]; then
        # Flatten — icons.nim looks for getAppDir()/yazi-icons.toml first
        # in release bundles, falls back to vendor/yazi-icons.toml in source
        # builds. Either way the file ends up findable.
        cp -f "$PROJECT_DIR/vendor/yazi-icons.toml" "$RELEASE_DIR/yazi-icons.toml"
    fi
    # XDG portal integration files (the .portal/.service/.conf the Void
    # package drops into system paths). Shipped verbatim so the packaging
    # template can install them straight out of the bundle.
    if [ -d "$PROJECT_DIR/contrib/portal" ]; then
        rm -rf "$RELEASE_DIR/portal"
        cp -R "$PROJECT_DIR/contrib/portal" "$RELEASE_DIR/portal"
    fi

    echo "==> Local done:"
    [ -f "$BIN_X11" ]    && echo "    $BIN_X11 ($(du -h "$BIN_X11" | cut -f1))"
    [ -f "$BIN_WL"  ]    && echo "    $BIN_WL  ($(du -h "$BIN_WL"  | cut -f1))"
    [ -f "$BIN_PORTAL" ] && echo "    $BIN_PORTAL ($(du -h "$BIN_PORTAL" | cut -f1))"
fi

if [ $DO_PUBLIC -eq 1 ]; then
    if [ -z "$VERSION" ]; then
        echo "error: --public requires --version <tag>" >&2
        exit 1
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo "error: gh CLI not found; install it and run 'gh auth login'" >&2
        exit 1
    fi
    REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || true)
    if [ -z "$REPO" ]; then
        echo "error: not in a github repo (or gh not authenticated)" >&2
        exit 1
    fi
    WORKFLOW="release.yml"
    echo "==> Triggering $WORKFLOW on $REPO ($VERSION)"
    OLD_ID=$(gh run list --workflow="$WORKFLOW" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
    gh workflow run "$WORKFLOW" \
        --field version="$VERSION" \
        --field notes="$NOTES"
    echo "==> Waiting for run to register..."
    NEW_ID=""
    for i in $(seq 1 30); do
        sleep 2
        CUR_ID=$(gh run list --workflow="$WORKFLOW" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
        if [ -n "$CUR_ID" ] && [ "$CUR_ID" != "$OLD_ID" ]; then
            NEW_ID="$CUR_ID"
            break
        fi
    done
    if [ -z "$NEW_ID" ]; then
        echo "error: failed to detect new workflow run" >&2
        exit 1
    fi
    echo "==> Watching run $NEW_ID"
    gh run watch "$NEW_ID" --exit-status
fi
