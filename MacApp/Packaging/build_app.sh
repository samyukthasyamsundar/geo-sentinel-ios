#!/bin/sh
# Builds GeoSentinel.app (universal: Apple Silicon + Intel) and a .zip for download.
#
#   Packaging/build_app.sh [version]        e.g.  Packaging/build_app.sh 1.0.0
#
# Output goes to MacApp/dist/. The app is signed AD-HOC (no paid Apple Developer account, no notarisation),
# so on first launch macOS shows a warning and the user must right-click > Open. See the README.
set -eu

VERSION="${1:-0.1.0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"           # MacApp/
DIST="$ROOT/dist"
APP="$DIST/GeoSentinel.app"
export PATH="/opt/homebrew/bin:$PATH"

case "$VERSION" in
  *[!0-9.]*|"") echo "version must look like 1.2.3, got: $VERSION" >&2; exit 2 ;;
esac

cd "$ROOT"
echo "==> building arm64"
swift build -c release --arch arm64  --scratch-path "$ROOT/.build-arm64"
echo "==> building x86_64"
swift build -c release --arch x86_64 --scratch-path "$ROOT/.build-x86_64"

ARM="$ROOT/.build-arm64/release/GeoSentinelMac"
X86="$ROOT/.build-x86_64/release/GeoSentinelMac"
[ -f "$ARM" ] && [ -f "$X86" ] || { echo "a slice is missing" >&2; exit 1; }

echo "==> assembling $APP"
# Only ever remove the app bundle this script itself creates, by its exact path.
[ -d "$APP" ] && rm -r "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$ARM" "$X86" -output "$APP/Contents/MacOS/GeoSentinelMac"
sed "s/VERSION_PLACEHOLDER/$VERSION/g" "$HERE/Info.plist" > "$APP/Contents/Info.plist"
cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> zipping"
ZIP="$DIST/GeoSentinel-$VERSION-macOS.zip"
[ -f "$ZIP" ] && rm "$ZIP"
( cd "$DIST" && ditto -c -k --keepParent GeoSentinel.app "$ZIP" )
( cd "$DIST" && shasum -a 256 "GeoSentinel-$VERSION-macOS.zip" > "GeoSentinel-$VERSION-macOS.zip.sha256" )

echo "==> done"
lipo -info "$APP/Contents/MacOS/GeoSentinelMac"
ls -la "$ZIP"
cat "$ZIP.sha256"
