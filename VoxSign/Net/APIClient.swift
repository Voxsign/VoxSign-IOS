//
//  APIClient.swift
//  VoxSign
//
//  INTERACT-v1 endpoint client (read-only contract, server unchanged). All calls carry Bearer auth.
//  Zero third-party dependencies: plain URLSession + async/await.
//

import Foundation

enum APIError: LocalizedError, Equatable {
    case http(Int, String)
    case decode(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "HTTP \(code): \(body)"
        case .decode(let m): return "Parse failed: \(m)"
        case .transport(let m): return "Network error: \(m)"
        }
    }
}

/// Response to POST /v1/tasks.
struct CreateTaskResponse: Equatable {
    let taskId: String
    let status: String?
    let deduped: Bool?
}

/// Response to GET /v1/status.
struct StatusResponse: Equatable {
    let ok: Bool
    let version: String?
    let tasks: Int?
}

/// Response to GET /v1/roles.
struct RolesResponse: Equatable {
    let roles: [RoleInfo]
    let taskId: String?
    let role: String?
}

/// Machine-code lookup result: the cloud-located machine identity.
struct MachineInfo: Equatable {
    let name: String
    let base: String
    let online: Bool
    /// Access credential (token) the cloud issued for this machine.
    let token: String
}

final class APIClient {
    static let shared = APIClient()
    var settings: SettingsStore = .shared

    /// Machine-code lookup uses the real cloud endpoint (POST /v1/devices/lookup, unauthenticated).
    static var machineLookupMock = false

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    // MARK: - Generic request

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> (Int, Data) {
        guard let url = settings.url(path) else {
            DiagLogger.shared.log("NET", "\(method) \(path) failed: invalid server base=\(settings.base)")
            throw APIError.transport("Invalid server address (check Settings)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // D0 贯穿 trace：每个 HTTP 请求带一个 X-Request-Id（UUID），与服务端日志对齐排障。
        req.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-Id")
        if !settings.token.isEmpty {
            req.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        }
        // A4（验收硬指标）：诊断日志不再输出 Bearer token 明文，只记"有/无"。
        DiagLogger.shared.log("NET", "\(method) \(url.absoluteString) token=\(settings.token.isEmpty ? "无" : "有")")
        if let body = body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw APIError.transport("No HTTP response")
            }
            DiagLogger.shared.log("NET", "\(method) \(path) -> \(http.statusCode) bytes=\(data.count)")
            return (http.statusCode, data)
        } catch let e as APIError {
            DiagLogger.shared.log("NET", "\(method) \(path) threw: \(e.localizedDescription)")
            throw e
        } catch {
            DiagLogger.shared.log("NET", "\(method) \(path) transport failed: \(error.localizedDescription)")
            throw APIError.transport(error.localizedDescription)
        }
    }

