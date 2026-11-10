#!/bin/bash
# Builds HostPulse.app with the Xcode Command Line Tools (full Xcode not needed).
#
#   ./build.sh           build into build/HostPulse.app
#   ./build.sh install   build, install to /Applications, register the widget, launch
#   ./build.sh package   build a universal app and zip it to build/HostPulse.zip (for releases)
#
# ARCHS="arm64 x86_64" ./build.sh builds a universal app (package does this by default).
# VERSION=1.2.0 sets the version shown in the app.
set -euo pipefail
cd "$(dirname "$0")"

NAME=HostPulse
APP="build/$NAME.app"
WIDGET="$APP/Contents/PlugIns/${NAME}Widget.appex"
SDK=$(xcrun --sdk macosx --show-sdk-path)
if [ "${1:-}" = "package" ]; then ARCHS=${ARCHS:-arm64 x86_64}; fi
ARCHS=${ARCHS:-${ARCH:-$(uname -m)}}
STAMP=$(date +%Y%m%d%H%M)

# Compiles Swift sources once per architecture and merges the slices with lipo.
swift_build() {
    local out=$1; shift
    local slices=()
    for arch in $ARCHS; do
        swiftc -O -sdk "$SDK" -target "$arch-apple-macos14.0" -parse-as-library "$@" -o "$out.$arch"
        slices+=("$out.$arch")
    done
    lipo -create "${slices[@]}" -output "$out"
    rm -f "${slices[@]}"
}

step() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

step "Cleaning"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WIDGET/Contents/MacOS"

step "Sensor helper for remote Macs (arm64 + x86_64)"
clang -arch arm64 -arch x86_64 -mmacosx-version-min=10.13 -O2 -fobjc-arc -Wall -Wextra -Wno-unused-parameter \
    -framework Foundation -framework IOKit -framework CoreWLAN \
    -o "$APP/Contents/Resources/hostpulse-probe" Sources/Probe/hostpulse-probe.m
codesign --force --sign - "$APP/Contents/Resources/hostpulse-probe"
cp Sources/Remote/collect.sh "$APP/Contents/Resources/collect.sh"

step "Widget extension"
swift_build "$WIDGET/Contents/MacOS/${NAME}Widget" -application-extension -module-name HostPulseWidget \
    Sources/Shared/*.swift Sources/Widget/*.swift
cp Resources/Widget-Info.plist "$WIDGET/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$STAMP" "$WIDGET/Contents/Info.plist"

step "App"
swift_build "$APP/Contents/MacOS/$NAME" -module-name HostPulse \
    Sources/Shared/*.swift Sources/App/*.swift
cp Resources/App-Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$STAMP" "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
printf 'APPL????' >"$APP/Contents/PkgInfo"

# Same SDK metadata Xcode stamps into bundles.
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
SDK_BUILD=$(xcrun --sdk macosx --show-sdk-build-version)
for plist in "$APP/Contents/Info.plist" "$WIDGET/Contents/Info.plist"; do
    if [ -n "${VERSION:-}" ]; then plutil -replace CFBundleShortVersionString -string "${VERSION#v}" "$plist"; fi
    plutil -replace DTPlatformName -string macosx "$plist"
    plutil -replace DTPlatformVersion -string "$SDK_VERSION" "$plist"
    plutil -replace DTPlatformBuild -string "$SDK_BUILD" "$plist"
    plutil -replace DTSDKName -string "macosx$SDK_VERSION" "$plist"
    plutil -replace DTSDKBuild -string "$SDK_BUILD" "$plist"
done

step "Signing (ad-hoc)"
codesign --force --sign - --entitlements Resources/Widget.entitlements "$WIDGET"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/$NAME"))"

if [ "${1:-}" = "package" ]; then
    step "Packaging"
    rm -f "build/$NAME.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "build/$NAME.zip"
    echo "Packaged build/$NAME.zip"
fi

if [ "${1:-}" = "install" ]; then
    # /Applications when we may write there, otherwise ~/Applications (non-admin accounts).
    if [ -w /Applications ]; then DEST="/Applications/$NAME.app"; else mkdir -p "$HOME/Applications"; DEST="$HOME/Applications/$NAME.app"; fi
    [ "$DEST" != "/Applications/$NAME.app" ] && rm -rf "/Applications/$NAME.app" 2>/dev/null || true
    step "Installing to $DEST"
    osascript -e "tell application id \"app.hostpulse.HostPulse\" to quit" >/dev/null 2>&1 || true
    sleep 1
    pkill -x "$NAME" 2>/dev/null || true
    pkill -x "${NAME}Widget" 2>/dev/null || true # so macOS loads the new widget code
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
    pluginkit -a "$DEST/Contents/PlugIns/${NAME}Widget.appex" 2>/dev/null || true
    open "$DEST"
    echo "Installed. Add the widget: right-click the desktop → Edit Widgets… → HostPulse."
fi
