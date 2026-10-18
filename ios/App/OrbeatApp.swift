import SwiftUI
import ActivityKit
import UserNotifications
import UIKit
import UniformTypeIdentifiers

@main
struct OrbeatApp: App {
    @StateObject private var core = AppCore()
    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView(core: core, model: core.model, store: core.store, recorder: core.recorder)
                    .tabItem { Label("Live", systemImage: "heart.fill") }
                SessionsTab(core: core, store: core.store)
                    .tabItem { Label("Sessions", systemImage: "chart.xyaxis.line") }
            }
            .preferredColorScheme(.dark)
            .onOpenURL { core.open($0) }   // .gpx from Files/share sheet, orbeat://ride?gpx=
        }
    }
}

struct ContentView: View {
    let core: AppCore
    @ObservedObject var model: RideModel
    @ObservedObject var store: SessionStore
    @ObservedObject var recorder: Recorder
    private var ble: BLEManager? { core.ble }
    @State private var activity: Activity<OrbeatAttributes>?
    @State private var showDevices = false
    @State private var pendingRoute: URL?
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
                PeerBadge(model: model)
                LiveDot(live: model.isFresh)
                Button { showDevices = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
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
            if let route = model.route {
                RouteCard(route: route, meters: model.routeMeters, padding: 14) { core.ride(nil) }
                    .padding(.top, 8)
            }
            if model.trainerControllable {
                TrainerStepper(mode: model.trainerMode, padding: 14,
                               onStep: { applyRidePress([$0]) }, onSet: core.setTrainer,
                               hill: model.route == nil)
                    .padding(.top, 8)
            }

            SessionBar(core: core, store: store, model: model)
                .padding(.top, 8)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color(red: 0.043, green: 0.043, blue: 0.059).ignoresSafeArea())
        // Route opens once the sheet is gone: an error alert can't present over it.
        .sheet(isPresented: $showDevices, onDismiss: { pendingRoute.map(core.open); pendingRoute = nil }) {
            SettingsSheet(ble: ble, model: model, recorder: recorder, setRider: core.setRider, openRoute: { pendingRoute = $0 },
                          upload: { store.upload(report: $0) },
                          vibrateEvery: $vibrateEvery,
                          island: Binding(get: { activity != nil },
                                          set: { $0 ? startActivity() : endActivity() }))
        }
        .preferredColorScheme(.dark)
        .alert("Route", isPresented: Binding(get: { model.routeError != nil },
                                             set: { if !$0 { model.routeError = nil } })) {
            Button("OK") {}
        } message: { Text(model.routeError ?? "") }
        .onAppear {
            startActivity()
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
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

    private func applyRidePress(_ inputs: [HandlebarInput]) { inputs.forEach(core.step) }
}

/// Everything set once per ride or less: equipment (the iOS stand-in for the
/// macOS "Connect Equipment" menu), rider, alert, Live Activity, debug log.
struct SettingsSheet: View {
    let ble: BLEManager?
    @ObservedObject var model: RideModel
    @ObservedObject var recorder: Recorder
    let setRider: (Rider) -> Void
    let openRoute: (URL) -> Void
    let upload: (((String) -> Void)?) -> Void
    @Binding var vibrateEvery: Int
    @Binding var island: Bool
    // ponytail: 1s tick re-reads ble.discovered (not observable); fine for a settings sheet
    @State private var tick = 0
    @State private var scanAll = false
    @State private var pickRoute = false
    @AppStorage(RideUpload.urlKey) private var uploadURL = ""
    @State private var uploadToken = RideUpload.token
    @State private var uploadStatus = ""
    @AppStorage(RideUpload.autoKey) private var uploadAuto = true
    @Environment(\.dismiss) private var dismiss
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
                    Section(header: Text("Equipment"), footer: Text(model.bleStatus)) {
                        if ble.discovered.isEmpty {
                            Label("Scanning for heart-rate straps and power meters…",
                                  systemImage: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(ble.discovered.filter(\.isSensor), id: \.peripheral.identifier) { d in
                            row(ble, d)
                        }
                        Toggle("Show all nearby devices", isOn: Binding(
                            get: { scanAll },
                            set: { scanAll = $0; ble.setScanAll($0) }))
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
                }
                Section(header: Text("Rider"),
                        footer: Text("Sent to the trainer for sim and virtual gears, like Zwift. Trainer Difficulty scales climbs; descents are halved first.")) {
                    Stepper("Rider \(model.rider.riderKg) kg", value: riderBinding(\.riderKg), in: Rider.riderRange)
                    Stepper("Bike \(model.rider.bikeKg) kg", value: riderBinding(\.bikeKg), in: Rider.bikeRange)
                    Picker("Trainer Difficulty", selection: riderBinding(\.difficulty)) {
                        ForEach(Rider.difficulties, id: \.self) { Text("\($0) %").tag($0) }
                    }
                }
                Section(footer: Text("Rides a GPX track's hills in sim, at your road speed. Gears stay yours.")) {
                    Button { pickRoute = true } label: {
                        Label("Ride a GPX Route…", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                }
                Section(header: Text("Heart-rate alert"),
                        footer: Text("Vibrates while you're over the limit; a notification when Orbeat is in the background.")) {
                    HStack {
                        Text("Alert at")
                        Spacer()
                        TextField("off", value: Binding(
                            get: { model.threshold == 0 ? nil : model.threshold },
                            set: { model.threshold = $0 ?? 0 }
                        ), format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 60)
                        Text("bpm").foregroundStyle(.secondary)
                    }
                    Picker("Vibrate", selection: $vibrateEvery) {
                        Text("Off").tag(0)
                        ForEach([5, 10, 30, 60], id: \.self) { Text("Every \($0) s").tag($0) }
                    }
                }
                Section {
                    Toggle("Dynamic Island", isOn: $island)
                }
                Section(header: Text("Health backend"),
                        footer: Text("Finished rides go to your own fitbit-air backend.")) {
                    TextField("https://…", text: $uploadURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Token", text: $uploadToken)
                    // Borderless: several buttons in one List row each keep their own tap.
                    HStack(spacing: 20) {
                        Button("Test") {
                            saveToken()
                            uploadStatus = "Testing…"
                            RideUpload.test { uploadStatus = $0 }
                        }
                        Button("Upload") {
                            saveToken()
                            uploadStatus = "Uploading…"
                            upload { uploadStatus = $0 }
                        }
                        Spacer()
                        Toggle("Auto", isOn: $uploadAuto).fixedSize()
                    }
                    .buttonStyle(.borderless)
                    if !uploadStatus.isEmpty { Text(uploadStatus).foregroundStyle(.secondary) }
                }
                // Same JSONL as the Mac app (one line per BLE packet, "t" ISO ms).
                Section(header: Text("Debug")) {
                    Toggle("Log ride", isOn: $recorder.recording)
                    ShareLink(item: Recorder.logURL) {
                        Label("Share orbeat.jsonl", systemImage: "square.and.arrow.up")
                    }
                }
                if ble == nil {
                    Text("No Bluetooth on the simulator — run on a real iPhone.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: $pickRoute, allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml]) {
                guard case .success(let url) = $0 else { return }
                openRoute(url)
                dismiss()
            }
            .onReceive(timer) { _ in tick += 1 }
            .onDisappear {
                ble?.setScanAll(false)
                saveToken()
                if uploadAuto { upload(nil) }
            }
        }
    }

    private func saveToken() {
        if uploadToken != RideUpload.token { RideUpload.token = uploadToken }
    }

    private func riderBinding(_ key: WritableKeyPath<Rider, Int>) -> Binding<Int> {
        Binding(get: { model.rider[keyPath: key] },
                set: { var r = model.rider; r[keyPath: key] = $0; setRider(r) })
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
