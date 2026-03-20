#!/usr/bin/env bash
# Build hermetic GStreamer SDK tarballs for Linux.
#
# Produces a base SDK tarball (headers + core link-time libraries) and
# separate plugin bundle tarballs that mirror GStreamer's own packaging:
#   - plugins-core:  core elements (fakesink, queue, filesrc, …)
#   - plugins-base:  base plugins (typefind, playback, volume, …)
#   - plugins-good:  well-supported plugins
#   - plugins-bad:   less-stable plugins (tsdemux, hlsdemux, …)
#
# Each plugin bundle includes the plugin .so files AND all transitive
# shared library dependencies (resolved via ldd), so downstream consumers
# only need to add the bundles they use.
#
# Designed to run natively on CI runners (Ubuntu 22.04).
#
# Usage:
#   ./build-tarball.sh [x86_64|aarch64]
#
# Outputs:
#   gstreamer-sdk-linux-<arch>.tar.gz
#   gstreamer-plugins-core-linux-<arch>.tar.gz
#   gstreamer-plugins-base-linux-<arch>.tar.gz
#   gstreamer-plugins-good-linux-<arch>.tar.gz
#   gstreamer-plugins-bad-linux-<arch>.tar.gz

set -euo pipefail

ARCH="${1:-$(uname -m)}"

# Normalise architecture name
case "$ARCH" in
x86_64 | amd64) ARCH="x86_64" ;;
aarch64 | arm64) ARCH="aarch64" ;;
*)
    echo "Usage: $0 [x86_64|aarch64]" >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}"

echo "==> Installing GStreamer development packages..."

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -q
# libunwind-dev is needed by libgstreamer1.0-dev but may be held on GitHub
# Actions runners; installing it explicitly resolves the dependency.
sudo apt-get install -y -q --no-install-recommends \
    libunwind-dev \
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    libglib2.0-dev \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad

# ── Helper: resolve transitive .so deps via ldd ──────────────────────────────

# Given a list of .so files, collect all transitive shared library dependencies
# (2 levels deep) and copy them into a target directory along with version
# symlinks.  Skips libc/libm/libpthread/ld-linux (always available).
bundle_with_deps() {
    local target_lib="$1"
    shift
    local plugin_files=("$@")

    mkdir -p "$target_lib"

    # Collect deps from all supplied .so files
    declare -A ALL_DEPS
    for so in "${plugin_files[@]}"; do
        [ -f "$so" ] || continue
        while IFS= read -r dep; do
            [ -n "$dep" ] && ALL_DEPS["$dep"]=1
        done < <(ldd "$so" 2>/dev/null | grep "=> /" | awk '{print $3}')
    done

    # Second level: deps of deps
    declare -A L2_DEPS
    for dep in "${!ALL_DEPS[@]}"; do
        while IFS= read -r dep2; do
            [ -n "$dep2" ] && L2_DEPS["$dep2"]=1
        done < <(ldd "$dep" 2>/dev/null | grep "=> /" | awk '{print $3}')
    done
    for dep in "${!L2_DEPS[@]}"; do
        ALL_DEPS["$dep"]=1
    done

    # Copy deps into target, skipping always-available system libs
    local copied=0
    for dep in "${!ALL_DEPS[@]}"; do
        local bn
        bn=$(basename "$dep")
        case "$bn" in
            libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*|ld-linux*|linux-vdso*) continue ;;
        esac
        if [ ! -e "$target_lib/$bn" ]; then
            local dir
            dir=$(dirname "$dep")
            local base="${bn%%.so*}"
            for f in "$dir/${base}".so*; do
                [ -e "$f" ] || continue
                cp -Pn "$f" "$target_lib/" 2>/dev/null || true
                copied=$((copied + 1))
            done
        fi
    done

    # Ensure unversioned .so symlinks exist
    pushd "$target_lib" > /dev/null
    for f in *.so.*; do
        [ -e "$f" ] || continue
        local base="${f%%.so.*}.so"
        [ -e "$base" ] || ln -sf "$f" "$base"
    done
    popd > /dev/null

    echo "    bundled $copied dependency files"
}

# ── 1. Base SDK tarball (headers + core link-time libs, NO plugins) ───────────

echo ""
echo "==> Building base SDK tarball..."

SDK_STAGING="$(mktemp -d)/gstreamer-sdk"
mkdir -p "$SDK_STAGING/include" "$SDK_STAGING/lib"

# Headers: glib / gobject / gio
cp -R /usr/include/glib-2.0 "$SDK_STAGING/include/"

# glib internal config header lives under lib/
GLIBCONFIG_DIR=$(dirname "$(dpkg -L libglib2.0-dev | grep glibconfig.h | head -1)")
mkdir -p "$SDK_STAGING/lib/glib-2.0/include"
cp "$GLIBCONFIG_DIR/glibconfig.h" "$SDK_STAGING/lib/glib-2.0/include/"

# Headers: gstreamer
cp -R /usr/include/gstreamer-1.0 "$SDK_STAGING/include/"

# Core link-time libraries (.so symlinks + .a files)
for lib in glib-2.0 gobject-2.0 gio-2.0 gstreamer-1.0 gstbase-1.0 gmodule-2.0 gthread-2.0; do
    for f in /usr/lib/*/lib${lib}.so* /usr/lib/*/lib${lib}.a; do
        [ -e "$f" ] || continue
        cp -P "$f" "$SDK_STAGING/lib/"
    done
