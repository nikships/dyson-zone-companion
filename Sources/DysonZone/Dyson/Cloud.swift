import Foundation

struct DysonDevice: Decodable {
    let serialNumber: String?
    let name: String?
    let category: String?
    let connectionCategory: String?
    let model: String?
    let type: String?
}

struct Credentials: Codable {
    var email: String
    var accountId: String
    var serial: String
    var ltk: String
}

enum CloudError: LocalizedError {
    case http(Int, String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "Dyson returned \(code): \(body.prefix(200))"
        case .message(let text): return text
        }
    }
}

/// Just enough of the Dyson cloud to fetch the headphones' long-term key. It runs once, at
/// sign-in; normal operation is entirely over Bluetooth.
struct DysonCloud {
    private let host = URL(string: "https://appapi.cp.dyson.com")!
    private let country: String
    private let culture: String

    init() {
        country = Locale.current.region?.identifier ?? "US"
        culture = "en-\(country)"
    }

    func beginLogin(email: String) async throws -> String {
        _ = try await request("GET", "/v1/provisioningservice/application/Android/version")
        _ = try await request("POST", "/v3/userregistration/email/userstatus", query: ["country": country], body: ["email": email])
        let data = try await request("POST", "/v3/userregistration/email/auth", query: ["country": country, "culture": culture], body: ["email": email])
        guard let challenge = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["challengeId"] as? String else {
            throw CloudError.message("Dyson did not return a challenge. Is this email registered?")
        }
        return challenge
    }

    func completeLogin(email: String, password: String, challengeId: String, code: String) async throws -> (token: String, accountId: String) {
        let data = try await request(
            "POST", "/v3/userregistration/email/verify",
            query: ["country": country, "culture": culture],
            body: ["challengeId": challengeId, "email": email, "otpCode": code, "password": password]
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String, let account = json["account"] as? String else {
            throw CloudError.message("Login succeeded but Dyson returned no token.")
        }
        return (token, account)
    }

    func devices(token: String) async throws -> [DysonDevice] {
        for path in ["/v3/manifest", "/v2/provisioningservice/manifest"] {
            if let data = try? await request("GET", path, headers: ["Authorization": "Bearer \(token)"]),
               let list = try? JSONDecoder().decode([DysonDevice].self, from: data) {
                return list
            }
        }
        throw CloudError.message("Could not read the device list from your Dyson account.")
    }

    func ltk(serial: String, token: String) async throws -> String {
        let escaped = serial.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? serial
        let data = try await request("GET", "/v1/lec/\(escaped)/ltk", headers: [
            "Authorization": "Bearer \(token)",
            "X-Dyson-ApiAuthCode": "80541406",
        ])
        guard let ltk = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["ltk"] as? String else {
            throw CloudError.message("Dyson returned no key for \(serial).")
        }
        return ltk
    }

    private func request(
        _ method: String, _ path: String,
        query: [String: String] = [:], body: [String: String]? = nil, headers: [String: String] = [:]
    ) async throws -> Data {
        var comps = URLComponents(url: host.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("android client", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw CloudError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}

enum CredentialStore {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DysonZone", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("credentials.json")
    }

    static func load() -> Credentials? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    static func save(_ credentials: Credentials) throws {
        try JSONEncoder().encode(credentials).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }
}

enum Log {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("DysonZone.log")
    }()

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
