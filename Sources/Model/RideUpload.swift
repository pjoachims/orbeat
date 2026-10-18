import Foundation
import Security

/// Posts finished sessions to the user's own health backend (fitbit-air,
/// `POST <url>/rides`). A session counts as sent per sample count, so a resumed
/// ride goes again; the backend upserts by start. Unsent ones (offline, no
/// backend set yet) go on the next store change or launch.
/// ponytail: no retry timer; a failed upload waits for the next session or launch.
enum RideUpload {
    static let urlKey = "rideUploadURL"
    /// Upload on every store change and launch; off = only the manual Upload button.
    static let autoKey = "rideUploadAuto"
    static var auto: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
    private static let doneKey = "rideUploadDone"
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
    /// `report` gets a one-line result for the UI.
    static func run(_ sessions: [Session], report: ((String) -> Void)? = nil) {
        if busy { again = sessions; report?("Upload already running"); return }
        let token = token
        guard !token.isEmpty, let base = URL(string: url), base.scheme != nil else {
            report?("Set URL and token first"); return
        }
        let done = Set(UserDefaults.standard.stringArray(forKey: doneKey) ?? [])
        let todo = sessions.filter { !done.contains(key($0)) }
        guard !todo.isEmpty else { report?("All \(sessions.count) rides already sent"); return }
        busy = true
        send(todo[...], to: base.appendingPathComponent("rides"), token: token, sent: 0, of: todo.count, report: report)
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
                UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: doneKey) ?? []) + [key(s)],
                                          forKey: doneKey)
                send(todo.dropFirst(), to: endpoint, token: token,
                     sent: sent + (status == 200 ? 1 : 0), of: total, report: report)
            }
        }.resume()
    }

    /// Checks URL + token against the backend's status route; reports its ride count.
    static func test(report: @escaping (String) -> Void) {
        guard let base = URL(string: url), base.scheme != nil, !token.isEmpty else {
            return report("Set URL and token first")
        }
        var req = URLRequest(url: base.appendingPathComponent("status"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let derived = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["derived"]
            let rides = (derived as? [[String: Any]])?.first { $0["kind"] as? String == "ride" }?["n"] as? Int ?? 0
            DispatchQueue.main.async {
                report(status == 200 ? "Connected · \(rides) rides on backend"
                                     : "Failed: \(error?.localizedDescription ?? "HTTP \(status)")")
            }
        }.resume()
    }

    /// Per backend: pointing at a new URL sends everything again.
    private static func key(_ s: Session) -> String { "\(url) \(s.id)/\(s.samples.count)" }
}
