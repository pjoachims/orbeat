import SwiftUI
import ActivityKit
import UserNotifications
import UIKit

@main
struct OrbeatApp: App {
    @StateObject private var model = RideModel()
    @StateObject private var store = SessionStore()
    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView(model: model, store: store)
                    .tabItem { Label("Live", systemImage: "heart.fill") }
                SessionsTab(store: store)
                    .tabItem { Label("Sessions", systemImage: "chart.xyaxis.line") }
            }
            .preferredColorScheme(.dark)
            // Root-level: a tab's own .task is cancelled when it's switched away.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    store.tick(model)
                }
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: RideModel
    @State private var ble: BLEManager?
    @StateObject private var recorder = Recorder()
    @ObservedObject var store: SessionStore
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

    private var live: Bool { model.hasData && model.isFresh }
    private var zone: Color { live ? rideZoneColor(model.bpm) : .secondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // top bar
            HStack(alignment: .firstTextBaseline) {
                Text("ORBEAT").font(.system(size: 12, weight: .bold)).kerning(2.2)
                Spacer()
                LiveDot(live: model.isFresh)
            }
            Text(model.hasData ? model.sourceName : model.bleStatus)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.top, 3)

            Spacer(minLength: 12)

            // hero
            HStack(alignment: .center, spacing: 10) {
                BeatingHeart(bpm: model.bpm, live: live, size: 32, color: zone)
                    .padding(.top, 8)   // glyph box centre sits a touch above the digits' centre
              HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(model.bpmText)
                    .font(.system(size: 116, weight: .semibold))
                    .monospacedDigit()
                    .kerning(-6)
                    .contentTransition(.numericText())
                    .animation(.spring(duration: 0.4), value: model.bpm)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
                Text("BPM")
                    .font(.system(size: 15, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 20)
              }
            }
            ZoneChip(model: model)

            Sparkline(history: model.history, tint: zone)
                .frame(height: 84)
                .padding(.top, 18)
                .opacity(live ? 1 : 0.35)

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                MetricTile(label: "Watts", value: wattsTxt, valueSize: 26, padding: 14)
                MetricTile(label: "RPM", value: cadenceTxt, valueSize: 26, padding: 14)
                MetricTile(label: "km/h", value: speedTxt, valueSize: 26, padding: 14)
            }
            if model.trainerControllable {
                TrainerStepper(mode: model.trainerMode, padding: 14) { applyRidePress([$0]) }
                    .padding(.top, 8)
            }

            SessionBar(store: store)
                .padding(.top, 8)

            Spacer(minLength: 16)

            // alert
            HStack(spacing: 10) {
                Text("Alert at").foregroundStyle(.secondary)
                TextField("off", value: Binding(
                    get: { model.threshold == 0 ? nil : model.threshold },
                    set: { model.threshold = $0 ?? 0 }
                ), format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
                    .frame(width: 56)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.primary.opacity(0.08)))
                Text("bpm").foregroundStyle(.secondary)
                Spacer()
                Picker("Vibrate", selection: $vibrateEvery) {
                    Text("No buzz").tag(0)
                    ForEach([5, 10, 30, 60], id: \.self) { Text("Buzz \($0)s").tag($0) }
                }
                .tint(.secondary)
                .fixedSize()
            }
            .font(.subheadline)
            .padding(.bottom, 6)

            // Same JSONL as the Mac app (one line per BLE packet, "t" ISO ms).
            HStack(spacing: 10) {
                Toggle(isOn: $recorder.recording) {
                    Label("Log ride", systemImage: "record.circle")
                        .foregroundStyle(recorder.recording ? orbeatRed : .secondary)
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                Spacer()
                ShareLink(item: Recorder.logURL) {
                    Label("orbeat.jsonl", systemImage: "square.and.arrow.up")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .font(.subheadline)
            .padding(.bottom, 10)

            HStack(spacing: 8) {
                action(activity == nil ? "Dynamic Island" : "Hide Island",
                       activity == nil ? "circle.dashed" : "circle.dashed.inset.filled") {
                    activity == nil ? startActivity() : endActivity()
                }
                action("Equipment", "antenna.radiowaves.left.and.right") { showDevices = true }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color(red: 0.043, green: 0.043, blue: 0.059).ignoresSafeArea())
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

    private var wattsTxt: String { model.displayWatts.map { "\($0)" } ?? "––" }
    private var cadenceTxt: String { model.displayCadence.map { "\($0)" } ?? "––" }
    private var speedTxt: String { model.displaySpeedKmh.map { String(format: "%.1f", $0) } ?? "––" }

    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
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
        model.trainerControllable = true
        model.trainerMode = .sim(grade: model.grade)
        var bpm = 128.0, watts = 210.0
        while !Task.isCancelled {
            bpm = min(174, max(96, bpm + .random(in: -4...5)))
            watts = min(340, max(140, watts + .random(in: -14...14)))
            model.ingest(Int(bpm))
            model.watts = Int(watts)
            model.cadence = Int.random(in: 84...96)
            model.speedKmh = watts / 6.4
            try? await Task.sleep(for: .seconds(1.1))
        }
        #else
        guard ble == nil else { return }
        let manager = BLEManager(log: recorder)
        manager.onEvent = { [model] in model.apply($0, ble: manager) }
        ble = manager
        #endif
    }

    private func applyRidePress(_ inputs: [HandlebarInput]) { model.press(inputs, ble: ble) }
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
                            get: { ble.proxy.enabled },
                            set: { ble.proxy.enabled = $0; tick += 1 }))
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
                Image(systemName: d.isRide ? "gamecontroller.fill"
                                  : d.isSensor ? (d.isPower ? "bolt.fill" : "heart.fill")
                                  : "questionmark.circle")
                    .foregroundStyle(d.isRide ? .blue
                                     : d.isSensor ? (d.isPower ? .yellow : .red) : .secondary)
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