    private func decodeJSON(_ data: Data) -> [String: Any] {
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// A4 脱敏：机器码等准敏感标识 → 仅记前后各 2 位，中间打码（短串一律 ***）。
    private static func masked(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count > 4 else { return "***" }
        return "\(t.prefix(2))***\(t.suffix(2))"
    }

    // MARK: - 端点

    /// POST /v1/tasks {text, space?, request_id?, attachments?} -> 202 {task_id,status}; same request_id -> 200 deduped.
    /// v2.4: when attachments are non-empty they are submitted in the body (the server ignores unknown fields).
    func submitTask(text: String, space: String? = nil, requestId: String, attachments: [Attachment] = []) async throws -> CreateTaskResponse {
        var body: [String: Any] = ["text": text, "request_id": requestId]
        if let space = space { body["space"] = space }
        if !attachments.isEmpty {
            body["attachments"] = attachments.map { a -> [String: Any] in
                ["kind": a.kind.rawValue,
                 "title": a.title,
                 "text": a.text ?? "",
                 "file": a.fileName ?? ""]
            }
        }
        let (code, data) = try await request("POST", "/v1/tasks", body: body)
        let j = decodeJSON(data)
        guard (200...299).contains(code), let tid = j["task_id"] as? String else {
            throw APIError.http(code, String(decoding: data, as: UTF8.self))
        }
        return CreateTaskResponse(taskId: tid,
                                  status: j["status"] as? String,
                                  deduped: j["deduped"] as? Bool)
    }

    /// GET /v1/tasks/{id} -> poll view.
    func fetchTask(_ id: String) async throws -> TaskView {
        let (code, data) = try await request("GET", "/v1/tasks/\(id)")
        let j = decodeJSON(data)
        if let st = j["status"] as? String, st == "done" || st == "need_ask" {
            DiagLogger.shared.log("POLL", "raw body[\(st)]: \(String(decoding: data, as: UTF8.self).prefix(300))")
        }
        guard (200...299).contains(code) else {
            throw APIError.http(code, String(decoding: data, as: UTF8.self))
        }
        let options = (j["options"] as? [[String: Any]])?.compactMap { o -> TaskOption? in
            guard let i = o["id"] as? String, let l = o["label"] as? String else { return nil }
            return TaskOption(id: i, label: l)
        }
        return TaskView(taskId: id,
                        status: j["status"] as? String,
                        question: j["question"] as? String,
                        options: options,
                        receipt: j["receipt"] as? String,
                        attribution: j["attribution"] as? String,
                        reversible: j["reversible"] as? Bool,
                        error: j["error"] as? String,
                        reply: VSLogic.normalizeReply(j["reply"]))
    }

    /// POST /v1/tasks/{id}/answer {answer} (option id or "execute"). 409 = no pending decision point.
    func answer(_ id: String, _ ans: String) async throws {
        let (code, data) = try await request("POST", "/v1/tasks/\(id)/answer", body: ["answer": ans])
        guard (200...299).contains(code) else {
            throw APIError.http(code, String(decoding: data, as: UTF8.self))
        }
    }

    /// POST /v1/tasks/{id}/rollback -> {ok, restored}; 409 if irreversible.
    @discardableResult
    func rollback(_ id: String) async throws -> String? {
        let (code, data) = try await request("POST", "/v1/tasks/\(id)/rollback")
        let j = decodeJSON(data)
        guard (200...299).contains(code) else {
            throw APIError.http(code, String(decoding: data, as: UTF8.self))
        }
        return j["restored"] as? String
    }

    /// POST /v1/tasks/{id}/cancel (M6 new endpoint set; legacy /v1/cancel body{task_id} kept).
    func cancel(_ id: String) async throws {
        // Prefer the new endpoint; fall back to legacy on failure (contract: legacy /v1/cancel stays compatible).
        do {
            let (code, _) = try await request("POST", "/v1/tasks/\(id)/cancel")
            if (200...299).contains(code) { return }
        } catch let e as APIError {
            // Fall back to legacy.
            if case .http(let c, _) = e, c == 404 || c == 405 {
                let _ = try await request("POST", "/v1/cancel", body: ["task_id": id])
                return
            }
            throw e
        }
    }

    /// GET /v1/status (Settings "Test connection").
    func status() async throws -> StatusResponse {
        let (code, data) = try await request("GET", "/v1/status")
        let j = decodeJSON(data)
        guard (200...299).contains(code) else {
            throw APIError.http(code, String(decoding: data, as: UTF8.self))
        }
        return StatusResponse(ok: j["ok"] as? Bool ?? false,
                              version: j["version"] as? String,
                              tasks: j["tasks"] as? Int)
    }

    // MARK: - Google sign-in (cloud mode)

    /// POST /v1/auth/google {id_token} -> session JWT + tenant/tier/quota (iOS-type client flow:
    /// iOS already exchanged the Google id_token via PKCE; the cloud harness verifies it with JWKS and
    /// issues a session JWT).
    func loginGoogleIDToken(_ idToken: String) async throws -> GoogleLoginResult {
        let (code2, data) = try await request("POST", "/v1/auth/google",
                                              body: ["id_token": idToken])
        let j = decodeJSON(data)
        guard (200...299).contains(code2), let token = j["token"] as? String else {
            throw APIError.http(code2, String(decoding: data, as: UTF8.self))
        }
        let quota = (j["quota"] as? [String: Any]).map { q in
            GoogleLoginResult.GoogleQuota(used: q["used"] as? Int,
                                         limit: q["limit"] as? Int,
                                         resetsAt: q["resets_at"] as? String)
        }
        return GoogleLoginResult(token: token,
                                 tenant: j["tenant"] as? String ?? "",
                                 email: j["email"] as? String ?? "",
                                 tier: j["tier"] as? String ?? "",
                                 trialUntil: j["trial_until"] as? String,
                                 quota: quota)
    }

    /// POST /v1/auth/google {code, code_verifier} (kept: for the Web-client local simulation flow).
    func loginGoogle(code: String, verifier: String) async throws -> GoogleLoginResult {
        let (code2, data) = try await request("POST", "/v1/auth/google",
                                              body: ["code": code, "code_verifier": verifier])
        let j = decodeJSON(data)
        guard (200...299).contains(code2), let token = j["token"] as? String else {
            throw APIError.http(code2, String(decoding: data, as: UTF8.self))
        }
        let quota = (j["quota"] as? [String: Any]).map { q in
            GoogleLoginResult.GoogleQuota(used: q["used"] as? Int,
                                         limit: q["limit"] as? Int,
                                         resetsAt: q["resets_at"] as? String)
        }
        return GoogleLoginResult(token: token,
                                 tenant: j["tenant"] as? String ?? "",
                                 email: j["email"] as? String ?? "",
                                 tier: j["tier"] as? String ?? "",
                                 trialUntil: j["trial_until"] as? String,
                                 quota: quota)
    }

    /// GET /v1/me -> refresh sign-in state (tier/quota/trial).
    func me() async throws -> MeResult {
        let (code, data) = try await request("GET", "/v1/me")
        let j = decodeJSON(data)
        guard (200...299).contains(code) else {
            throw APIError.http(code, String(decoding: data, as: UTF8.self))
        }
        let quota = (j["quota"] as? [String: Any]).map { q in
            GoogleLoginResult.GoogleQuota(used: q["used"] as? Int,
                                         limit: q["limit"] as? Int,
                                         resetsAt: q["resets_at"] as? String)
        }
        return MeResult(tenant: j["tenant"] as? String ?? "",
                        email: j["email"] as? String ?? "",
                        tier: j["tier"] as? String ?? "",
                        trialUntil: j["trial_until"] as? String,
                        quota: quota)
    }

    /// GET /v1/roles -> multi-role collapsed bar data (active state).
    func roles() async throws -> RolesResponse {
        let (code, data) = try await request("GET", "/v1/roles")
        let j = decodeJSON(data)
        guard (200...299).contains(code) else {
            throw APIError.http(code, String(decoding: data, as: UTF8.self))
        }
        let rs = (j["roles"] as? [[String: Any]])?.map { o -> RoleInfo in
            RoleInfo(id: o["id"] as? String ?? "",
                     label: o["label"] as? String ?? "",
                     active: o["active"] as? Bool ?? false)
        } ?? []
        return RolesResponse(roles: rs,
                             taskId: j["task_id"] as? String,
                             role: j["role"] as? String)
    }

    // MARK: - Machine-code binding (self-hosted)

    /// POST /v1/devices/lookup {machine_code} -> cloud locates the machine (identity + intranet address + online state).
    /// Always hits the cloud base (cloudBase), independent of the currently selected self-hosted server.
    func lookupMachine(code: String) async throws -> MachineInfo {
        if Self.machineLookupMock {
            DiagLogger.shared.log("NET", "lookupMachine mock: code=\(Self.masked(code))")
            return MachineInfo(name: "办公室 Mac", base: "http://192.168.8.186:8897", online: true, token: "m7-token")
        }
        let clean = settings.cloudBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: clean + "/v1/devices/lookup") else {
            throw APIError.transport("Invalid cloud address")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-Id")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["machine_code": code])
        DiagLogger.shared.log("NET", "lookupMachine \(url.absoluteString) code=\(Self.masked(code))")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.transport("No HTTP response")
        }
        let j = decodeJSON(data)
        guard (200...299).contains(http.statusCode), let base = j["base"] as? String else {
            // 响应体含访问凭证(token)，诊断日志不落 body（A4 脱敏）。
            DiagLogger.shared.log("NET", "lookupMachine → \(http.statusCode)（响应体含凭证，已脱敏）")
            throw APIError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return MachineInfo(name: j["name"] as? String ?? "Server",
                           base: base,
                           online: j["online"] as? Bool ?? false,
                           token: j["token"] as? String ?? "")
    }

    /// Connectivity probe (pre-save check / direct probe) — independent of the current settings.base;
    /// any base can be probed.
    func healthCheck(base: String) async -> Bool {
        let clean = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: clean + "/v1/health") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 4
        req.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-Id")
        do {
            let (_, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return false }
            DiagLogger.shared.log("NET", "healthCheck \(url.absoluteString) -> \(http.statusCode)")
            return (200...299).contains(http.statusCode)
        } catch {
            DiagLogger.shared.log("NET", "healthCheck \(url.absoluteString) failed: \(error.localizedDescription)")
            return false
        }
    }
}
