# gstreamer-prebuilt

Pre-built GStreamer SDK tarballs for hermetic Bazel builds on Linux.

These tarballs contain headers and shared libraries for GStreamer, GLib, and
related dependencies — just enough for Rust `*-sys` crates to compile against.

## Triggering a build

### Automatic (tag push)

```bash
git tag v1.26.11
git push origin v1.26.11
```

The CI workflow builds tarballs for **x86_64** and **aarch64** using native
GitHub Actions runners (no QEMU), then publishes them as GitHub Release assets.

### Manual (workflow dispatch)

Go to **Actions > Build GStreamer SDK > Run workflow** and enter the GStreamer
version string (e.g. `1.26.11`).

## Consuming in MODULE.bazel

After a release, copy the URLs and SHA-256 hashes from the release notes:

```python
gstreamer_pkg = use_repo_rule("//bazel/rules:gstreamer_pkg.bzl", "gstreamer_pkg")

gstreamer_pkg(
    name = "gstreamer_sdk",
    version = "1.26.11",
    macos_sha256 = "...",
    linux_x86_64_url = "https://github.com/rillanetwork/gstreamer-prebuilt/releases/download/v1.26.11/gstreamer-sdk-linux-x86_64.tar.gz",
    linux_x86_64_sha256 = "<from release notes>",
    linux_aarch64_url = "https://github.com/rillanetwork/gstreamer-prebuilt/releases/download/v1.26.11/gstreamer-sdk-linux-aarch64.tar.gz",
    linux_aarch64_sha256 = "<from release notes>",
)
```

## License

The build scripts in this repo are MIT-licensed. The tarballs themselves contain
GStreamer and GLib libraries which are licensed under LGPL-2.1+.
