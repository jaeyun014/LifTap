#!/bin/sh
set -eu

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
swift build --configuration release
bin="$(swift build --configuration release --show-bin-path)"

mkdir -p "$repo/dist"
stage="$(mktemp -d "$repo/dist/.liftap.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/LifTap.app"
mkdir -p "$bundle/Contents/MacOS"
install -m 755 "$bin/LifTap" "$bundle/Contents/MacOS/LifTap"
install -m 644 "$repo/Packaging/Info.plist" "$bundle/Contents/Info.plist"

/usr/bin/codesign --force --options runtime --timestamp=none \
    --sign "${LIFTAP_SIGN_IDENTITY:--}" \
    --entitlements "$repo/Packaging/LifTap.entitlements" "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
/usr/bin/ditto "$bundle" "$repo/dist/LifTap.app"
echo "$repo/dist/LifTap.app"
