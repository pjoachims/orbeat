#!/bin/bash
# Runs the component tests without Xcode: compiles Core types + pure component
# files against Tests/, executes the binary. RideModel is excluded (drags in
# SwiftUI); BLE transport code needs hardware and stays untested by design.
set -euo pipefail
cd "$(dirname "$0")"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swiftc -O \
  Sources/Core/Sensors.swift \
  Sources/Core/TrainerMode.swift \
  Sources/Core/RideButtons.swift \
  Sources/Components/Ergs/CyclingPower.swift \
  Sources/Components/Ergs/FtmsIndoorBike.swift \
  Sources/Components/HeartRate/HeartRateParse.swift \
  Sources/Components/BLE/Zwift/ZwiftButtonFrame.swift \
  Sources/Components/BLE/Zwift/ZwiftRideController.swift \
  Tests/Harness.swift \
  Tests/ErgsTests.swift \
  Tests/TrainerModeTests.swift \
  Tests/ZwiftTests.swift \
  Tests/main.swift \
  -o "$OUT/orbeat-tests"

"$OUT/orbeat-tests"
