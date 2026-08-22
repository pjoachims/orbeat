import SwiftUI
import ActivityKit
import UserNotifications
import UIKit

@main
struct OrbeatApp: App {
    @StateObject private var model = RideModel()
    var body: some Scene {
        WindowGroup { ContentView(model: model) }
    }
}

struct ContentView: View {
    @ObservedObject var model: RideModel
    @State private var ble: BLEManager?
    @State private var activity: Activity<OrbeatAttributes>?
    @State private var showDevices = false
    /// Vibrate/notify every N seconds while over threshold; 0 = off.
    @AppStorage("vibrateEvery") private var vibrateEvery = 10
    @State private var lastBuzz = Date.distantPast
    @State private var lastActivityPush = Date.distantPast
    @State private var lastEndedID: String?
    @Environment(\.scenePhase) private var scenePhase

    private var state: OrbeatAttributes.ContentState {
        .init(bpm: model.isFresh ? model.bpm : 0,
              watts: model.displayWatts,
              cadence: model.displayCadence,
              over: model.overThreshold)
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(model.zoneColor)
                    Text(model.bpmText)
                        .font(.system(size: 76, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Text(model.hasData && model.isFresh ? model.zone : model.bleStatus)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 32) {
                metric("bolt.fill", model.displayWatts.map { "\($0) W" } ?? "–– W")
                metric("arrow.clockwise", model.displayCadence.map { "\($0) rpm" } ?? "–– rpm")
            }
            Spacer()
            Button {
                activity == nil ? startActivity() : endActivity()
            } label: {
                Text(activity == nil ? "Show in Dynamic Island" : "Hide from Dynamic Island")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            HStack(spacing: 8) {
                Text("Alert at")
                TextField("off", value: Binding(
                    get: { model.threshold == 0 ? nil : model.threshold },
                    set: { model.threshold = $0 ?? 0 }
                ), format: .number)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 64)
                Text("bpm")
                Picker("Vibrate", selection: $vibrateEvery) {
                    Text("No vibration").tag(0)
                    ForEach([5, 10, 30, 60], id: \.self) { Text("Vibrate \($0)s").tag($0) }
                }
                .tint(.secondary)
            }
            .foregroundStyle(.secondary)
            Button("Connect Equipment") { showDevices = true }
                .font(.subheadline)
            Text(model.sourceName)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .sheet(isPresented: $showDevices) { DeviceSheet(ble: ble, model: model) }
        .preferredColorScheme(.dark)
        .onAppear {
            startActivity()
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        .task { await feed() }
        .task { await alertLoop() }
        // Event-driven Live Activity updates: fires on every reading, so it also
        // runs on background BLE wakeups where a sleep-loop would be suspended.
        .onReceive(model.$lastSync) { _ in
            guard let a = activity,
                  Date().timeIntervalSince(lastActivityPush) >= 2 else { return }
            lastActivityPush = Date()
            let content = ActivityContent(state: state, staleDate: .now + 60)
            Task { await a.update(content) }
        }
        // Recreate after the user swiped the island away — the old handle keeps
        // accepting updates that render nowhere.
        .onChange(of: scenePhase) { _, p in
            guard p == .active, let a = activity, a.activityState != .active else { return }
            activity = nil
            startActivity()
        }
    }

    private func metric(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.title3.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    private func startActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Adopt a survivor from a previous run instead of stacking a duplicate —
        // orphans keep rendering old data while updates go to the new activity.
        // Never adopt one that is ending (or just ended via the Hide button):
        // it disappears moments later while the app thinks it's showing.
        var adopted: Activity<OrbeatAttributes>?
        for a in Activity<OrbeatAttributes>.activities {
            if adopted == nil, a.activityState == .active, a.id != lastEndedID {
                adopted = a
            } else {
                Task { await a.end(nil, dismissalPolicy: .immediate) }
            }
        }
        activity = adopted ?? (try? Activity.request(
            attributes: OrbeatAttributes(),
            content: .init(state: state, staleDate: .now + 60)))
    }

    private func endActivity() {
        let a = activity
        activity = nil
        lastEndedID = a?.id
        Task { await a?.end(nil, dismissalPolicy: .immediate) }
    }

    /// While over threshold, buzz every `vibrateEvery` seconds. Foreground →
    /// haptic; background (BLE keeps us alive) → time-sensitive notification.
    private func alertLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard model.overThreshold, vibrateEvery > 0,
                  Date().timeIntervalSince(lastBuzz) >= Double(vibrateEvery) else { continue }
            lastBuzz = Date()
            if UIApplication.shared.applicationState == .active {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            } else {
                let c = UNMutableNotificationContent()
                c.title = "Heart rate high"
                c.body = "\(model.bpm) bpm — over your \(model.threshold) bpm limit"
                c.sound = .default
                c.interruptionLevel = .timeSensitive
                try? await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
            }
        }
    }

