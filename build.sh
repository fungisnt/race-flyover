#!/bin/zsh
# Builds RaceFlyover.saver and the RaceFlyoverPreview app into build/.
#
#   ./build.sh            build both
#   ./build.sh install    build, then install the screensaver into ~/Library/Screen Savers
#   ./build.sh preview    build, then open the preview app
#   ./build.sh release    build, then zip the screensaver for a GitHub release
set -euo pipefail
cd "${0:A:h}"

BUILD=build
SAVER="$BUILD/RaceFlyover.saver"
APP="$BUILD/RaceFlyoverPreview.app"
MIN_OS=14.0
SOURCES=(Sources/RaceFlyover/*.swift)
FRAMEWORKS=(-framework ScreenSaver -framework MapKit -framework AppKit -framework CoreLocation -framework QuartzCore -framework Metal)
FLAGS=(-O -swift-version 5 -suppress-warnings)

compile() { # $1 output, $2 module, rest: extra args
  local out=$1 module=$2; shift 2
  local slices=()
  for arch in arm64 x86_64; do
    swiftc "${FLAGS[@]}" -target "$arch-apple-macos$MIN_OS" -module-name "$module" \
      "${FRAMEWORKS[@]}" "$@" -o "$out.$arch"
    slices+=("$out.$arch")
  done
  lipo -create "${slices[@]}" -output "$out"
  rm -f "${slices[@]}"
}

copy_courses() { # $1 resources dir
  mkdir -p "$1/Courses"
  cp Resources/Courses/*.json "$1/Courses/"
}

# Version shown in Options: the release tag when building one (v1.0.0), else the
# commit (a36342a), with "-dirty" if there are uncommitted changes.
VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo dev)
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
stamp_version() { # $1 Info.plist
  plutil -replace RaceFlyoverVersion -string "$VERSION" "$1"
  plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$1"
  local tag=$(git describe --tags --abbrev=0 2>/dev/null || true)
  [[ -n "$tag" ]] && plutil -replace CFBundleShortVersionString -string "${tag#v}" "$1"
  return 0
}

echo "› Building screensaver ($VERSION)"
rm -rf "$SAVER"
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"
compile "$SAVER/Contents/MacOS/RaceFlyover" RaceFlyover -parse-as-library -Xlinker -bundle "${SOURCES[@]}"
cp Resources/Info.plist "$SAVER/Contents/Info.plist"
stamp_version "$SAVER/Contents/Info.plist"
copy_courses "$SAVER/Contents/Resources"
# Thumbnail shown in System Settings › Screen Saver.
cp Resources/thumbnail.png Resources/thumbnail@2x.png "$SAVER/Contents/Resources/"
# Signing can fail in CI or on machines without a valid local identity; keep the
# build moving rather than aborting on a non-fatal code-signing issue.
codesign --force --sign - "$SAVER" 2>/dev/null || true

echo "› Building preview app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
compile "$APP/Contents/MacOS/RaceFlyoverPreview" RaceFlyoverPreview "${SOURCES[@]}" Sources/Preview/main.swift
sed -e 's/<string>RaceFlyover<\/string>/<string>RaceFlyoverPreview<\/string>/' \
    -e 's/com.raceflyover.RaceFlyover/com.raceflyover.RaceFlyoverPreview/' \
    -e 's/<string>BNDL<\/string>/<string>APPL<\/string>/' \
    -e 's/<string>Race Flyover<\/string>/<string>Race Flyover Preview<\/string>/g' \
    Resources/Info.plist > "$APP/Contents/Info.plist"
stamp_version "$APP/Contents/Info.plist"
copy_courses "$APP/Contents/Resources"
codesign --force --sign - "$APP" 2>/dev/null || true

echo "✓ $SAVER"
echo "✓ $APP"

case "${1:-}" in
  install)
    DEST="$HOME/Library/Screen Savers"
    mkdir -p "$DEST"
    rm -rf "$DEST/RaceFlyover.saver"
    cp -R "$SAVER" "$DEST/"
    # The Screen Saver list is cached by WallpaperAgent and its legacy-saver
    # extension; restart them (they relaunch on demand) along with any running
    # saver host so System Settings rescans and loads the new build.
    killall legacyScreenSaver WallpaperLegacyExtension WallpaperAgent 2>/dev/null || true
    osascript -e 'tell application "System Settings" to quit' 2>/dev/null || true
    echo "✓ Installed to $DEST/RaceFlyover.saver — open System Settings › Screen Saver and scroll to Other"
    ;;
  preview)
    open "$APP"
    ;;
  release)
    ZIP="$BUILD/RaceFlyover-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --norsrc --noextattr --noacl --keepParent "$SAVER" "$ZIP"
    echo "✓ $ZIP"
    ;;
esac
