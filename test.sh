#!/bin/bash
# Runs the component tests without Xcode: compiles Core types + pure component
# files against Tests/, executes the binary. RideModel is excluded (drags in
# SwiftUI); BLE transport code needs hardware and stays untested by design.
set -euo pipefail
cd "$(dirname "$0")"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swiftc -O \
  Sources/Core/Readings.swift \
  Sources/Core/SensorEvent.swift \
  Sources/Core/TrainerMode.swift \
  Sources/Core/RideButtons.swift \
  Sources/Drivers/Standard/CyclingPower.swift \
  Sources/Drivers/Standard/FtmsIndoorBike.swift \
  Sources/Drivers/Standard/HeartRateParse.swift \
  Sources/Drivers/Zwift/ZwiftButtonFrame.swift \
  Sources/Drivers/Zwift/ButtonDecoder.swift \
  Tests/Harness.swift \
  Tests/ErgsTests.swift \
  Tests/TrainerModeTests.swift \
  Tests/ZwiftTests.swift \
  Tests/main.swift \
  -o "$OUT/orbeat-tests"

"$OUT/orbeat-tests"
