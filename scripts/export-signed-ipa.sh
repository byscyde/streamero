#!/usr/bin/env bash
# Archives and exports a SIGNED IPA (development / ad-hoc / app-store) with your Apple Developer account.
# Requires: macOS, Xcode signed in to your team, and either automatic signing or installed profiles.
#   TEAM_ID=ABCDE12345 BUNDLE_ID=com.yourco.streamero METHOD=ad-hoc ./scripts/export-signed-ipa.sh
set -euo pipefail
cd "$(dirname "$0")/../ios"
: "${TEAM_ID:?Set TEAM_ID to your Apple Developer Team ID}"
: "${BUNDLE_ID:?Set BUNDLE_ID to your registered bundle identifier}"
METHOD="${METHOD:-development}" # development | ad-hoc | app-store-connect | release-testing
OUT="build/export-$METHOD"

xcodegen generate --quiet
xcodebuild -project STREAMERO.xcodeproj -scheme STREAMERO -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/STREAMERO.xcarchive \
  DEVELOPMENT_TEAM="$TEAM_ID" STREAMERO_BUNDLE_ID="$BUNDLE_ID" -allowProvisioningUpdates archive

cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>${METHOD}</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>stripSwiftSymbols</key><true/>
</dict></plist>
PLIST

xcodebuild -exportArchive -archivePath build/STREAMERO.xcarchive -exportPath "$OUT" \
  -exportOptionsPlist build/ExportOptions.plist -allowProvisioningUpdates
echo "Signed IPA exported to ios/$OUT"
