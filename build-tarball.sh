#!/usr/bin/env bash
# Build a hermetic GStreamer SDK tarball for Linux.
#
# Designed to run natively on CI runners (Ubuntu 22.04).
# For each architecture, GitHub Actions provides a native runner,
# so no Docker or QEMU is needed.
#
# Usage:
#   ./build-tarball.sh [x86_64|aarch64]
#
# Outputs:
#   gstreamer-sdk-linux-<arch>.tar.gz  in the current directory
#   Prints the SHA-256 for MODULE.bazel at the end.

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

OUTPUT="gstreamer-sdk-linux-${ARCH}.tar.gz"

echo "==> Installing GStreamer development packages..."

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends \
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    libglib2.0-dev \
    >/dev/null 2>&1

STAGING="$(mktemp -d)/gstreamer-sdk"
mkdir -p "$STAGING/include" "$STAGING/lib"

echo "==> Copying headers..."

# glib / gobject / gio
cp -R /usr/include/glib-2.0 "$STAGING/include/"

# glib internal config header lives under lib/
GLIBCONFIG_DIR=$(dirname "$(dpkg -L libglib2.0-dev | grep glibconfig.h | head -1)")
mkdir -p "$STAGING/lib/glib-2.0/include"
cp "$GLIBCONFIG_DIR/glibconfig.h" "$STAGING/lib/glib-2.0/include/"

# gstreamer
cp -R /usr/include/gstreamer-1.0 "$STAGING/include/"

echo "==> Copying libraries..."

# Copy .so symlinks and .a files for the libraries we need.
for lib in glib-2.0 gobject-2.0 gio-2.0 gstreamer-1.0 gstbase-1.0 gmodule-2.0 gthread-2.0; do
    for f in /usr/lib/*/lib${lib}.so* /usr/lib/*/lib${lib}.a; do
        [ -e "$f" ] || continue
        cp -P "$f" "$STAGING/lib/"
    done
done

# Ensure unversioned .so symlinks exist
cd "$STAGING/lib"
for f in *.so.*; do
    [ -e "$f" ] || continue
    base="${f%%.so.*}.so"
    [ -e "$base" ] || ln -sf "$f" "$base"
done

echo "==> Creating tarball..."

cd "$(dirname "$STAGING")"
tar czf "${OLDPWD}/${OUTPUT}" -C "$STAGING" include lib

cd "$OLDPWD"
echo ""
echo "Output: ${OUTPUT}"
echo "SHA-256:"
sha256sum "${OUTPUT}"
