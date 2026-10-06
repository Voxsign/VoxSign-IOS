//
//  SettingsStore.swift
//  VoxSign
//
//  Settings (T3): dual connection modes --
//  - Cloud (default): zero config, Google sign-in only; base/token point at the VoxSign cloud
//    (independent of the server list).
//  - Self-hosted: empty list by default; the user adds servers (IP address / machine code);
//    each entry records its binding and connection method (direct / cloud relay).
//  Downstream (APIClient/SSEClient) keeps using the base/token computed properties, no change needed.
//

import Foundation

/// Connection mode: cloud (default) / self-hosted.
enum ConnectionMode: String, Codable, CaseIterable {
    case cloud        // cloud · default: sign in with Google, zero config
    case selfHosted   // self-hosted: add your own server
}

/// A connectable Harness server (self-hosted).
struct ServerConfig: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var base: String
    var token: String
    /// Machine-code binding (non-nil = added via machine code; address comes from cloud lookup).
    var machineCode: String?
    /// Cloud relay (intranet server relayed via the cloud; nil = direct).
    var viaRelay: Bool?

    var isMachineBound: Bool { machineCode != nil }
    var usesRelay: Bool { viaRelay ?? false }
}

/// Google sign-in state (cloud mode: tenant = Google sub).
struct GoogleAuthState: Codable, Equatable {
    var email: String
    var tenant: String
    var tier: String
    var quotaUsed: Int?
    var quotaLimit: Int?
    var resetsAt: String?
    var trialUntil: String?
    /// Session JWT (used as the Bearer token in cloud mode; older data may lack it -> optional for compatibility).
    var token: String?
    /// Kept for compatibility (v2.1 stored a server address; cloud mode no longer uses it).
    var serverBase: String
}

