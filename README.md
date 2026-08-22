# Orbeat

macOS menu-bar heart-rate monitor with an iOS companion (widget + Live Activity).

- Menu-bar BPM display with popover and floating panel (SwiftUI/AppKit)
- Bluetooth LE heart-rate rebroadcast (CoreBluetooth)
- Trainer difficulty from Zwift Ride controls (see below)
- Ships with a simulated signal; real Fitbit Web API integration is a stub in `Sources/Fitbit.swift`

## Trainer control (Zwift Ride → KICKR)

No Zwift needed — Orbeat is the controller. It connects to a KICKR (or any
FTMS trainer) and to a Zwift Ride / Zwift Play handlebar controller, and the
shifter paddles set the trainer's ERG target power: **shift up = +10 W,
shift down = −10 W** (clamped 30–600 W, persisted). Fallback while testing:
right-click the menu-bar icon → **Harder / Easier** once the trainer connects.

Both pair through **Connect Equipment** in the right-click menu; the Ride
controller shows as `— Controller`. Protocol (plaintext, no crypto) reverse-
engineered from [qdomyos-zwift](https://github.com/cagnulein/qdomyos-zwift):
Zwift Ride `0x23` button-bitmap frames, FTMS `0x2AD9` set-target-power.

Verified: compiles, and the button-bitmap decode passes unit tests. **Not yet
tested on hardware** — if a KICKR ignores FTMS control it may need the Wahoo
proprietary path (noted in `Sources/Bluetooth.swift`).

## Build (macOS)

```sh
./build.sh
open Orbeat.app
```

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

Project generated from `ios/project.yml` (XcodeGen); open `ios/Orbeat.xcodeproj`.
