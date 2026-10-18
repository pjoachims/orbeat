import SwiftUI

/// Route mode: name, progress, current grade and the elevation profile with
/// the ridden part filled in.
struct RouteCard: View {
    let route: Route
    let meters: Double
    var padding: CGFloat = 12
    let onStop: () -> Void

    private var done: Bool { meters >= route.length }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Eyebrow(text: "Route · \(route.name)")
                Spacer(minLength: 4)
                Button(action: onStop) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Stop riding this route")
            }
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%.1f / %.1f km", meters / 1000, route.length / 1000))
                Spacer()
                Text(done ? "Finished" : String(format: "%.1f %%", Double(route.grade(at: meters)) / 100))
            }
            .font(.system(size: 15, weight: .semibold))
            .monospacedDigit()
            ElevationProfile(route: route, meters: meters)
                .frame(height: 44)
            Text(String(format: "%.0f m climbing", route.climb))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .modifier(Tile(padding: padding))
    }
}

struct ElevationProfile: View {
    let route: Route
    let meters: Double

    var body: some View {
        Canvas { ctx, size in
            let n = 160
            let samples = (0...n).map { route.elevation(at: route.length * Double($0) / Double(n)) }
            let lo = samples.min() ?? 0, span = max(20, (samples.max() ?? 0) - lo)   // ≥ 20 m: flat stays flat
            func point(_ i: Int) -> CGPoint {
                CGPoint(x: size.width * CGFloat(i) / CGFloat(n),
                        y: size.height * (1 - CGFloat((samples[i] - lo) / span) * 0.9))
            }
            func area(upTo end: Int) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                for i in 0...end { p.addLine(to: point(i)) }
                p.addLine(to: CGPoint(x: point(end).x, y: size.height))
                p.closeSubpath()
                return p
            }
            let at = min(n, Int((meters / max(1, route.length) * Double(n)).rounded()))
            ctx.fill(area(upTo: n), with: .color(.primary.opacity(0.12)))
            ctx.fill(area(upTo: at), with: .color(orbeatRed.opacity(0.55)))
            let dot = point(at)
            ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8)), with: .color(orbeatRed))
        }
    }
}

/// Workout mode: name, time, current target and the power profile with the
/// ridden part filled in.
struct WorkoutCard: View {
    let workout: Workout
    let seconds: Double
    var padding: CGFloat = 12
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Eyebrow(text: "Workout · \(workout.name)")
                Spacer(minLength: 4)
                Button(action: onStop) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Stop this workout")
            }
            HStack(alignment: .firstTextBaseline) {
                Text("\(clock(seconds)) / \(clock(workout.length))")
                Spacer()
                Text(workout.watts(at: seconds).map { "\($0) W" } ?? "Finished")
            }
            .font(.system(size: 15, weight: .semibold))
            .monospacedDigit()
            WorkoutProfile(workout: workout, seconds: seconds)
                .frame(height: 44)
        }
        .modifier(Tile(padding: padding))
    }
}

struct WorkoutProfile: View {
    let workout: Workout
    let seconds: Double

    var body: some View {
        Canvas { ctx, size in
            let total = max(1, workout.length)
            let top = Double(max(1, workout.steps.map { max($0.from, $0.to) }.max() ?? 1))
            func y(_ w: Int) -> CGFloat { size.height * (1 - CGFloat(Double(w) / top) * 0.9) }
            var p = Path(), t = 0.0
            p.move(to: CGPoint(x: 0, y: size.height))
            for s in workout.steps {
                p.addLine(to: CGPoint(x: size.width * t / total, y: y(s.from)))
                t += s.seconds
                p.addLine(to: CGPoint(x: size.width * t / total, y: y(s.to)))
            }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.closeSubpath()
            ctx.fill(p, with: .color(.primary.opacity(0.12)))
            var done = ctx
            done.clip(to: Path(CGRect(x: 0, y: 0, width: size.width * min(1, seconds / total), height: size.height)))
            done.fill(p, with: .color(orbeatRed.opacity(0.55)))
        }
    }
}
