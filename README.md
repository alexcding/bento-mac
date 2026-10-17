# Bento

A native Mac app that collects posts from social media and RSS around the clock, translates and
summarizes them with an AI CLI, forwards them to Discord and Telegram, and syncs everything through
iCloud. An iOS reader follows later. See [docs/PLAN.md](docs/PLAN.md).

Status: early development (phase 1).

## Layout

```
Apps/        macOS app (Bento.xcodeproj): app entry, collector service, menu bar, Collector window
Packages/    BentoData (schema, sync; BentoCollectorClient is Mac only), BentoUI (shared SwiftUI)
services/    Rust workspace: bento-collector daemon
docs/        plan
```

## Build

Requirements: Xcode 26+, Rust (`brew install rustup && rustup default stable`).

```sh
open Apps/Bento.xcodeproj
```

`Apps/Bento` is a synchronized folder, so new files there join the app target without editing the
project. The `BentoCollector` target has no Swift sources: its build phase runs
`Apps/Scripts/embed-collector.sh`, which builds the daemon and plugins with cargo, and the app embeds
it as `Contents/Helpers/BentoCollector.app` so it can be signed with the keychain access group that
puts secrets in iCloud Keychain. The app target also bundles `plugins/` as resources and copies the
LaunchAgent plist into `Contents/Library/LaunchAgents`.

The default build is ad-hoc signed with iCloud sync off. To sign with your team and turn on sync,
copy `Apps/Config/Local.xcconfig.template` to `Apps/Config/Local.xcconfig` and fill it in.

## Test

```sh
(cd services && cargo test --workspace && cargo build -p bento-collector)
(cd Packages/BentoData && swift test)
(cd Packages/BentoUI && swift test)
```

`services/testdata/` holds vectors and fixtures that both the Rust and Swift tests check, so the
two sides cannot drift apart.

## License

MIT
