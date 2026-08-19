#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.tools"
GHOSTTY_COMMIT="b211341be1ba902e772f57fc67c3e65d35205676"
KIT_ARCHIVE="$TOOLS/GhosttyKit.xcframework.tar.gz"
KIT_EXTRACTED="$TOOLS/GhosttyKit.xcframework"
SOURCE_ARCHIVE="$TOOLS/ghostty-${GHOSTTY_COMMIT}.tar.gz"
SOURCE_DIR="$TOOLS/ghostty-${GHOSTTY_COMMIT}"
THEMES_ARCHIVE="$TOOLS/ghostty-themes-8c97c3c.tgz"
DESTINATION="$ROOT/GhosttyKit.xcframework"
RESOURCES="$ROOT/Piñata/GhosttyResources"
TERMINFO_SOURCE="$ROOT/Resources/xterm-ghostty.terminfo"
ZMX_ARCHIVE="$TOOLS/zmx-0.7.0-macos-aarch64.tar.gz"
ZMX_RESOURCES="$ROOT/Piñata/ZmxResources"

KIT_URL="https://github.com/manaflow-ai/ghostty/releases/download/xcframework-${GHOSTTY_COMMIT}-crashsubdir-cmux-crash-v1/GhosttyKit.xcframework.tar.gz"
KIT_SHA256="09aa0ae53edc7ef2ca04e13ea820f6f0861b24f851ac7f2fae28b978eec980a3"
SOURCE_URL="https://github.com/manaflow-ai/ghostty/archive/${GHOSTTY_COMMIT}.tar.gz"
SOURCE_SHA256="bf8f7a9d1c5a8194933003a5d61a6a22c09986f2fe34c63c5c639268651211e6"
THEMES_URL="https://deps.files.ghostty.org/ghostty-themes-release-20260629-161812-8c97c3c.tgz"
THEMES_SHA256="aae3023ec6d521e2eacc8576a248d10d94cac40e9876451262ec660477f7c4c8"
ZMX_URL="https://zmx.sh/a/zmx-0.7.0-macos-aarch64.tar.gz"
ZMX_SHA256="a63d6f3edd6d4b38240f8f81513e60e35a898ca520211112d7bc67f610f1f3eb"

download() {
  local url="$1"
  local destination="$2"
  if [[ ! -f "$destination" ]]; then
    curl --fail --location "$url" --output "$destination"
  fi
}

verify() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(shasum -a 256 "$path" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "Checksum mismatch for $path." >&2
    exit 1
  fi
}

mkdir -p "$TOOLS"
download "$KIT_URL" "$KIT_ARCHIVE"
download "$SOURCE_URL" "$SOURCE_ARCHIVE"
download "$THEMES_URL" "$THEMES_ARCHIVE"
download "$ZMX_URL" "$ZMX_ARCHIVE"
verify "$KIT_ARCHIVE" "$KIT_SHA256"
verify "$SOURCE_ARCHIVE" "$SOURCE_SHA256"
verify "$THEMES_ARCHIVE" "$THEMES_SHA256"
verify "$ZMX_ARCHIVE" "$ZMX_SHA256"

if [[ ! -d "$KIT_EXTRACTED" ]]; then
  tar -xzf "$KIT_ARCHIVE" -C "$TOOLS"
fi
if [[ ! -d "$SOURCE_DIR" ]]; then
  tar -xzf "$SOURCE_ARCHIVE" -C "$TOOLS"
fi

library_dir="$KIT_EXTRACTED/macos-arm64_x86_64"
if [[ -f "$library_dir/ghostty-internal.a" ]]; then
  mv "$library_dir/ghostty-internal.a" "$library_dir/libghostty.a"
fi
plutil -replace AvailableLibraries.0.BinaryPath -string libghostty.a "$KIT_EXTRACTED/Info.plist"
plutil -replace AvailableLibraries.0.LibraryPath -string libghostty.a "$KIT_EXTRACTED/Info.plist"

rm -rf "$DESTINATION" "$RESOURCES" "$ZMX_RESOURCES"
cp -R "$KIT_EXTRACTED" "$DESTINATION"
mkdir -p "$RESOURCES/ghostty/themes" "$RESOURCES/terminfo"
cp -R "$SOURCE_DIR/src/shell-integration" "$RESOURCES/ghostty/shell-integration"
tar -xzf "$THEMES_ARCHIVE" -C "$RESOURCES/ghostty/themes" --strip-components=1
tic -x -o "$RESOURCES/terminfo" "$TERMINFO_SOURCE"
mkdir -p "$ZMX_RESOURCES"
tar -xzf "$ZMX_ARCHIVE" -C "$ZMX_RESOURCES"
chmod 755 "$ZMX_RESOURCES/zmx"

echo "GhosttyKit, zmx, and resources are ready."
