#!/usr/bin/env bash
#
# Build an unsigned Zoop .ipa for sideloading (AltStore / SideStore re-sign it on the device).
# Mirrors the fork's CI packaging: Release build, watch app and widget extension stripped, with a
# replaceable ad-hoc capability template for the app.
#
# Usage:
#   Tools/build-ipa.sh [output.ipa]     # default: Zoop-ios-unsigned.ipa in the repo root
#
# Needs Xcode and XcodeGen (brew install xcodegen).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/Zoop-ios-unsigned.ipa}"
DD="$ROOT/build/dd"
cd "$ROOT"

command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen" >&2; exit 1; }

echo "==> Generating Xcode project"
xcodegen generate --quiet

echo "==> Building ZoopiOS (Release, unsigned)"
xcodebuild -project Strand.xcodeproj -scheme ZoopiOS -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build -quiet

APP=$(find "$DD/Build/Products/Release-iphoneos" -maxdepth 1 -name '*.app' -type d | head -1)
[ -n "$APP" ] && [ -f "$APP/Info.plist" ] || { echo "built .app not found or incomplete" >&2; exit 1; }

echo "==> Packaging"
rm -rf "$APP/Watch"
# No widgets in the Zoop sideload: one App ID per install instead of two.
rm -rf "$APP/PlugIns/ZoopWidgets.appex"; rmdir "$APP/PlugIns" 2>/dev/null || true
Tools/prepare-ios-sideload-app.sh "$APP"
STAGE=$(mktemp -d)
mkdir "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
rm -f "$OUT"
(cd "$STAGE" && zip -qr "$OUT" Payload)
rm -rf "$STAGE"

echo "==> $OUT ($(du -h "$OUT" | cut -f1))"
