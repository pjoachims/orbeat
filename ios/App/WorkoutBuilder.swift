import SwiftUI
import UniformTypeIdentifiers

/// Build a workout on the phone: zone-coloured profile on top (tap it to pick a
/// block), one card below editing that block. The draft is kept between
/// visits; Ride hands it to ERG, Share exports a .zwo.
struct WorkoutBuilder: View {
    /// The rider's FTP from Settings; the plan may override it.
    let riderFTP: Int
    let ride: (Workout) -> Void
    // Loaded on appear: Settings re-renders every second, re-running this init.
    @State private var plan = WorkoutPlan.sample
    @State private var sel = 0
    /// Template waiting for "Replace?": picking one overwrites the draft.
    @State private var replacing: WorkoutPlan?

    private static let key = "workoutPlan"
    private static var saved: WorkoutPlan {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(WorkoutPlan.self, from: $0) } ?? .sample
    }

    private var ftp: Int { plan.ftp ?? riderFTP }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                if plan.blocks.indices.contains(sel) { editor(sel) } else { empty }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(red: 0.043, green: 0.043, blue: 0.059).ignoresSafeArea())
        .navigationTitle("Build Workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    ForEach(WorkoutPlan.templates, id: \.name) { t in Button(t.name) { if plan.blocks.isEmpty { use(t) } else { replacing = t } } }
                } label: { Image(systemName: "doc.badge.plus") }
                ShareLink(item: plan, preview: SharePreview(plan.name)) { Image(systemName: "square.and.arrow.up") }
                    .disabled(plan.blocks.isEmpty)
                Button("Ride") { ride(plan.workout(ftp: ftp)) }
                    .fontWeight(.semibold)
                    .tint(orbeatRed)
                    .disabled(plan.blocks.isEmpty)
            }
        }
        .confirmationDialog("Replace this workout?", isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }),
                            titleVisibility: .visible, presenting: replacing) { t in
            Button("Replace with \(t.name)", role: .destructive) { use(t) }
        }
        .onAppear {
            plan = Self.saved
            if plan.ftp == riderFTP { plan.ftp = nil }   // Settings caught up with the override
        }
        .onChange(of: plan) { _, p in UserDefaults.standard.set(try? JSONEncoder().encode(p), forKey: Self.key) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: $plan.name)
                .font(.system(size: 17, weight: .semibold))
                .submitLabel(.done)
            HStack(alignment: .firstTextBaseline) {
                Text(clock(Double(plan.length)))
                Spacer()
                Text("\(watts(plan.intensity)) W avg · \(plan.tss) TSS")
            }
            .font(.system(size: 15, weight: .semibold))
            .monospacedDigit()
            ZoneProfile(plan: plan, selected: sel) { sel = $0 }
                .frame(height: 128)
                .padding(.top, 4)
            HStack {
                ForEach(0..<5) { k in
                    if k > 0 { Spacer() }
                    Text(clock(Double(plan.length * k / 4 / 60 * 60)))
                }
            }
            .font(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .opacity(plan.blocks.isEmpty ? 0 : 1)
            Divider().padding(.top, 4)
            row("FTP · ±5 W", "\(ftp) W", plan.ftp == nil ? "from Settings" : "this workout",
                { setFTP(ftp - 5) }, { setFTP(ftp + 5) })
                .padding(.bottom, -10)
        }
        .modifier(Tile(padding: 14))
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Text("No blocks yet").foregroundStyle(.secondary)
            Button("Add a block") { plan.blocks.append(.init(kind: .steady)); sel = 0 }
                .fontWeight(.semibold)
                .tint(orbeatRed)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .modifier(Tile(padding: 14))
    }

    private func editor(_ i: Int) -> some View {
        let b = $plan.blocks[i]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Eyebrow(text: "Block \(i + 1) of \(plan.blocks.count) · \(title(i))")
                Spacer(minLength: 4)
                stepButton("chevron.left") { sel -= 1 }.disabled(i == 0)
                stepButton("chevron.right") { sel += 1 }.disabled(i == plan.blocks.count - 1)
            }
            Picker("Kind", selection: Binding(get: { b.wrappedValue.kind }, set: { b.wrappedValue = b.wrappedValue.as($0) })) {
                ForEach(WorkoutPlan.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.vertical, 10)
            switch b.wrappedValue.kind {
            case .steady:
                timeRow("Time", b.seconds); Divider(); powerRow("Power", b.power)
            case .ramp:
                timeRow("Time", b.seconds); Divider(); powerRow("Start", b.power); Divider(); powerRow("End", b.powerEnd)
            case .intervals:
                row("Repeat", "\(b.wrappedValue.repeats) ×", nil,
                    { b.wrappedValue.repeats = max(1, b.wrappedValue.repeats - 1) },
                    { b.wrappedValue.repeats = min(30, b.wrappedValue.repeats + 1) })
                Divider(); timeRow("Work", b.on); Divider(); powerRow("Work power", b.onPower)
                Divider(); timeRow("Rest", b.off); Divider(); powerRow("Rest power", b.offPower)
            }
            Divider()
            HStack(spacing: 20) {
                Button("Duplicate") { plan.blocks.insert(plan.blocks[i], at: i + 1); sel = i + 1 }
                Button("Add after") { plan.blocks.insert(.init(kind: .steady), at: i + 1); sel = i + 1 }
                Spacer()
                Button("Delete", role: .destructive) { plan.blocks.remove(at: i); sel = max(0, i - 1) }
                    .foregroundStyle(orbeatRed)
            }
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
        .modifier(Tile(padding: 14))
    }

    private func use(_ t: WorkoutPlan) { plan = t; sel = 0 }

    /// Back at the rider's FTP drops the override.
    private func setFTP(_ w: Int) { let w = min(500, max(50, w)); plan.ftp = w == riderFTP ? nil : w }

    private func watts(_ f: Double) -> Int { Int((f * Double(ftp)).rounded()) }

    private func title(_ i: Int) -> String {
        let b = plan.blocks[i]
        switch b.kind {
        case .steady: return "Steady"
        case .intervals: return "\(b.repeats) × Intervals"
        case .ramp where i == 0 && b.power < b.powerEnd: return "Warm-up"
        case .ramp where i == plan.blocks.count - 1 && b.power > b.powerEnd: return "Cool-down"
        case .ramp: return "Ramp"
        }
    }

    /// Finer steps for short times: 15 s under 2 min, 30 s under 10, then minutes.
    /// Both buttons step by the current value's size, so the label is always true.
    private func step(_ s: Int) -> Int { s < 120 ? 15 : s < 600 ? 30 : 60 }

    private func timeRow(_ label: String, _ v: Binding<Int>) -> some View {
        let s = v.wrappedValue, st = step(s)
        return row("\(label) · ±\(st < 60 ? "\(st) s" : "1 min")", clock(Double(s)), nil,
                   { v.wrappedValue = max(15, s - st) },
                   { v.wrappedValue = min(max(7200, s), s + st) })
    }

    /// ±5 W at the rider's FTP, stored as an FTP fraction.
    private func powerRow(_ label: String, _ v: Binding<Double>) -> some View {
        let d = 5 / Double(ftp)
        return row("\(label) · ±5 W", "\(watts(v.wrappedValue)) W", "\(Int((v.wrappedValue * 100).rounded())) %",
                   { v.wrappedValue = max(0.25, v.wrappedValue - d) },
                   { v.wrappedValue = min(3, v.wrappedValue + d) })
    }

    private func row(_ label: String, _ value: String, _ sub: String?,
                     _ minus: @escaping () -> Void, _ plus: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Eyebrow(text: label)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value).font(.system(size: 17, weight: .semibold)).contentTransition(.numericText())
                    if let sub { Text(sub).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary) }
                }
                .monospacedDigit()
            }
            Spacer(minLength: 4)
            stepButton("minus", minus)
            stepButton("plus", plus)
        }
        .padding(.vertical, 10)
    }
}

