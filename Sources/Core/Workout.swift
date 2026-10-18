import Foundation

/// A structured workout to ride in ERG: power targets over time, from a Zwift
/// .zwo or an .erg / .mrc course file. Watts are absolute; files given in % of
/// FTP are converted when loaded.
struct Workout: Codable, Equatable {
    struct Step: Codable, Equatable {
        var seconds: Double
        /// Target at the step's start and end; they differ on a ramp.
        var from: Int
        var to: Int
    }
    var name: String
    var steps: [Step]

    static let extensions: Set = ["zwo", "erg", "mrc"]

    var length: Double { steps.reduce(0) { $0 + $1.seconds } }

    /// ERG target `t` seconds in, ramps interpolated; nil once finished.
    func watts(at t: Double) -> Int? {
        var start = 0.0
        for s in steps {
            if t < start + s.seconds {
                return Int((Double(s.from) + Double(s.to - s.from) * (t - start) / s.seconds).rounded())
            }
            start += s.seconds
        }
        return nil
    }

    /// nil when the file has no targets to ride.
    static func parse(_ data: Data, ext: String, name: String, ftp: Int) -> Workout? {
        let w = ext == "zwo" ? zwo(data, name: name, ftp: ftp)
            : (String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)).map { course($0, name: name, ftp: ftp) }
        guard let w, w.length > 0 else { return nil }
        return w
    }

    /// Zwift workout XML; power is a fraction of FTP.
    private static func zwo(_ data: Data, name: String, ftp: Int) -> Workout? {
        let p = ZwoParser(ftp: Double(ftp))
        let xml = XMLParser(data: data)
        xml.delegate = p
        guard xml.parse() else { return nil }
        return Workout(name: p.name ?? name, steps: p.steps)
    }

    /// .erg (watts) / .mrc (% of FTP): `minutes value` points between
    /// [COURSE DATA] markers, consecutive points joined linearly.
    private static func course(_ text: String, name: String, ftp: Int) -> Workout {
        var percent = false, inData = false
        var points: [(min: Double, v: Double)] = []
        for line in text.components(separatedBy: .newlines) {
            let u = line.uppercased()
            if u.contains("[COURSE DATA]") { inData = true; continue }
            if u.contains("[END COURSE DATA]") { inData = false; continue }
            if !inData {
                // the column line only: a DESCRIPTION may say "minutes at 105 percent"
                if u.split(whereSeparator: \.isWhitespace) == ["MINUTES", "PERCENT"] { percent = true }
                continue
            }
            let f = line.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
            if f.count >= 2 { points.append((f[0], f[1])) }
        }
        let watts = { (v: Double) in Int((percent ? v / 100 * Double(ftp) : v).rounded()) }
        let steps = zip(points, points.dropFirst()).compactMap { a, b in
            b.min > a.min ? Step(seconds: (b.min - a.min) * 60, from: watts(a.v), to: watts(b.v)) : nil
        }
        return Workout(name: name, steps: steps)
    }
}

private final class ZwoParser: NSObject, XMLParserDelegate {
    let ftp: Double
    var steps: [Workout.Step] = []
    var name: String?
    private var text = ""

    init(ftp: Double) { self.ftp = ftp }

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String] = [:]) {
        text = ""
        func num(_ k: String) -> Double? { a[k].flatMap(Double.init) }
        func w(_ f: Double) -> Int { Int((f * ftp).rounded()) }
        // ponytail: FreeRide / MaxEffort skipped (no ERG target); hold-previous if anyone misses them
        switch el {
        case "SteadyState":
            if let d = num("Duration"), let p = num("Power") ?? num("PowerLow") {
                steps.append(.init(seconds: d, from: w(p), to: w(p)))
            }
        case "Warmup", "Cooldown", "Ramp":
            if let d = num("Duration"), let lo = num("PowerLow"), let hi = num("PowerHigh") {
                steps.append(.init(seconds: d, from: w(lo), to: w(hi)))
            }
        case "IntervalsT":
            if let n = num("Repeat"), let on = num("OnDuration"), let off = num("OffDuration"),
               let pOn = num("OnPower") ?? num("PowerOnLow"), let pOff = num("OffPower") ?? num("PowerOffLow") {
                for _ in 0..<max(0, Int(n)) {
                    steps.append(.init(seconds: on, from: w(pOn), to: w(pOn)))
                    steps.append(.init(seconds: off, from: w(pOff), to: w(pOff)))
                }
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if el == "name", name == nil, !t.isEmpty { name = t }
    }
}
