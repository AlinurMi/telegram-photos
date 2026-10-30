# TelegramPhotos

A small personal iPhone app that backs up photos and videos from the Photos library to a private Telegram channel, in original quality.

> **Unofficial personal project.** It is not affiliated with Telegram or Apple, is not on the App Store, and comes with no support. It logs in with *your own* Telegram account through the official [TDLib](https://github.com/tdlib/td) client library.

## What it does

- Uploads every photo and video as a **file (document)**, so nothing is recompressed. That covers HEIC, ProRAW/DNG, HEVC/ProRes and Live Photo videos.
- **One-way, append-only.** Deleting or editing a photo on the phone never touches what's already in Telegram. An optional setting, "Re-send edited photos", uploads a new copy tagged `#edit` when you edit a photo that's already backed up.
- Captions carry the date taken, the original filename, the location (place name plus a maps link) and searchable hashtags (`#y2026 #m10`).
- Syncs whenever it's allowed to run:
  - **Sync Now**, with progress in the Dynamic Island and on the Lock Screen
  - **Shortcuts automations** that run the app's "Sync Photos" action
  - **Overnight** while the phone charges on Wi-Fi
- Wi-Fi only by default. The one-time backfill of the existing library runs automatically only while charging; tapping **Sync Now** uploads it right away.

## Requirements

- iPhone on iOS 26 or later
- A Telegram account and your own API credentials from [my.telegram.org](https://my.telegram.org). You type them into the app on the phone; they're never stored in this repo.
- An Apple ID (a free one works) and [SideStore](https://sidestore.io) on the iPhone to install the app. SideStore is set up once from any Linux, macOS or Windows computer with [iloader](https://github.com/nab138/iloader).

## Building

You don't need a Mac. Every push runs GitHub Actions on a macOS runner, which:

1. generates the Xcode project from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen),
2. runs the `SyncCore` unit tests,
3. builds an **unsigned** `TelegramPhotos.ipa` and publishes it as a GitHub Release: `latest` for `main`, and pre-release `pr-<number>` for pull requests.

On the iPhone, open the release's `TelegramPhotos.ipa` link in Safari, download it, and open it in SideStore, which signs and installs it with your Apple ID. Free Apple ID installs expire after 7 days, so let SideStore refresh them weekly (a Shortcuts automation can do it for you).

The pure-Swift sync logic in `Packages/SyncCore` builds and tests on any platform Swift supports, Windows included:

```bash
swift test --package-path Packages/SyncCore
```

## Project layout

```
App/                 iOS app (SwiftUI)
Widgets/             Live Activity (Dynamic Island / Lock Screen) extension
Shared/              Code shared by the app and the widget extension
Packages/SyncCore/   Platform-independent sync engine + tests
project.yml          XcodeGen project definition
.github/workflows/   CI
```

## Acknowledgements

- [TDLib](https://github.com/tdlib/td) (Boost Software License 1.0)
- [TDLibKit](https://github.com/Swiftgram/TDLibKit) (MIT)
- [GRDB.swift](https://github.com/groue/GRDB.swift) (MIT)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (MIT)

## License

[MIT](LICENSE)