/// Zwift's power-zone colours: what anyone who rides structured workouts reads.
func powerZoneColor(_ f: Double) -> Color {
    switch f {
    case ..<0.60: Color(white: 0.56)
    case ..<0.76: Color(red: 0.04, green: 0.52, blue: 1.0)    // #0A84FF
    case ..<0.90: Color(red: 0.19, green: 0.82, blue: 0.35)   // #30D158
    case ..<1.05: Color(red: 1.0, green: 0.84, blue: 0.04)    // #FFD60A
    case ..<1.19: Color(red: 1.0, green: 0.62, blue: 0.04)    // #FF9F0A
    default: orbeatRed
    }
}

/// Bars per step in zone colours, ramps as stairs; the picked block at full
/// strength with a bar underneath, the rest dimmed.
struct ZoneProfile: View {
    let plan: WorkoutPlan
    let selected: Int
    let onPick: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in draw(ctx, size) }
            .contentShape(Rectangle())
            .onTapGesture { p in
                let t = Double(p.x / geo.size.width) * Double(plan.length)
                var end = 0
                for (i, b) in plan.blocks.enumerated() {
                    end += b.length
                    if t < Double(end) { return onPick(i) }
                }
                if !plan.blocks.isEmpty { onPick(plan.blocks.count - 1) }
            }
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let total = Double(max(1, plan.length)), h: CGFloat = size.height - 8
        let top = max(1.2, plan.blocks.flatMap(\.steps).map { max($0.1, $0.2) }.max() ?? 1) / 0.92
        func y(_ f: Double) -> CGFloat { h - f / top * h }
        var x: CGFloat = 0, mark: (CGFloat, CGFloat)?
        for (i, b) in plan.blocks.enumerated() {
            let x0 = x
            for (s, a, e) in b.steps {
                let w: CGFloat = Double(s) / total * size.width
                let n = a == e ? 1 : min(12, max(2, s / 60))
                for k in 0..<n {
                    let q = Double(k) / Double(n), dq = 1 / Double(n)
                    let f: Double = a + (e - a) * (q + dq / 2)
                    let u: CGFloat = x + w * q
                    let u1: CGFloat = x + w * (q + dq) - (k == n - 1 ? 1.5 : 0)
                    guard u1 > u else { continue }
                    let r = min(3, (u1 - u) / 2)
                    let bar = UnevenRoundedRectangle(topLeadingRadius: r, topTrailingRadius: r)
                        .path(in: CGRect(x: u, y: y(f), width: u1 - u, height: h - y(f)))
                    ctx.fill(bar, with: .color(powerZoneColor(f).opacity(i == selected ? 1 : 0.35)))
                }
                x += w
            }
            if i == selected { mark = (x0, x) }
        }
        var line = Path()
        line.move(to: CGPoint(x: 0, y: y(1)))
        line.addLine(to: CGPoint(x: size.width, y: y(1)))
        ctx.stroke(line, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
        ctx.draw(Text("FTP").font(.system(size: 9)).kerning(1).foregroundStyle(.tertiary),
                 at: CGPoint(x: size.width, y: y(1) - 3), anchor: .bottomTrailing)
        if let (a, b) = mark {
            ctx.fill(Path(roundedRect: CGRect(x: a, y: size.height - 3, width: max(0, b - a - 1.5), height: 3), cornerRadius: 1.5),
                     with: .color(.white))
        }
    }
}

extension WorkoutPlan: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: UTType("com.zwift.zwo") ?? .xml) { Data($0.zwo.utf8) }
            .suggestedFileName { p in
                let n = p.name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces.union(["."]))
                return "\(n.isEmpty ? "Workout" : n).zwo"
            }
    }
}