    /// Real sensors on device; simulated ride on the simulator (no BLE there).
    private func feed() async {
        #if targetEnvironment(simulator)
        model.setLive(true, source: "Simulated ride")
        var bpm = 128.0, watts = 210.0
        while !Task.isCancelled {
            bpm = min(174, max(96, bpm + .random(in: -4...5)))
            watts = min(340, max(140, watts + .random(in: -14...14)))
            model.ingest(Int(bpm))
            model.watts = Int(watts)
            model.cadence = Int.random(in: 84...96)
            try? await Task.sleep(for: .seconds(1.1))
        }
        #else
        guard ble == nil else { return }
        let manager = BLEManager()
        manager.onEvent = { [weak self] event in
            guard let self else { return }
            self.apply(event, to: self.model)
        }
        ble = manager
        #endif
    }

    /// Map component events onto the shared model (composition root).
    private func apply(_ event: BLEEvent, to model: RideModel) {
        switch event {
        case .status(let s): model.bleStatus = s
        case .heartLinkUp(let device): model.setLive(true, source: device)
        case .heartLinkDown: model.setLive(false, source: "Disconnected")
        case .powerLinkUp(let device): model.powerSource = device
        case .powerLinkDown:
            model.watts = nil
            model.cadence = nil
            model.speedKmh = nil
            model.powerSource = ""
        case .heartRate(let r):
            if r.bpm > 0 { model.ingest(r.bpm) }
        case .power(let p):
            model.watts = p.watts
            model.touch()
            model.speedKmh = p.kmh
            model.cadence = p.cadence
        case .handlebar, .trainerReady, .trainerLost:
            break   // no trainer UI on iOS yet
        }
    }
}

/// Discovered-sensor list — the iOS stand-in for the macOS "Connect Equipment" menu.
struct DeviceSheet: View {
    let ble: BLEManager?
    @ObservedObject var model: RideModel
    // ponytail: 1s tick re-reads ble.discovered (not observable); fine for a settings sheet
    @State private var tick = 0
    @State private var scanAll = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                let _ = tick
                if let ble {
                    Section(footer: Text("Other devices (Zwift, Apple TV, another Mac) can pair with “Orbeat” as a heart-rate/power sensor.")) {
                        Toggle("Share sensors via Bluetooth", isOn: Binding(
                            get: { ble.rebroadcaster.enabled },
                            set: { ble.rebroadcaster.enabled = $0; tick += 1 }))
                    }
                    Section(footer: Text(model.bleStatus)) {
                        if ble.discovered.isEmpty {
                            Label("Scanning for heart-rate straps and power meters…",
                                  systemImage: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(ble.discovered.filter(\.isSensor), id: \.peripheral.identifier) { d in
                            row(ble, d)
                        }
                    }
                    if scanAll {
                        Section("All nearby devices") {
                            let others = ble.discovered.filter { !$0.isSensor }
                            if others.isEmpty {
                                Label("Searching everything nearby…", systemImage: "magnifyingglass")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(others, id: \.peripheral.identifier) { d in
                                row(ble, d)
                            }
                        }
                    }
                } else {
                    Text("No Bluetooth on the simulator — run on a real iPhone.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connect Equipment")
            .toolbar {
                Button {
                    scanAll.toggle()
                    ble?.setScanAll(scanAll)
                } label: {
                    Image(systemName: scanAll ? "xmark.circle" : "plus")
                }
            }
            .onReceive(timer) { _ in tick += 1 }
            .onDisappear { ble?.setScanAll(false) }
        }
    }

    private func row(_ ble: BLEManager, _ d: BLEManager.Device) -> some View {
        Button { ble.connect(d) } label: {
            HStack {
                Image(systemName: d.isSensor ? (d.isPower ? "bolt.fill" : "heart.fill")
                                             : "questionmark.circle")
                    .foregroundStyle(d.isSensor ? (d.isPower ? .yellow : .red) : .secondary)
                VStack(alignment: .leading) {
                    Text(d.name).foregroundStyle(.primary)
                    if ble.isKnown(d) {
                        Text("Auto-connects").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if ble.isConnected(d) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        }
        .swipeActions {
            if ble.isKnown(d) {
                Button("Forget", role: .destructive) { ble.forget(d) }
            }
        }
    }
}