done

# Ensure unversioned .so symlinks exist
pushd "$SDK_STAGING/lib" > /dev/null
for f in *.so.*; do
    [ -e "$f" ] || continue
    base="${f%%.so.*}.so"
    [ -e "$base" ] || ln -sf "$f" "$base"
done
popd > /dev/null

SDK_TARBALL="gstreamer-sdk-linux-${ARCH}.tar.gz"
tar czf "${OUTPUT_DIR}/${SDK_TARBALL}" -C "$SDK_STAGING" include lib
echo "  Created $SDK_TARBALL"

# ── 2. Plugin bundle tarballs ─────────────────────────────────────────────────

# Find the system plugin directory
PLUGIN_DIR=""
for d in /usr/lib/*/gstreamer-1.0; do
    [ -d "$d" ] && PLUGIN_DIR="$d" && break
done
if [ -z "$PLUGIN_DIR" ]; then
    echo "ERROR: Could not find GStreamer plugin directory" >&2
    exit 1
fi

# Map plugin bundles to their .so files.
# We use dpkg -L to discover which plugins belong to each package.
build_plugin_bundle() {
    local bundle_name="$1"
    local deb_package="$2"

    echo ""
    echo "==> Building $bundle_name plugin bundle..."

    local staging
    staging="$(mktemp -d)/gstreamer-$bundle_name"
    mkdir -p "$staging/lib/gstreamer-1.0" "$staging/lib"

    # Find all plugin .so files from this package
    local plugin_files=()
    while IFS= read -r f; do
        if [[ "$f" == */gstreamer-1.0/libgst*.so ]]; then
            if [ -f "$f" ]; then
                cp -P "$f" "$staging/lib/gstreamer-1.0/"
                plugin_files+=("$f")
            fi
        fi
    done < <(dpkg -L "$deb_package" 2>/dev/null)

    echo "  Found ${#plugin_files[@]} plugins in $deb_package"

    if [ ${#plugin_files[@]} -eq 0 ]; then
        echo "  WARNING: No plugins found for $deb_package, skipping"
        return
    fi

    # Bundle transitive .so dependencies
    bundle_with_deps "$staging/lib" "${plugin_files[@]}"

    # Verify key plugins can resolve their deps
    local failed=0
    for pf in "$staging/lib/gstreamer-1.0/"*.so; do
        [ -f "$pf" ] || continue
        local missing
        missing=$(LD_LIBRARY_PATH="$staging/lib" ldd "$pf" 2>&1 | grep "not found" || true)
        if [ -n "$missing" ]; then
            echo "  WARNING: $(basename "$pf") has unresolved deps:"
            echo "$missing" | head -5
            failed=$((failed + 1))
        fi
    done
    if [ $failed -eq 0 ]; then
        echo "  Verification: all plugins resolve their dependencies"
    else
        echo "  WARNING: $failed plugin(s) have unresolved dependencies"
    fi

    local tarball="gstreamer-${bundle_name}-linux-${ARCH}.tar.gz"
    tar czf "${OUTPUT_DIR}/${tarball}" -C "$staging" lib
    echo "  Created $tarball"
}

# Core elements: fakesink, filesrc, queue, identity, etc.
# These are shipped with the core GStreamer package.
echo ""
echo "==> Building plugins-core plugin bundle..."
CORE_STAGING="$(mktemp -d)/gstreamer-plugins-core"
mkdir -p "$CORE_STAGING/lib/gstreamer-1.0" "$CORE_STAGING/lib"

# Core elements plugin is always at a known path
CORE_PLUGIN="$PLUGIN_DIR/libgstcoreelements.so"
if [ -f "$CORE_PLUGIN" ]; then
    cp -P "$CORE_PLUGIN" "$CORE_STAGING/lib/gstreamer-1.0/"
    echo "  Found 1 plugin (libgstcoreelements.so)"
    bundle_with_deps "$CORE_STAGING/lib" "$CORE_PLUGIN"
else
    echo "  WARNING: libgstcoreelements.so not found"
fi

CORE_TARBALL="gstreamer-plugins-core-linux-${ARCH}.tar.gz"
tar czf "${OUTPUT_DIR}/${CORE_TARBALL}" -C "$CORE_STAGING" lib
echo "  Created $CORE_TARBALL"

# Base, Good, Bad plugin bundles
build_plugin_bundle "plugins-base" "gstreamer1.0-plugins-base"
build_plugin_bundle "plugins-good" "gstreamer1.0-plugins-good"
build_plugin_bundle "plugins-bad"  "gstreamer1.0-plugins-bad"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== All tarballs ==="
echo ""
for f in "${OUTPUT_DIR}"/gstreamer-*-linux-"${ARCH}".tar.gz; do
    [ -f "$f" ] || continue
    echo "$(basename "$f")  ($(du -h "$f" | cut -f1))"
done

echo ""
echo "=== SHA-256 checksums ==="
echo ""
sha256sum "${OUTPUT_DIR}"/gstreamer-*-linux-"${ARCH}".tar.gz
