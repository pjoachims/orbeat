import SwiftUI
import Charts

/// Start/stop row: elapsed clock while a session records here or on the
/// peer (stop works for both), start button otherwise.
struct SessionBar: View {
    let core: AppCore
    @ObservedObject var store: SessionStore
    @ObservedObject var model: RideModel   // peer's recording clock
    var compact = false
    @State private var confirmStop = false

    var body: some View {
        HStack(spacing: 8) {
            if let rec = core.recording {
                VStack(alignment: .leading, spacing: 3) {
                    Eyebrow(text: rec.isPaused ? "Paused"
                            : store.active.map { "Session · \($0.samples.count) samples" }
                            ?? "Recording on \(PeerLink.peerLabel)")
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(clock(rec.elapsed(at: ctx.date)))
                            .font(.system(size: compact ? 18 : 22, weight: .semibold))
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(Tile(padding: compact ? 10 : 14))
                Button { core.setPaused(!rec.isPaused) } label: {
                    Image(systemName: rec.isPaused ? "play.fill" : "pause.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, compact ? 14 : 18)
                        .padding(.vertical, compact ? 15 : 20)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(rec.isPaused ? "Resume" : "Pause")
                Button { confirmStop = true } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, compact ? 14 : 18)
                        .padding(.vertical, compact ? 15 : 20)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(orbeatRed.opacity(0.2)))
                        .foregroundStyle(orbeatRed)
                }
                .buttonStyle(.plain)
            } else {
                action("Start session", "record.circle") { core.startSession() }
            }
        }
        .confirmationDialog("Stop and save this session?", isPresented: $confirmStop) {
            Button("Stop session", role: .destructive) { core.stopSession() }
        }
    }

    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, compact ? 10 : 13)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.primary.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

func clock(_ t: TimeInterval) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

/// Sessions tab: the live session bar (here or on the peer), a link to the
/// running session's charts, then totals and history.
struct SessionsTab: View {
    let core: AppCore
    @ObservedObject var store: SessionStore
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            history
                .navigationDestination(for: UUID.self) { id in
                    if id == store.active?.id {
                        LiveSessionDetail(store: store)
                    } else if let s = store.past.first(where: { $0.id == id }) {
                        SessionDetail(session: s)
                            .toolbar {
                                if core.recording == nil {
                                    Button { core.continueSession(s) } label: {
                                        Label("Continue", systemImage: "record.circle")
                                    }
                                }
                            }
                    }
                }
                // Stopped (here or from the other device): leave the live view.
                .onChange(of: store.active?.id) { old, _ in path.removeAll { $0 == old } }
        }
    }

    private var history: some View {
        let week = store.past.filter { $0.start > Date().addingTimeInterval(-7 * 86400) }
        let weekTime = week.reduce(0) { $0 + $1.duration }
        let weekBPM = week.compactMap(\.avgBPM)
        return List {
            Section {
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible())], spacing: 8) {
                    MetricTile(label: "This week", value: clock(weekTime))
                    MetricTile(label: "Sessions", value: "\(week.count)")
                    MetricTile(label: "Avg bpm",
                               value: weekBPM.isEmpty ? "––" : "\(weekBPM.reduce(0, +) / weekBPM.count)")
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                SessionBar(core: core, store: store, model: core.model)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                if let a = store.active {
                    NavigationLink(value: a.id) {
                        Label("Live charts", systemImage: "waveform.path.ecg")
                    }
                }
            }
            Section("History") {
                if store.past.isEmpty {
                    Text("No sessions yet.").foregroundStyle(.secondary)
                }
                ForEach(store.past) { s in
                    NavigationLink(value: s.id) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.start, format: .dateTime.weekday(.wide).day().month().hour().minute())
                            HStack(spacing: 12) {
                                Text(clock(s.duration)).monospacedDigit()
                                if let b = s.avgBPM { Label("\(b)", systemImage: "heart.fill") }
                                if let w = s.avgWatts { Label("\(w)", systemImage: "bolt.fill") }
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in idx.map { store.past[$0] }.forEach(store.delete) }
            }
        }
        .navigationTitle("Sessions")
    }
}

/// The running session's charts. Observes the store itself (a pushed
/// navigation destination doesn't reliably refresh from its parent), so
/// clock and charts follow each 1 Hz sample.
struct LiveSessionDetail: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        if let s = store.active {
            SessionDetail(session: s)
                .navigationTitle("Recording · \(clock(store.elapsed))")
        }
    }
}

/// Stats + heart-rate / power over time.
struct SessionDetail: View {
    let session: Session
    /// Moving-average window in seconds, 0 = raw.
    @AppStorage("chartSmoothing") private var window = 30.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible())], spacing: 8) {
                    MetricTile(label: "Time", value: clock(session.duration))
                    MetricTile(label: "Avg bpm", value: session.avgBPM.map { "\($0)" } ?? "––")
                    MetricTile(label: "Max bpm", value: session.maxBPM.map { "\($0)" } ?? "––")
                    if session.avgWatts != nil {
                        MetricTile(label: "Avg W", value: "\(session.avgWatts!)")
                        MetricTile(label: "Max W", value: "\(session.maxWatts!)")
                        MetricTile(label: "km", value: String(format: "%.1f", session.distanceKm))
                    }
                }
                Picker("Smoothing", selection: $window) {
                    Text("Raw").tag(0.0)
                    Text("10 s").tag(10.0)
                    Text("30 s").tag(30.0)
                    Text("1 min").tag(60.0)
                }
                .pickerStyle(.segmented)
                if !session.bpms.isEmpty {
                    Eyebrow(text: "Heart rate")
                    Chart(curve(\.bpm), id: \.t) { p in
                        LineMark(x: .value("min", p.t / 60), y: .value("bpm", p.v))
                            .foregroundStyle(orbeatRed)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 160)
                    zones
                }
                if !session.wattsAll.isEmpty {
                    Eyebrow(text: "Power")
                    Chart(curve(\.watts), id: \.t) { p in
                        LineMark(x: .value("min", p.t / 60), y: .value("W", p.v))
                            .foregroundStyle(.yellow)
                    }
                    .frame(height: 160)
                }
            }
            .padding(22)
        }
        .navigationTitle(session.start.formatted(date: .abbreviated, time: .shortened))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Smoothed over the full-res samples, then thinned so charts stay cheap.
    private func curve(_ metric: KeyPath<Session.Sample, Int?>) -> [Curve.Point] {
        let pts = session.samples.compactMap { s in s[keyPath: metric].map { Curve.Point(t: s.t, v: Double($0)) } }
        return Curve.thin(Curve.smooth(pts, window: window))
    }

    /// Time-in-zone bar, one segment per zone.
    private var zones: some View {
        let z = session.zoneSeconds.filter { $0.seconds > 0 }
        let total = max(1, z.reduce(0) { $0 + $1.seconds })
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(z, id: \.zone) { e in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(zoneColor(e.zone))
                            .frame(width: g.size.width * CGFloat(e.seconds) / CGFloat(total))
                    }
                }
            }
            .frame(height: 10)
            HStack(spacing: 12) {
                ForEach(z, id: \.zone) { e in
                    HStack(spacing: 4) {
                        Circle().fill(zoneColor(e.zone)).frame(width: 6, height: 6)
                        Text("\(e.zone) \(clock(TimeInterval(e.seconds)))")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func zoneColor(_ name: String) -> Color {
        switch name {
        case "Resting": return rideZoneColor(50)
        case "Fat Burn": return rideZoneColor(80)
        case "Cardio": return rideZoneColor(120)
        default: return rideZoneColor(160)
        }
    }
}
