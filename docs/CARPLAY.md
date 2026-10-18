# CarPlay

STREAMERO implements a CarPlay **audio** app using only Apple's templates:
`CPTabBarTemplate` (Home, Library, Recent) → `CPListTemplate` (mixes, trending, liked songs, playlists, albums,
artists, downloads) → `CPNowPlayingTemplate.shared` with shuffle/repeat buttons. Artwork and explicit flags are
shown on list items; the playing item shows an indicator. Playback, lock-screen state and the queue are the same
`AudioPlayer` instance used on the phone, so CarPlay works while the iPhone is locked.

Not offered: video on the car display (never), and search (Apple does not provide a search template to audio
apps; drivers use Siri). Navigation prompts duck STREAMERO automatically because it uses the long-form playback
audio session; phone calls interrupt and resume per iOS rules.

## Entitlement (required)

1. Apply at <https://developer.apple.com/contact/carplay/> for the **CarPlay audio** entitlement for your team.
2. After approval, enable it for your App ID and regenerate provisioning profiles.
3. `ios/STREAMERO/STREAMERO.entitlements` already declares `com.apple.developer.carplay-audio`.
4. Build signed (`scripts/export-signed-ipa.sh`). A sideloaded IPA re-signed with a profile without the entitlement
   installs fine, but iOS will not show STREAMERO in CarPlay.

## Testing

- Xcode › Open Developer Tool › **CarPlay Simulator** (Additional Tools for Xcode) with a signed debug build on a
  connected iPhone, or the iOS Simulator's I/O › External Displays › CarPlay.
- Then a real vehicle or aftermarket head unit: lists load, playback starts from lists, Now Playing shows
  artwork and progress, calls/Siri/navigation prompts interrupt and resume correctly, locked-phone operation.

Status: implemented, compiled in CI, **not yet run** (no entitlement or head unit available).
