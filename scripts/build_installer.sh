#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist")
VOLUME_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleGetInfoString' "$ROOT_DIR/Info.plist")
DMG_PATH="$ROOT_DIR/outputs/LookAt-$VERSION.dmg"

"$ROOT_DIR/scripts/build_app.sh"

STAGE_DIR=$(mktemp -d "$ROOT_DIR/work/dmg-stage.XXXXXX")
VERIFY_MOUNT="$STAGE_DIR/mounted"
DMG_ATTACHED=false
cleanup() {
    if [[ "$DMG_ATTACHED" == true ]]; then
        # Never remove a staging directory containing a still-mounted volume.
        hdiutil detach "$VERIFY_MOUNT" || return 1
    fi
    rm -rf -- "$STAGE_DIR"
}
trap cleanup EXIT
mkdir -p "$STAGE_DIR/volume"
cp -RX "$ROOT_DIR/outputs/LookAt.app" "$STAGE_DIR/volume/LookAt.app"
ln -s /Applications "$STAGE_DIR/volume/Applications"

# A regular filesystem image preserves the signed bundle. makehybrid can
# synthesize FinderInfo on icon files, invalidating an otherwise valid signature.
hdiutil create \
    -srcfolder "$STAGE_DIR/volume" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -format UDZO \
    -nospotlight \
    "$STAGE_DIR/LookAt.dmg"

hdiutil verify "$STAGE_DIR/LookAt.dmg"
mkdir -p "$VERIFY_MOUNT" "$STAGE_DIR/install-check"
hdiutil attach "$STAGE_DIR/LookAt.dmg" -readonly -nobrowse -mountpoint "$VERIFY_MOUNT"
DMG_ATTACHED=true
codesign --verify --strict --verbose=2 "$VERIFY_MOUNT/LookAt.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$VERIFY_MOUNT/LookAt.app/Contents/Info.plist")" == "$VERSION" ]]
[[ "$(readlink "$VERIFY_MOUNT/Applications")" == /Applications ]]
cmp "$ROOT_DIR/outputs/LookAt.app/Contents/MacOS/LookAt" "$VERIFY_MOUNT/LookAt.app/Contents/MacOS/LookAt"

# Also verify a normal copy out of the volume, equivalent to installing by drag.
ditto "$VERIFY_MOUNT/LookAt.app" "$STAGE_DIR/install-check/LookAt.app"
codesign --verify --strict --verbose=2 "$STAGE_DIR/install-check/LookAt.app"
hdiutil detach "$VERIFY_MOUNT"
DMG_ATTACHED=false

if [[ -e "$DMG_PATH" ]]; then
    BACKUP_DIR=$(mktemp -d "$ROOT_DIR/work/previous-dmg.XXXXXX")
    mv "$DMG_PATH" "$BACKUP_DIR/LookAt-$VERSION.dmg"
fi
mv "$STAGE_DIR/LookAt.dmg" "$DMG_PATH"

mkdir -p "$STAGE_DIR/source/LookAt"
for item in Sources Tests scripts Assets Info.plist Package.swift README.md VALIDATION.md; do
    [[ ! -e "$ROOT_DIR/$item" ]] || cp -RX "$ROOT_DIR/$item" "$STAGE_DIR/source/LookAt/$item"
done
ditto -c -k --norsrc --noextattr --keepParent "$STAGE_DIR/source/LookAt" "$STAGE_DIR/LookAt-Source.zip"
mv -f "$STAGE_DIR/LookAt-Source.zip" "$ROOT_DIR/outputs/LookAt-Source.zip"
echo "$DMG_PATH"
