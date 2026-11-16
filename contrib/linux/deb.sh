#!/bin/sh
# Builds target/kibi_<version>_<arch>.deb on a Debian or Ubuntu machine:
# the engine and CLI (/usr/bin/kibi, kibi-init), the kibi system service,
# and the window (/usr/lib/kibi/kibi-window) with its launcher and icon.
#
# Needs: Rust, dpkg-deb, and libwebkit2gtk-4.1-dev for the window. Run it
# on the oldest release the package should install on: the window links
# that release's glibc, GTK and WebKitGTK.
set -eu
cd "$(dirname "$0")/../.."
root=$(pwd)
version=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
arch=$(dpkg --print-architecture)

cargo build --release -p kibi -p kibi-init
# Its own target dir: the same crate with another feature set would
# otherwise rebuild over the engine's binary each time.
CARGO_TARGET_DIR=target/window cargo build --release -p kibi --features window

pkg=target/deb/kibi_${version}_${arch}
rm -rf "$pkg"
install -d "$pkg/DEBIAN" "$pkg/usr/bin" "$pkg/usr/lib/kibi" "$pkg/usr/lib/systemd/system" "$pkg/usr/share/applications"
install -m 755 target/release/kibi target/release/kibi-init "$pkg/usr/bin/"
install -m 755 target/window/release/kibi "$pkg/usr/lib/kibi/kibi-window"
sed 's|^ExecStart=/usr/local/bin/kibi daemon|ExecStart=/usr/bin/kibi daemon|' contrib/linux/kibi.service >"$pkg/usr/lib/systemd/system/kibi.service"
install -m 644 contrib/linux/kibi.desktop "$pkg/usr/share/applications/kibi.desktop"
for s in 16 32 64 128 256 512; do
    install -D -m 644 "brand/icon/png/kibi-app-icon-$s.png" "$pkg/usr/share/icons/hicolor/${s}x${s}/apps/kibi.png"
done
install -D -m 644 brand/icon/kibi-app-icon.svg "$pkg/usr/share/icons/hicolor/scalable/apps/kibi.svg"
install -m 755 contrib/linux/deb/postinst contrib/linux/deb/prerm contrib/linux/deb/postrm "$pkg/DEBIAN/"

size=$(du -sk "$pkg/usr" | cut -f1)
cat >"$pkg/DEBIAN/control" <<EOF
Package: kibi
Version: $version
Architecture: $arch
Maintainer: Kibi
Homepage: https://runkibi.kambiz.site
Section: admin
Priority: optional
Installed-Size: $size
Depends: libc6, libgtk-3-0t64 | libgtk-3-0, libwebkit2gtk-4.1-0, docker.io | docker-ce-cli
Recommends: docker-buildx | docker-buildx-plugin, docker-compose-v2 | docker-compose-plugin
Description: Run, build and share containers
 Kibi is a small container engine with its own window. Plain docker
 commands work against it through the "kibi" docker context, and the
 window shows containers, images, volumes, builds and Kubernetes, and
 shares a container on a public https link.
EOF
dpkg-deb --root-owner-group --build "$pkg" "target/kibi_${version}_${arch}.deb"
echo "$root/target/kibi_${version}_${arch}.deb"
