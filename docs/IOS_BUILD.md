# iOS build, IPA export and installation

The Xcode project is generated from `ios/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
Requirements: macOS 15+, Xcode 16+ (CI uses the newest stable Xcode on `macos-15`), iOS 17.0+ deployment target.

```bash
brew install xcodegen
cd ios && xcodegen generate && open STREAMERO.xcodeproj
```

Configuration (build settings in `project.yml`, overridable on the command line):

| Setting | Default | Purpose |
| --- | --- | --- |
| `STREAMERO_BUNDLE_ID` | `com.scyde.streamero` | Bundle identifier (use your own reverse-DNS id) |
| `STREAMERO_SERVER_URL` | `https://app.streamero.net` | The fixed service address compiled into the app (https only; users never see or change it) |
| `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` | `1.0.0` / `1` | Version (SemVer) and build number (increment every upload) |
| `DEVELOPMENT_TEAM` | empty | Your Apple team id for signed builds |

## 1. Unsigned IPA for Feather / AltStore / SideStore / Sideloadly

```bash
./scripts/build-unsigned-ipa.sh                      # → ios/build/ipa/STREAMERO-1.0.0-1-unsigned.ipa (+ .sha256)
STREAMERO_SERVER_URL=https://staging.example.com ./scripts/build-unsigned-ipa.sh   # e.g. a staging build
```

No Mac? Every push runs the **iOS** GitHub Actions workflow, which uploads the IPA as the
`STREAMERO-unsigned-ipa` artifact. *Run workflow* (workflow_dispatch) accepts a different server URL for test builds. To publish a GitHub Release with
`STREAMERO.ipa`, change the `VERSION` file (e.g. `1.0.1`) and push — or push a tag `vX.Y.Z`.

Installing with **Feather**:
1. Add your signing certificate (`.p12` + password) and its `.mobileprovision` in Feather.
2. Import `STREAMERO-…-unsigned.ipa`, sign it with that certificate, install, and trust the profile if iOS asks
   (Settings › General › VPN & Device Management).
3. Open STREAMERO and sign in; it connects to the built-in server automatically.

Notes:
- The unsigned IPA is **not installable by itself**; the sideloading tool must sign it.
- Free Apple IDs expire apps after 7 days (AltStore/SideStore refresh them); paid developer certificates last a year.
- Re-signing replaces entitlements with those of your provisioning profile. Background audio, AirPlay, PiP and
  downloads work with any profile. **CarPlay** requires `com.apple.developer.carplay-audio` and **Sign in with
  Apple** requires that capability on your App ID — otherwise those features stay inactive. Email sign-in always works.
- If Feather offers to change the bundle id, either keep the change consistently or use your own id; Keychain
  sessions are tied to it.

## 2. Signed development / Ad Hoc IPA

```bash
TEAM_ID=ABCDE12345 BUNDLE_ID=com.yourco.streamero METHOD=development ./scripts/export-signed-ipa.sh
TEAM_ID=ABCDE12345 BUNDLE_ID=com.yourco.streamero METHOD=ad-hoc      ./scripts/export-signed-ipa.sh
```

Prerequisites: Xcode signed into the team, the bundle id registered, device UDIDs in the profile for Ad Hoc,
and capabilities enabled on the App ID (Background Modes are in Info.plist; CarPlay is in
`STREAMERO.entitlements` and must be granted to the App ID).

## 3. TestFlight and App Store (separate release path)

1. `METHOD=app-store-connect ./scripts/export-signed-ipa.sh` (or Xcode › Product › Archive › Distribute).
2. Upload with Xcode Organizer or `xcrun altool --upload-app` / Transporter.
3. TestFlight: add internal testers immediately; external testers require Beta App Review.
4. App Store: privacy nutrition labels (account email, listening history — linked to the user, not used for
   tracking), age rating (explicit content), export compliance (`ITSAppUsesNonExemptEncryption=false`, standard
   HTTPS only), screenshots, and review notes with a demo server + account.
   App Review will ask about content rights; document that operators supply licensed media.

## Versioning

SemVer `MARKETING_VERSION` for user-visible releases; `CURRENT_PROJECT_VERSION` increases on every build
uploaded anywhere. Tag releases `vX.Y.Z`. The backend API is versioned by path (`/v1`); additive changes only
within a major version, and the app ignores unknown JSON fields.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `xcodegen: command not found` | `brew install xcodegen` |
| Package resolution fails | `File › Packages › Reset Package Caches`; StreameroCore is a local package |
| Feather: "Unable to install" | Certificate revoked/expired, or device not in the profile (Ad Hoc). Re-sign with a valid profile |
| App can't reach server | Use `https://`; for LAN `http://` the server must be on the local network (ATS allows local networking only) |
| No sound in background | Check Silent Mode isn't the issue (playback category ignores it) and that another app didn't take the audio session |
| CarPlay doesn't show the app | The signing profile lacks the CarPlay audio entitlement (see CARPLAY.md) |
