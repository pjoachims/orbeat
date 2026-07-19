# Orbeat

macOS menu-bar heart-rate monitor with an iOS companion (widget + Live Activity).

- Menu-bar BPM display with popover and floating panel (SwiftUI/AppKit)
- Bluetooth LE heart-rate rebroadcast (CoreBluetooth)
- Ships with a simulated signal; real Fitbit Web API integration is a stub in `Sources/Fitbit.swift`

## Build (macOS)

```sh
./build.sh
open Orbeat.app
```

## iOS

Project generated from `ios/project.yml` (XcodeGen); open `ios/Orbeat.xcodeproj`.
