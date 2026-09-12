import SwiftUI
import Charts

/// Start/stop row on the main screen: elapsed clock while recording,
/// history button otherwise.
struct SessionBar: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        HStack(spacing: 8) {
            if let s = store.active {
                VStack(alignment: .leading, spacing: 3) {
                    Eyebrow(text: "Session · \(s.samples.count) samples")
                    Text(clock(store.elapsed))
                        .font(.system(size: 22, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(Tile(padding: 14))
                Button { store.stop() } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 20)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(orbeatRed.opacity(0.2)))
                        .foregroundStyle(orbeatRed)
                }
                .buttonStyle(.plain)
            } else {
                action("Start session", "record.circle") { store.start() }
            }
        }
    }

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
}

func clock(_ t: TimeInterval) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

/// Sessions tab: the running session's KPIs and charts while recording,
/// otherwise totals plus the history list.
struct SessionsTab: View {
    @ObservedObject var store: SessionStore
    // ponytail: charts redraw from a 5 s snapshot, not every 1 Hz sample —
    // only the clock in the title ticks per second.
    @State private var snapshot: Session?
    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Group {
                if store.active != nil, let s = snapshot ?? store.active {
                    SessionDetail(session: s)
                        .navigationTitle("Recording · \(clock(store.elapsed))")
                        .toolbar {
                            Button("Stop", systemImage: "stop.fill") { store.stop() }
                                .tint(orbeatRed)
                        }
                } else {
                    history
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let s = store.past.first(where: { $0.id == id }) { SessionDetail(session: s) }
            }
            .onReceive(refresh) { _ in snapshot = store.active }
            .onChange(of: store.active == nil) { _, _ in snapshot = store.active }
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
                Button { store.start() } label: {
                    Label("Start session", systemImage: "record.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
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

/// Stats + heart-rate / power over time.
struct SessionDetail: View {
    let session: Session

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
                if !session.bpms.isEmpty {
                    Eyebrow(text: "Heart rate")
                    Chart(thin(session.samples.filter { $0.bpm != nil }), id: \.t) { s in
                        LineMark(x: .value("min", s.t / 60), y: .value("bpm", s.bpm!))
                            .foregroundStyle(orbeatRed)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 160)
                    zones
                }
                if !session.wattsAll.isEmpty {
                    Eyebrow(text: "Power")
                    Chart(thin(session.samples.filter { $0.watts != nil }), id: \.t) { s in
                        LineMark(x: .value("min", s.t / 60), y: .value("W", s.watts!))
                            .foregroundStyle(.yellow)
                    }
                    .frame(height: 160)
                }
            }
            .padding(22)
        }
        .navigationTitle(session.start.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Keep charts cheap: at most ~600 points, every n-th sample.
    private func thin(_ xs: [Session.Sample]) -> [Session.Sample] {
        let n = max(1, xs.count / 600)
        return n == 1 ? xs : xs.enumerated().filter { $0.offset % n == 0 }.map(\.element)
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
