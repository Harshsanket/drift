# Drift

A lightweight, native macOS BitTorrent client built with Swift 6, SwiftUI,
and Apple's native frameworks, powered by the qBittorrent Web API.
The transfers themselves always run in qBittorrent — Drift is the
efficient native frontend.

**Status:** 1.0 (2026-10-14) — core daily-use client: torrent list,
details (trackers/peers/files with per-file priorities), add via
magnet/link/.torrent, start/stop/pause/remove, category & tag filters,
settings, connection management, menu bar status item with controls,
tiered background sync, and an optional sleep-prevention toggle.

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon (ARM64)
- A qBittorrent instance with its **Web UI enabled** (tested against
  qBittorrent 5.2.x; API 2.17)

## Build

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build --arch arm64
./Scripts/package-dev-app.sh        # → .build/Drift.app
open .build/Drift.app
```

Run the unit suite:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --arch arm64
```

Release artifact (ad-hoc sealed locally; see Limitations):

```sh
./Scripts/package-release-app.sh    # → dist/Drift-1.0.0-arm64.dmg
```

## First run

Drift opens the connection sheet on first launch — point it at your
qBittorrent Web UI URL and credentials (stored in the Keychain).

## Highlights

- **Native SwiftUI** — no web views, no Electron, SF Symbols only.
- **One poller, tiered** — window visible: server cadence; hidden with
  the menu bar item on: 3 s summary; both off: sync suspends entirely
  (menu bar item reappears on wake/relay).
- **Menu bar status item** — live download speed, speeds/counts/
  progress, Open / Pause All / Resume All / Settings / Quit; can be
  hidden from Settings → General.
- **Sleep prevention (opt-in, default OFF)** — while transfers are
  actually moving, holds a single named IOPM assertion; releases on
  inactivity, on toggle-off, and on quit. Never blocks display sleep,
  Apple-menu Sleep, or closing the lid.
- **Honest about limits** — system sleep still pauses transfers;
  quitting Drift ends its sleep-prevention assertion (the daemon keeps
  running either way).

## Limitations (1.0)

- **Not notarized** — this build is ad-hoc signed; Gatekeeper will
  block it on other Macs until it is signed with a Developer ID and
  notarized. Run locally or right-click → Open.
- No app icon yet (system generic icon).
- RSS/search/advanced per-torrent settings are post-1.0 backlog.
- Localization: English only.

## Development

Internal phase documentation and benchmarks live in `docs-internal/`
and `benchmarks/` (not published). Commit convention: one phase per
commit, message `Phase N: …`. Headless/test runs pass backend
credentials via the `DRIFT_TEST_PASSWORD` environment variable (never
hard-coded).