/// Observable settings store: reads UserDefaults on launch, writes back on save.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard
    private let serversKey = "vhs-ios-servers"
    private let activeKey = "vhs-ios-active"
    private let modeKey = "vhs-ios-mode"

    /// Connection mode (cloud default / self-hosted), persisted.
    @Published var mode: ConnectionMode = .cloud

    /// Self-hosted server list (empty by default, user adds), persisted.
    /// Note: no didSet attached (assigning during init would fire didSet before self is fully initialized -> compile error);
    /// persistence happens explicitly via persist() in the mutating methods.
    @Published var servers: [ServerConfig] = []
    /// Active server id (self-hosted mode), persisted.
    @Published var activeServerID: String = ""

    /// Cloud base (production domain voxsign.ai; nginx forwards /v1 -> cloud harness 8898).
    var cloudBase: String { "https://voxsign.ai" }

    /// Active server (self-hosted mode; cloud / none selected -> nil).
    var activeServerConfig: ServerConfig? { activeServer() }

    /// Effective base (for downstream compatibility).
    var base: String {
        switch mode {
        case .cloud: return cloudBase
        case .selfHosted: return activeServer()?.base ?? ""
        }
    }
    /// Effective token (for downstream compatibility).
    var token: String {
        switch mode {
        case .cloud: return googleAuth?.token ?? ""
        case .selfHosted: return activeServer()?.token ?? ""
        }
    }

    init() {
        if let raw = defaults.string(forKey: modeKey), let m = ConnectionMode(rawValue: raw) {
            mode = m
        }
        if let data = defaults.data(forKey: serversKey),
           let list = try? JSONDecoder().decode([ServerConfig].self, from: data),
           !list.isEmpty {
            servers = list
        }
        // Self-hosted defaults to empty: no servers are pre-provisioned; existing users keep their list after upgrade.
        let saved = defaults.string(forKey: activeKey)
        if let saved, servers.contains(where: { $0.id == saved }) {
            activeServerID = saved
        }
        loadAuth()
    }

    // MARK: - Mode

    func setMode(_ m: ConnectionMode) {
        mode = m
        defaults.set(m.rawValue, forKey: modeKey)
        // V6.3 re-probe on switch: the status dot and machine name must follow the actual connection target.
        // Otherwise you get a mismatch: Settings says self-hosted but you are still on cloud while the name has changed.
        ConnectivityService.shared.reset()
    }

    // MARK: - Self-hosted server management

    func addServer(name: String, base: String, token: String,
                   machineCode: String? = nil, viaRelay: Bool = false) {
        let cfg = ServerConfig(id: UUID().uuidString, name: name, base: base, token: token,
                               machineCode: machineCode, viaRelay: viaRelay)
        servers.append(cfg)
        activeServerID = cfg.id   // the new one becomes active (Doubao-style: add = connect)
        persist()
    }

    func switchServer(_ id: String) {
        guard servers.contains(where: { $0.id == id }) else { return }
        activeServerID = id
        persist()
        // v2.1 I16: switching triggers an immediate connectivity probe (pill feedback at once, no 30s heartbeat wait).
        Task { await ConnectivityService.shared.probe() }
    }

    func removeServer(_ id: String) {
        servers.removeAll { $0.id == id }
        if activeServerID == id {
            activeServerID = servers.first?.id ?? ""
        }
        // Allow deleting down to 0 (no longer "keep at least one"); when empty in self-hosted mode, fall back to cloud so the UI stays consistent.
        if servers.isEmpty && mode == .selfHosted {
            setMode(.cloud)
        }
        persist()
        // Reset probing: clear the old server connection state and immediately re-probe the current base.
        ConnectivityService.shared.reset()
    }

    /// Unbind the machine code: clear machineCode (keep the server entry, address/token/relay),
    /// after which the server behaves as a normal self-hosted server (rename/edit address/delete).
    func unbindMachine(_ id: String) {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[idx].machineCode = nil
        persist()
        ConnectivityService.shared.reset()
    }

    /// Update the active server's address/token (Settings edit).
    func updateActive(base: String, token: String) {
        guard let idx = servers.firstIndex(where: { $0.id == activeServerID }) else { return }
        servers[idx].base = base
        servers[idx].token = token
        persist()
    }

    // MARK: - Google sign-in state (cloud mode)

    private let authKey = "vhs-ios-google-auth"

    /// Sign-in state: tenant email/tier/quota/trial + session JWT (persisted).
    @Published var googleAuth: GoogleAuthState?

    func setGoogleLogin(_ result: GoogleLoginResult, base: String) {
        googleAuth = GoogleAuthState(email: result.email,
                                     tenant: result.tenant,
                                     tier: result.tier,
                                     quotaUsed: result.quota?.used,
                                     quotaLimit: result.quota?.limit,
                                     resetsAt: result.quota?.resetsAt,
                                     trialUntil: result.trialUntil,
                                     token: result.token,
                                     serverBase: base)
        persistAuth()
    }

    /// Refresh sign-in state from /v1/me (tier/quota may change).
    func refreshAuth(_ me: MeResult) {
        guard var a = googleAuth else { return }
        a.tier = me.tier
        a.quotaUsed = me.quota?.used
        a.quotaLimit = me.quota?.limit
        a.resetsAt = me.quota?.resetsAt
        a.trialUntil = me.trialUntil
        googleAuth = a
        persistAuth()
    }

    func logoutGoogle() {
        googleAuth = nil
        persistAuth()
    }

    private func loadAuth() {
        guard let data = defaults.data(forKey: authKey),
              let auth = try? JSONDecoder().decode(GoogleAuthState.self, from: data) else { return }
        googleAuth = auth
    }

    private func persistAuth() {
        if let data = try? JSONEncoder().encode(googleAuth) {
            defaults.set(data, forKey: authKey)
        } else {
            defaults.removeObject(forKey: authKey)
        }
    }

    private func activeServer() -> ServerConfig? {
        servers.first { $0.id == activeServerID } ?? servers.first
    }

    /// Strip trailing slashes and build an absolute URL (path starts with /).
    func url(_ path: String) -> URL? {
        let clean = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: clean + path)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(servers) {
            defaults.set(data, forKey: serversKey)
        }
        defaults.set(activeServerID, forKey: activeKey)
        defaults.set(mode.rawValue, forKey: modeKey)
    }
}
