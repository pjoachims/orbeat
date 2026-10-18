import Foundation
import Security

/// Posts finished sessions to the user's own health backend (fitbit-air,
/// `POST <url>/rides`). A session counts as sent per sample count, so a resumed
/// ride goes again; the backend upserts by start. Unsent ones (offline, no
/// backend set yet) go on the next store change or launch.
/// ponytail: no retry timer; a failed upload waits for the next session or launch.
enum RideUpload {
    static let urlKey = "rideUploadURL"
    private static let doneKey = "rideUploadDone"
    private static var busy = false

    static var url: String { UserDefaults.standard.string(forKey: urlKey) ?? "" }

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

    /// Main thread. Sends one session at a time and stops at the first failure.
    static func run(_ sessions: [Session]) {
        let token = token
        guard !busy, !token.isEmpty, let base = URL(string: url), base.scheme != nil else { return }
        let done = Set(UserDefaults.standard.stringArray(forKey: doneKey) ?? [])
        let todo = sessions.filter { !done.contains(key($0)) }
        guard !todo.isEmpty else { return }
        busy = true
        send(todo[...], to: base.appendingPathComponent("rides"), token: token)
    }

    private static func send(_ todo: ArraySlice<Session>, to endpoint: URL, token: String) {
        guard let s = todo.first else { busy = false; return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? encoder.encode(s)
        URLSession.shared.dataTask(with: req) { _, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    NSLog("Orbeat: ride upload failed: \(error?.localizedDescription ?? "HTTP \(status)")")
                    busy = false
                    return
                }
                UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: doneKey) ?? []) + [key(s)],
                                          forKey: doneKey)
                send(todo.dropFirst(), to: endpoint, token: token)
            }
        }.resume()
    }

    private static func key(_ s: Session) -> String { "\(s.id)/\(s.samples.count)" }
}
