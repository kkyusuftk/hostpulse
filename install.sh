#!/bin/bash
# Installs the latest HostPulse release.
#
#   curl -fsSL https://raw.githubusercontent.com/kkyusuftk/hostpulse/main/install.sh | bash
#
# Options (environment variables):
#   HOSTPULSE_VERSION=v1.0.0   install a specific release instead of the latest
#   HOSTPULSE_DIR=~/Apps       install somewhere else (default: /Applications, or
#                              ~/Applications when /Applications isn't writable)
#   HOSTPULSE_ZIP=path.zip     install from a local zip instead of downloading
#   HOSTPULSE_NO_LAUNCH=1      don't open the app afterwards
set -euo pipefail

REPO="kkyusuftk/hostpulse"
NAME="HostPulse"
BUNDLE_ID="app.hostpulse.HostPulse"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "HostPulse only runs on macOS."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || fail "HostPulse needs macOS 14 (Sonoma) or newer; this Mac has $(sw_vers -productVersion)."

if [ -n "${HOSTPULSE_DIR:-}" ]; then
    DIR="${HOSTPULSE_DIR/#\~/$HOME}"
elif [ -w /Applications ]; then
    DIR="/Applications"
else
    DIR="$HOME/Applications"
fi
mkdir -p "$DIR"
DEST="$DIR/$NAME.app"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ -n "${HOSTPULSE_ZIP:-}" ]; then
    cp "$HOSTPULSE_ZIP" "$TMP/$NAME.zip"
else
    if [ -n "${HOSTPULSE_VERSION:-}" ]; then
        URL="https://github.com/$REPO/releases/download/$HOSTPULSE_VERSION/$NAME.zip"
    else
        URL="https://github.com/$REPO/releases/latest/download/$NAME.zip"
    fi
    say "Downloading $URL"
    curl -fL --progress-bar -o "$TMP/$NAME.zip" "$URL" || fail "Download failed."
fi

say "Unpacking"
ditto -x -k "$TMP/$NAME.zip" "$TMP/unpacked"
[ -d "$TMP/unpacked/$NAME.app" ] || fail "The download doesn't contain $NAME.app."

# Stop the running copy so macOS loads the new app and widget code.
if pgrep -x "$NAME" >/dev/null 2>&1; then
    say "Quitting the running $NAME"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    sleep 1
    pkill -x "$NAME" 2>/dev/null || true
fi
pkill -x "${NAME}Widget" 2>/dev/null || true

say "Installing to $DEST"
rm -rf "$DEST"
ditto "$TMP/unpacked/$NAME.app" "$DEST"

# The app isn't notarized by Apple, so clear the quarantine flag that would make
# Gatekeeper block it ("damaged" / "unidentified developer").
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true
pluginkit -a "$DEST/Contents/PlugIns/${NAME}Widget.appex" 2>/dev/null || true

version=$(defaults read "$DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
if [ -z "${HOSTPULSE_NO_LAUNCH:-}" ]; then
    open "$DEST"
fi

cat <<EOF

HostPulse $version is installed at $DEST.

  • It runs in the menu bar (server-rack icon). Add machines from the
    popover → gear → Hosts → +. Each host must accept 'ssh <host> true'
    without a password prompt.
  • Widget: right-click the desktop → Edit Widgets… → search "HostPulse".
  • Uninstall: quit HostPulse, then
      rm -rf "$DEST" ~/Library/Application\ Support/HostPulse
EOF
