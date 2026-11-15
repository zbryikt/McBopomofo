#!/bin/bash
#
# Builds the input method and installs it into ~/Library/Input Methods for
# local testing, without going through the installer app.
#
# Unlike the installer, this overwrites the installed bundle in place rather
# than moving it to the Trash, and unregisters the build products from
# Launch Services, so that only one bundle with the input method's bundle ID
# is known to the system.
#
# The first install of a new bundle ID still needs the installer (or a log
# out and log in) before the input method shows up in the input menu.
#
# If the code signing identity CODESIGN_IDENTITY (default: "devsuite code
# signing", made by ~/workspace/devsuite/init-codesign.sh) is in the keychain,
# the installed bundle is signed with it, so that macOS keeps privacy
# permissions such as the microphone across rebuilds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT="$REPO_DIR/McBopomofo.xcodeproj"
SCHEME="McBopomofo"
CONFIGURATION="${CONFIGURATION:-Debug}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-devsuite code signing}"

# Use the same DerivedData as Xcode, so builds are shared.
build_setting() {
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
        -showBuildSettings 2>/dev/null | awk -F ' = ' -v key="$1" '$1 ~ "^ *" key "$" { print $2; exit }'
}

BUILT_PRODUCTS_DIR="$(build_setting BUILT_PRODUCTS_DIR)"
PRODUCT_NAME="$(build_setting PRODUCT_NAME)"
APP_NAME="$PRODUCT_NAME.app"
BUILT_APP="$BUILT_PRODUCTS_DIR/$APP_NAME"
INSTALLED_APP="$HOME/Library/Input Methods/$APP_NAME"

echo "==> Building $APP_NAME ($CONFIGURATION)"
# xcodebuild logs noisy errors about connected iOS devices even when the
# build succeeds, so only show its output on failure.
BUILD_LOG="$(mktemp -t dev-install-build)"
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
    build >"$BUILD_LOG" 2>&1; then
    grep -E "error:|BUILD FAILED" "$BUILD_LOG" >&2 || tail -n 50 "$BUILD_LOG" >&2
    echo "Build failed. Full log: $BUILD_LOG" >&2
    exit 1
fi
rm -f "$BUILD_LOG"

if [[ ! -d "$INSTALLED_APP" ]]; then
    echo "warning: $INSTALLED_APP is not installed yet." >&2
    echo "         Run the McBopomofoInstaller scheme once first, then use this script." >&2
fi

echo "==> Stopping $PRODUCT_NAME"
killall -9 "$PRODUCT_NAME" 2>/dev/null || true

echo "==> Installing to $INSTALLED_APP"
mkdir -p "$INSTALLED_APP"
rsync -a --delete "$BUILT_APP/" "$INSTALLED_APP/"

if security find-certificate -c "$CODESIGN_IDENTITY" >/dev/null 2>&1; then
    echo "==> Signing with \"$CODESIGN_IDENTITY\""
    codesign --force --deep --sign "$CODESIGN_IDENTITY" "$INSTALLED_APP" 2>/dev/null
fi

echo "==> Updating Launch Services registrations"
for stray in \
    "$BUILT_APP" \
    "$BUILT_PRODUCTS_DIR/McBopomofoInstaller.app/Contents/Resources/$APP_NAME" \
    "$HOME/.Trash/$PRODUCT_NAME"*.app; do
    if [[ -d "$stray" ]]; then
        "$LSREGISTER" -u "$stray" 2>/dev/null || true
    fi
done
"$LSREGISTER" -f "$INSTALLED_APP"

echo "==> Done. Switch to another input source and back to load the new build."
