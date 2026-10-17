import Foundation

@MainActor
final class AppModel: ObservableObject {
    let headphones = Headphones()
    let link = ZoneLink()
    @Published private(set) var credentials: Credentials?

    init() {
        credentials = CredentialStore.load()
        link.start(with: credentials)
    }

    func signedIn(_ credentials: Credentials) {
        self.credentials = credentials
        link.start(with: credentials)
    }

    func signOut() {
        link.stop()
        CredentialStore.clear()
        credentials = nil
        link.start(with: nil)
    }
}

@MainActor
final class SignInModel: ObservableObject {
    enum Step { case email, code, choose, done }

    @Published var email = UserDefaults.standard.string(forKey: "dysonEmail") ?? ""
    @Published var password = ""
    @Published var code = ""
    @Published var step = Step.email
    @Published var busy = false
    @Published var error: String?
    @Published var candidates: [DysonDevice] = []

    private let cloud = DysonCloud()
    private var challengeId = ""
    private var token = ""
    private var accountId = ""

    func sendCode() {
        run {
            self.challengeId = try await self.cloud.beginLogin(email: self.email.trimmingCharacters(in: .whitespaces))
            UserDefaults.standard.set(self.email, forKey: "dysonEmail")
            self.step = .code
        }
    }

    func verify(_ app: AppModel) {
        run {
            let result = try await self.cloud.completeLogin(
                email: self.email.trimmingCharacters(in: .whitespaces), password: self.password,
                challengeId: self.challengeId, code: self.code.trimmingCharacters(in: .whitespaces)
            )
            self.token = result.token
            self.accountId = result.accountId
            self.password = ""
            let devices = try await self.cloud.devices(token: result.token)
            for d in devices {
                Log.write("account device: serial=\(d.serialNumber ?? "?") name=\(d.name ?? "?") category=\(d.category ?? "?") connection=\(d.connectionCategory ?? "?") model=\(d.model ?? "?") type=\(d.type ?? "?")")
            }
            let withSerial = devices.filter { $0.serialNumber != nil }
            let likely = withSerial.filter { Self.looksLikeZone($0) }
            if likely.count == 1 {
                try await self.finish(likely[0], app)
            } else {
                self.candidates = withSerial
                self.step = .choose
            }
        }
    }

    func choose(_ device: DysonDevice, _ app: AppModel) {
        run { try await self.finish(device, app) }
    }

    private func finish(_ device: DysonDevice, _ app: AppModel) async throws {
        guard let serial = device.serialNumber else { return }
        let ltk = try await cloud.ltk(serial: serial, token: token)
        let credentials = Credentials(email: email, accountId: accountId, serial: serial, ltk: ltk)
        try CredentialStore.save(credentials)
        token = ""
        app.signedIn(credentials)
        step = .done
    }

    private static func looksLikeZone(_ d: DysonDevice) -> Bool {
        let text = [d.name, d.model, d.type, d.category].compactMap { $0 }.joined(separator: " ").lowercased()
        return text.contains("571") || text.contains("zone") || text.contains("headphone")
    }

    private func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            self.busy = false
        }
    }
}
