import Foundation
import Security

/// Posts finished sessions to the user's own health backend (fitbit-air,
/// `POST <url>/rides`). Asks the backend first (`GET <url>/rides`) and sends only
/// sessions it lacks or holds with another sample count (a resumed ride), so the Mac and
/// iPhone don't both send the same ride. Unsent ones (offline, no backend set
/// yet) go on the next store change or launch.
/// ponytail: no retry timer; a failed upload waits for the next session or launch.
enum RideUpload {
    static let urlKey = "rideUploadURL"
    /// Upload on every store change and launch; off = only the manual Upload button.
    static let autoKey = "rideUploadAuto"
    static var auto: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
    private static var busy = false
    /// Sessions handed in while busy: sent after the running chain.
    private static var again: [Session]?

    static var url: String {
        (UserDefaults.standard.string(forKey: urlKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Bearer token, kept in the Keychain: it reads and writes the user's health data.
    static var token: String {
        get {
            var out: CFTypeRef?
            let q = query.merging([kSecReturnData as String: true]) { $1 }
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            let newValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            SecItemDelete(query as CFDictionary)
            guard !newValue.isEmpty else { return }
            let item = query.merging([kSecValueData as String: Data(newValue.utf8)]) { $1 }
            SecItemAdd(item as CFDictionary, nil)
        }
    }
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                               kSecAttrService as String: "Orbeat ride upload"]

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Main thread. Sends one session at a time; stops at the first failure except a 400
    /// (a body the backend will never take), which is skipped so it can't block the rest.
    /// ponytail: a 400 ride is retried every run; remember rejects if one ever shows up.
    /// `report` gets a one-line result for the UI.
    static func run(_ sessions: [Session], report: ((String) -> Void)? = nil) {
        if busy { again = sessions; report?("Upload already running"); return }
        let token = token
        guard !token.isEmpty, let base = URL(string: url), base.scheme != nil else {
            report?("Set URL and token first"); return
        }
        busy = true
        held(base, token: token) { held, why in
            guard let held else {
                busy = false
                again = nil
                report?("Failed: \(why)")
                return
            }
            let todo = sessions.filter { held[$0.id.uuidString] != $0.samples.count }
            guard !todo.isEmpty else {
                busy = false
                report?("All \(sessions.count) rides on backend")
                if let next = again { again = nil; run(next) }
                return
            }
            send(todo[...], to: base.appendingPathComponent("rides"), token: token, sent: 0, of: todo.count, report: report)
        }
    }

    /// The backend's rides as id → sample count, or nil plus why on the main thread.
    private static func held(_ base: URL, token: String, done: @escaping ([String: Int]?, String) -> Void) {
        var req = URLRequest(url: base.appendingPathComponent("rides"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let list = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]]
            let held = list.map { Dictionary($0.compactMap { r in
                (r["id"] as? String).flatMap { id in (r["samples"] as? Int).map { (id, $0) } }
            }) { a, _ in a } }
            DispatchQueue.main.async {
                done(status == 200 ? held : nil, error?.localizedDescription ?? "HTTP \(status)")
            }
        }.resume()
    }

    private static func send(_ todo: ArraySlice<Session>, to endpoint: URL, token: String,
                             sent: Int, of total: Int, report: ((String) -> Void)?) {
        guard let s = todo.first else {
            busy = false
            report?("Sent \(sent) of \(total) rides")
            if let next = again { again = nil; run(next) }
            return
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? encoder.encode(s)
        URLSession.shared.dataTask(with: req) { _, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 || status == 400 else {
                    let why = error?.localizedDescription ?? "HTTP \(status)"
                    NSLog("Orbeat: ride upload failed: \(why)")
                    report?("Failed: \(why) (\(sent) of \(total) sent)")
                    busy = false
                    again = nil
                    return
                }
                if status == 400 { NSLog("Orbeat: ride \(s.id) rejected by backend, skipped") }
                send(todo.dropFirst(), to: endpoint, token: token,
                     sent: sent + (status == 200 ? 1 : 0), of: total, report: report)
            }
        }.resume()
    }

    /// Checks URL + token against the backend; reports its ride count.
    static func test(report: @escaping (String) -> Void) {
        let token = token
        guard let base = URL(string: url), base.scheme != nil, !token.isEmpty else {
            return report("Set URL and token first")
        }
        held(base, token: token) { held, why in
            report(held.map { "Connected · \($0.count) rides on backend" } ?? "Failed: \(why)")
        }
    }
}
