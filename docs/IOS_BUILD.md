# iOS build and IPA

The Xcode project is generated from `ios/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
Requirements: macOS with Xcode 16+ (CI uses the newest stable Xcode on `macos-15`); deployment target iOS 17.

```bash
brew install xcodegen
cd ios && xcodegen generate && open STREAMERO.xcodeproj
swift test --package-path Packages/StreameroKit     # API layer tests (also run on Linux in CI)
```

| Setting | Default | Purpose |
| --- | --- | --- |
| `STREAMERO_BUNDLE_ID` | `com.scyde.streamero` | Bundle identifier |
| `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` | from `VERSION` / CI run number | Version shown in Settings |

## Unsigned IPA (Feather, AltStore, SideStore, Sideloadly)

```bash
./scripts/build-unsigned-ipa.sh     # → ios/build/ipa/STREAMERO-<version>-<build>-unsigned.ipa
```

Every push runs the **iOS** workflow (Linux package tests, simulator unit + UI tests, IPA artifact). To publish a
GitHub Release with `STREAMERO.ipa`, change the `VERSION` file and push.

The unsigned IPA cannot be installed by itself — the sideloading tool signs it with your certificate. The app needs no
special entitlements (Face ID uses `NSFaceIDUsageDescription` only).

## Signed IPA (own Apple Developer account)

```bash
TEAM_ID=ABCDE12345 BUNDLE_ID=com.scyde.streamero METHOD=ad-hoc ./scripts/export-signed-ipa.sh
```
