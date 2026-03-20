#!/usr/bin/env bash
# Build hermetic GStreamer SDK tarballs for Linux.
#
# Builds GStreamer 1.20.7 from source inside a glibc 2.28 environment
# (Debian buster) to ensure compatibility with LLVM toolchains targeting
# glibc 2.28.
#
# Produces:
#   gstreamer-sdk-linux-<arch>.tar.gz           - Headers + core link-time libraries
#   gstreamer-plugins-core-linux-<arch>.tar.gz   - Core elements (fakesink, queue, …)
#   gstreamer-plugins-base-linux-<arch>.tar.gz   - Base plugins (typefind, playback, …)
#   gstreamer-plugins-good-linux-<arch>.tar.gz   - Good plugins (matroska, isomp4, …)
#   gstreamer-plugins-bad-linux-<arch>.tar.gz    - Bad plugins (tsdemux, hlsdemux, …)
#
# Each plugin bundle includes the plugin .so files AND all transitive
# shared library dependencies (resolved via ldd).
#
# Designed to run inside a debian:buster Docker container.
#
# Usage:
#   ./build-tarball.sh [x86_64|aarch64]

set -euo pipefail

ARCH="${1:-$(uname -m)}"
GST_VERSION="1.20.7"

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

# ── 0. Configure apt (Debian buster is EOL) ─────────────────────────────────

echo "==> Configuring apt sources for Debian buster (archive)..."
cat > /etc/apt/sources.list <<'SOURCES'
deb http://archive.debian.org/debian/ buster main
deb http://archive.debian.org/debian-security/ buster/updates main
SOURCES

# Disable validity checks for archived repos
echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid

# ── 1. Install build dependencies ───────────────────────────────────────────

echo "==> Installing build dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends \
    build-essential \
    pkg-config \
    flex \
    bison \
    python3 \
    python3-pip \
    python3-setuptools \
    python3-wheel \
    libglib2.0-dev \
    ninja-build \
    wget \
    ca-certificates

# Buster ships Meson 0.49; GStreamer 1.20 needs >= 0.59.
# Meson < 1.3 is required for Python 3.7 compatibility.
pip3 install 'meson>=0.59,<1.3'

# ── 2. Download and build GStreamer from source ──────────────────────────────

echo ""
echo "==> Downloading GStreamer ${GST_VERSION}..."
wget -q "https://gitlab.freedesktop.org/gstreamer/gstreamer/-/archive/${GST_VERSION}/gstreamer-${GST_VERSION}.tar.gz" \
    -O /tmp/gstreamer-src.tar.gz

cd /tmp
tar xf gstreamer-src.tar.gz

echo ""
echo "==> Building GStreamer ${GST_VERSION} (this may take a few minutes)..."
cd "/tmp/gstreamer-${GST_VERSION}"

meson setup build \
    --prefix=/opt/gstreamer \
    --libdir=lib \
    --buildtype=release \
    -Dbase=enabled \
    -Dgood=enabled \
    -Dbad=enabled \
    -Dugly=disabled \
    -Dlibav=disabled \
    -Ddevtools=disabled \
    -Dges=disabled \
    -Drtsp_server=disabled \
    -Dvaapi=disabled \
    -Dsharp=disabled \
    -Drs=disabled \
    -Dpython=disabled \
    -Dgst-examples=disabled \
    -Dtests=disabled \
    -Dexamples=disabled \
    -Dintrospection=disabled \
    -Ddoc=disabled \
    -Dgtk_doc=disabled \
    -Dorc=disabled

ninja -C build -j "$(nproc)"

DESTDIR=/tmp/gst-destdir ninja -C build install

GST_ROOT="/tmp/gst-destdir/opt/gstreamer"
GST_LIB="$GST_ROOT/lib"
GST_PLUGIN_DIR="$GST_LIB/gstreamer-1.0"
BUILD_DIR="/tmp/gstreamer-${GST_VERSION}/build"

echo ""
echo "==> GStreamer installed to $GST_ROOT"
echo "    Libraries: $(find "$GST_LIB" -maxdepth 1 -name 'libgst*.so*' | wc -l) files"
echo "    Plugins:   $(find "$GST_PLUGIN_DIR" -name 'libgst*.so' 2>/dev/null | wc -l) files"

