# Orbeat

macOS menu-bar heart-rate monitor with an iOS companion (widget + Live Activity).

- Menu-bar BPM display with popover and floating panel (SwiftUI/AppKit)
- Bluetooth LE heart-rate rebroadcast (CoreBluetooth)
- Trainer difficulty from Zwift Ride controls (see below)
- Ships with a simulated signal; real Fitbit Web API integration is a stub in `Sources/Fitbit.swift`

## Trainer control (Zwift Ride → KICKR)

No Zwift needed — Orbeat is the controller. It connects to a KICKR (or any
FTMS trainer) and to a Zwift Ride / Zwift Play handlebar controller, and the
shifter paddles set the trainer's ERG target power: **shift up = +5 W,
shift down = −5 W** (clamped 30–600 W, persisted). Fallback while testing:
right-click the menu-bar icon → **Harder / Easier** once the trainer connects.

Both pair through **Connect Equipment** in the right-click menu; the Ride
controller shows as `— Controller`. Protocol (plaintext, no crypto) reverse-
engineered from [qdomyos-zwift](https://github.com/cagnulein/qdomyos-zwift):
Zwift Ride `0x23` button-bitmap frames, FTMS `0x2AD9` set-target-power.

Verified: compiles, and the button-bitmap decode passes unit tests. **Not yet
tested on hardware** — if a KICKR ignores FTMS control it may need the Wahoo
proprietary path (noted in `Sources/Bluetooth.swift`).

## Build

One XcodeGen project (`project.yml`) for Mac, iOS and the widget; `Orbeat.xcodeproj` is generated, not committed.
Signing needs your Apple ID in Xcode → Settings → Accounts (iCloud entitlements need provisioning profiles).

```sh
./build.sh              # Mac → ./Orbeat.app
ios/deploy.sh [name]    # build + install + launch on a paired iPhone
./test.sh               # decoder/driver/wire tests
```

## Sync between Mac and iPhone

- **Live**: Mac hosts a custom GATT service (`PeerLink.swift`), iPhone connects as central (survives backgrounding).
  Each side sends only readings from sensors it is connected to directly (`PeerWire`), so nothing echoes.
  Sensors can be on either device; the other mirrors them. Trainer steps / mode changes / session stop are routed to whichever device owns the trainer or session.
- **History**: SwiftData in `Application Support/Orbeat/sessions.store`, synced via CloudKit (`iCloud.com.vibecode.orbeat`).
  An old `Documents/sessions.json` is imported once and renamed `.imported`.
- **Settings**: alert threshold via iCloud key-value store.
- "Share sensors via Bluetooth" still rebroadcasts to third-party apps (Zwift etc.).

## DuckDB logging

Right-click the menu-bar icon → **Log to DuckDB (JSONL)**. While on, every BLE
packet is appended to `~/Library/Application Support/Orbeat/orbeat.jsonl` — one row per packet,
`src: "hr"` (bpm, and rr_ms/contact/kj when the strap sends them) or
`src: "pwr"` (watts, rpm, kmh, raw wheel/crank counters, torque/balance when sent).
Query it live:

```sh
brew install duckdb
duckdb -c "SELECT * FROM read_json_auto('$HOME/Library/Application Support/Orbeat/orbeat.jsonl')"
```

Or keep a persistent view in a database:

```sql
CREATE VIEW orbeat AS SELECT * FROM read_json_auto('~/Library/Application Support/Orbeat/orbeat.jsonl');
```

Re-running a query re-reads the file, so results always include the latest samples.

## iOS

Same live card, sessions, trainer control; plus Dynamic Island / Live Activity and background alerts.
