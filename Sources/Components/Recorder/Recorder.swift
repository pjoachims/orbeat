import Foundation

/// DuckDB logging: when enabled, appends one JSON line per BLE packet (JSONL) to
/// ~/Library/Application Support/Orbeat/orbeat.jsonl. DuckDB reads it directly:
///   SELECT * FROM read_json_auto('.../Application Support/Orbeat/orbeat.jsonl')
/// Not ~/Documents: TCC blocks launchd jobs (rsync to the VPS) from reading there.
/// ponytail: single append-only file, add daily rotation if it ever gets big.
/// JSONL sink for the Core LogWriting protocol.
final class Recorder: ObservableObject, LogWriting {
    static let logURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Orbeat/orbeat.jsonl")

    /// Master toggle, persisted.
    @Published var recording = UserDefaults.standard.bool(forKey: "duckdbLog") {
        didSet {
            UserDefaults.standard.set(recording, forKey: "duckdbLog")
            recording ? open() : close()
        }
    }
    private var handle: FileHandle?
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init() { if recording { open() } }

    private func open() {
        let url = Recorder.logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    private func close() {
        try? handle?.close()
        handle = nil
    }

    /// Append one event (one BLE packet); "t" with ms precision added automatically.
    func log(_ fields: [String: Any]) {
        guard let handle else { return }
        var obj = fields
        obj["t"] = Recorder.iso.string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        handle.write(data)
        handle.write(Data("\n".utf8))
    }
}
