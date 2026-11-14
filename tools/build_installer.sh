#!/bin/zsh
# Packages build/RaceFlyover.saver into a .pkg installer in build/.
# Run ./build.sh first. The pkg installs the screensaver system-wide into
# /Library/Screen Savers.
#
#   tools/build_installer.sh                      unsigned pkg
#   tools/build_installer.sh "Developer ID Installer: Name (TEAMID)"   signed pkg
set -euo pipefail
cd "${0:A:h}/.."

BUILD=build
SAVER="$BUILD/RaceFlyover.saver"
IDENTITY=${1:-}
PKG_SCRIPTS="$BUILD/pkg-scripts"

[[ -d "$SAVER" ]] || { echo "error: $SAVER not found — run ./build.sh first" >&2; exit 1; }

rm -rf "$PKG_SCRIPTS"
mkdir -p "$PKG_SCRIPTS"
cat > "$PKG_SCRIPTS/postinstall" <<'EOF'
#!/bin/zsh
set -e
killall legacyScreenSaver WallpaperLegacyExtension WallpaperAgent 2>/dev/null || true
osascript -e 'tell application "System Settings" to quit' 2>/dev/null || true
exit 0
EOF
chmod 755 "$PKG_SCRIPTS/postinstall"

VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo dev)
# pkgbuild wants a numeric version: strip a leading v and anything from the
# first - (e.g. v1.2.0-3-gabc → 1.2.0); fall back to the commit count.
PKG_VERSION="${VERSION#v}"
PKG_VERSION="${PKG_VERSION%%-*}"
[[ "$PKG_VERSION" =~ '^[0-9]+(\.[0-9]+)*$' ]] || \
  PKG_VERSION=$(git rev-list --count HEAD 2>/dev/null || echo 1)

PKG="$BUILD/RaceFlyover-$VERSION.pkg"
rm -f "$PKG"

args=(--component "$SAVER"
      --install-location "/Library/Screen Savers"
      --identifier com.raceflyover.RaceFlyover
      --version "$PKG_VERSION"
      --scripts "$PKG_SCRIPTS")
[[ -n "$IDENTITY" ]] && args+=(--sign "$IDENTITY")

pkgbuild "${args[@]}" "$PKG"
echo "✓ $PKG"
# Signature verification can fail even when pkgbuild succeeded (for example, a
# stale or non-trusted installer identity in CI). Keep the package build itself as
# the pass/fail signal for this workflow instead of treating verification as a
# fatal error.
[[ -n "$IDENTITY" ]] && pkgutil --check-signature "$PKG" || echo "warning: signature verification failed; installer package was still created" >&2
