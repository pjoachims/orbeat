import Foundation

/// Optional session recording: start/stop, one JSON line per reading (JSONL),
/// written to Documents. iOS exposes the files via the Files app / share sheet;
/// macOS just drops them in ~/Documents.
final class Recorder: ObservableObject {
    @Published private(set) var recording = false
    /// Most recent session file (current one while recording) — export target.
    @Published private(set) var fileURL: URL?
    private var handle: FileHandle?
    private var lastWrite = Date.distantPast

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()

    func start() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("Orbeat \(Recorder.stamp.string(from: Date())).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        guard handle != nil else { return }
        fileURL = url
        recording = true
    }

    func stop() {
        try? handle?.close()
        handle = nil
        recording = false
    }

    /// Append one reading; call as often as you like — throttled to 1/s.
    func sample(bpm: Int, watts: Int?, cadence: Int?, speedKmh: Double?) {
        guard recording, Date().timeIntervalSince(lastWrite) >= 1 else { return }
        lastWrite = Date()
        var obj: [String: Any] = ["t": ISO8601DateFormatter().string(from: Date())]
        if bpm > 0 { obj["bpm"] = bpm }
        if let w = watts { obj["watts"] = w }
        if let c = cadence { obj["rpm"] = c }
        if let s = speedKmh { obj["kmh"] = (s * 10).rounded() / 10 }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        handle?.write(data)
        handle?.write(Data("\n".utf8))
    }
}
