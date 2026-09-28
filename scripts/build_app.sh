#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_DIR="$ROOT_DIR/outputs/LookAt.app"
ZIP_PATH="$ROOT_DIR/outputs/LookAt-macOS.zip"
BUILD_DIR="$ROOT_DIR/work/release-build"
CACHE_DIR="$ROOT_DIR/work/cache"

cd "$ROOT_DIR"
mkdir -p "$CACHE_DIR/clang" "$CACHE_DIR/swiftpm" "$ROOT_DIR/work/config" "$ROOT_DIR/work/security"
CLANG_MODULE_CACHE_PATH="$CACHE_DIR/clang" swift build \
    --disable-sandbox \
    --cache-path "$CACHE_DIR/swiftpm" \
    --config-path "$ROOT_DIR/work/config" \
    --security-path "$ROOT_DIR/work/security" \
    --scratch-path "$BUILD_DIR" \
    -c release \
    --product LookAt

STAGING_DIR=$(mktemp -d "$ROOT_DIR/work/app-stage.XXXXXX")
trap 'rm -rf -- "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/LookAt.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" "$ROOT_DIR/outputs"
cp -X "$BUILD_DIR/release/LookAt" "$STAGED_APP/Contents/MacOS/LookAt"
cp -X "$ROOT_DIR/Info.plist" "$STAGED_APP/Contents/Info.plist"

if [[ -f "$ROOT_DIR/Assets/AppIcon.png" ]]; then
    cp -X "$ROOT_DIR/Assets/AppIcon.png" "$STAGED_APP/Contents/Resources/AppIcon.png"
fi

if [[ -f "$ROOT_DIR/Assets/AppIcon.icns" ]]; then
    cp -X "$ROOT_DIR/Assets/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
fi

plutil -lint "$STAGED_APP/Contents/Info.plist"
codesign --force --sign - "$STAGED_APP"
codesign --verify --strict --verbose=2 "$STAGED_APP"
ditto -c -k --norsrc --noextattr --keepParent "$STAGED_APP" "$STAGING_DIR/LookAt-macOS.zip"

# Publish only after the new bundle has been signed and verified. Keep the
# previous build recoverable instead of deleting it before the build succeeds.
if [[ -e "$APP_DIR" || -e "$ZIP_PATH" ]]; then
    BACKUP_DIR=$(mktemp -d "$ROOT_DIR/work/previous-release.XXXXXX")
    [[ ! -e "$APP_DIR" ]] || mv "$APP_DIR" "$BACKUP_DIR/LookAt.app"
    [[ ! -e "$ZIP_PATH" ]] || mv "$ZIP_PATH" "$BACKUP_DIR/LookAt-macOS.zip"
fi
mv "$STAGED_APP" "$APP_DIR"
mv "$STAGING_DIR/LookAt-macOS.zip" "$ZIP_PATH"

echo "$APP_DIR"
echo "$ZIP_PATH"
