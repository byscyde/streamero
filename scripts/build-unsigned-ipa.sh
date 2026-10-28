#!/usr/bin/env bash
# Builds an UNSIGNED STREAMERO.ipa for sideloading tools that re-sign on device (Feather, AltStore,
# SideStore, Sideloadly). An unsigned IPA cannot be installed on an iPhone as-is: the tool must sign it
# with your own certificate/provisioning profile. Requires macOS with Xcode and XcodeGen.
set -euo pipefail
cd "$(dirname "$0")/../ios"

CONFIGURATION="${CONFIGURATION:-Release}"
OUT_DIR="${OUT_DIR:-$(pwd)/build/ipa}"
DERIVED="${DERIVED:-$(pwd)/build/DerivedData}"

command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen" >&2; exit 1; }
xcodebuild -version
xcodegen generate --quiet
mkdir -p "$DERIVED"
LOG="$(pwd)/build/build.log"

set +e
xcodebuild \
  -project STREAMERO.xcodeproj \
  -scheme STREAMERO \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  ${STREAMERO_BUNDLE_ID:+STREAMERO_BUNDLE_ID="$STREAMERO_BUNDLE_ID"} \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS="" \
  build > "$LOG" 2>&1
STATUS=$?
set -e
grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$LOG" | sort -u | head -200 || true
[ $STATUS -eq 0 ] || { echo "xcodebuild failed (full log: ios/build/build.log)" >&2; exit $STATUS; }

APP="$DERIVED/Build/Products/${CONFIGURATION}-iphoneos/STREAMERO.app"
[ -d "$APP" ] || { echo "Build failed: $APP missing (see ios/build/build.log)" >&2; exit 1; }

rm -rf "$OUT_DIR" && mkdir -p "$OUT_DIR/Payload"
cp -R "$APP" "$OUT_DIR/Payload/"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Info.plist")
IPA="$OUT_DIR/STREAMERO-${VERSION}-${BUILD}-unsigned.ipa"
(cd "$OUT_DIR" && zip -qry "$IPA" Payload)
rm -rf "$OUT_DIR/Payload"
shasum -a 256 "$IPA" | tee "$IPA.sha256"
echo "Unsigned IPA: $IPA"