# ── Helper: resolve transitive .so deps via ldd ─────────────────────────────

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
        done < <(LD_LIBRARY_PATH="$GST_LIB" ldd "$so" 2>/dev/null | grep "=> /" | awk '{print $3}')
    done

    # Second level: deps of deps
    declare -A L2_DEPS
    for dep in "${!ALL_DEPS[@]}"; do
        while IFS= read -r dep2; do
            [ -n "$dep2" ] && L2_DEPS["$dep2"]=1
        done < <(LD_LIBRARY_PATH="$GST_LIB" ldd "$dep" 2>/dev/null | grep "=> /" | awk '{print $3}')
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

# ── Helper: categorize plugins by build subproject ───────────────────────────

# After building the monorepo, find which plugins belong to each subproject
# by looking at the build directory structure.
plugins_for_subproject() {
    local subproject="$1"
    local sp_build="$BUILD_DIR/subprojects/$subproject"

    if [ ! -d "$sp_build" ]; then
        return
    fi

    # Find plugin .so files built by this subproject
    while IFS= read -r f; do
        local bn
        bn=$(basename "$f")
        # Only include if it's also in the install directory
        if [ -f "$GST_PLUGIN_DIR/$bn" ]; then
            echo "$GST_PLUGIN_DIR/$bn"
        fi
    done < <(find "$sp_build" -name 'libgst*.so' 2>/dev/null)
}

# ── 3. SDK tarball (headers + core link-time libs) ───────────────────────────

echo ""
echo "==> Building base SDK tarball..."

SDK_STAGING="$(mktemp -d)/gstreamer-sdk"
mkdir -p "$SDK_STAGING/include" "$SDK_STAGING/lib"

# GStreamer headers (from our build)
cp -R "$GST_ROOT/include/gstreamer-1.0" "$SDK_STAGING/include/"

# GLib headers (from system / Debian buster)
cp -R /usr/include/glib-2.0 "$SDK_STAGING/include/"

# glibconfig.h (lives under lib/ in a multiarch subdir)
GLIBCONFIG_DIR=$(find /usr/lib -name glibconfig.h -printf '%h\n' | head -1)
mkdir -p "$SDK_STAGING/lib/glib-2.0/include"
cp "$GLIBCONFIG_DIR/glibconfig.h" "$SDK_STAGING/lib/glib-2.0/include/"

# Core link-time libraries from our GStreamer build
for lib in gstreamer-1.0 gstbase-1.0; do
    for f in "$GST_LIB"/lib${lib}.so* "$GST_LIB"/lib${lib}.a; do
        [ -e "$f" ] || continue
        cp -P "$f" "$SDK_STAGING/lib/"
    done
done

# GLib libraries from system (compiled against glibc 2.28)
for lib in glib-2.0 gobject-2.0 gio-2.0 gmodule-2.0 gthread-2.0; do
    for f in /usr/lib/*/lib${lib}.so* /usr/lib/*/lib${lib}.a; do
        [ -e "$f" ] || continue
        cp -P "$f" "$SDK_STAGING/lib/"
    done
done

# Also copy libffi (dependency of GLib/gobject)
for f in /usr/lib/*/libffi.so*; do
    [ -e "$f" ] || continue
    cp -P "$f" "$SDK_STAGING/lib/"
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

# ── 4. Plugin bundle tarballs ────────────────────────────────────────────────

build_plugin_bundle() {
    local bundle_name="$1"
    local subproject="$2"

    echo ""
    echo "==> Building $bundle_name plugin bundle..."

    local staging
    staging="$(mktemp -d)/gstreamer-$bundle_name"
    mkdir -p "$staging/lib/gstreamer-1.0" "$staging/lib"

    # Find plugins for this subproject from the build directory
    local plugin_files=()
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        cp -P "$f" "$staging/lib/gstreamer-1.0/"
        plugin_files+=("$f")
    done < <(plugins_for_subproject "$subproject")

    echo "  Found ${#plugin_files[@]} plugins from $subproject"

    if [ ${#plugin_files[@]} -eq 0 ]; then
        echo "  WARNING: No plugins found for $subproject, creating empty bundle"
        local tarball="gstreamer-${bundle_name}-linux-${ARCH}.tar.gz"
        tar czf "${OUTPUT_DIR}/${tarball}" -C "$staging" lib
        echo "  Created $tarball (empty)"
        return
    fi

    # Bundle transitive .so dependencies
    bundle_with_deps "$staging/lib" "${plugin_files[@]}"

    # Verify all plugins can resolve their deps
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

build_plugin_bundle "plugins-core" "gstreamer"
build_plugin_bundle "plugins-base" "gst-plugins-base"
build_plugin_bundle "plugins-good" "gst-plugins-good"
build_plugin_bundle "plugins-bad"  "gst-plugins-bad"

# ── Summary ──────────────────────────────────────────────────────────────────

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
