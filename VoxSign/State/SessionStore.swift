//
//  SessionStore.swift
//  VoxSign
//
//  v2.4 multi-session store: local persistence + session list (hidden by default).
//  UserDefaults JSON persistence (key "vhs-ios-sessions"); read/write pattern mirrors Net/SettingsStore.swift.
//  Observed: read back on app launch; every mutating method calls persist() explicitly.
//

import Foundation
import Combine

/// Persisted payload: the whole sessions array + current session id.
private struct PersistedState: Codable, Equatable {
    var sessions: [ChatSession]
    var currentID: String
}

/// Session store (singleton). Thread model: same as AppModel; called on the main actor / serialized access.
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    private let defaults: UserDefaults
    private let key = "vhs-ios-sessions"
    private let containerKey = "vhs-ios-containers"

    /// Session list (order = creation order; the view sorts by updatedAt).
    @Published var sessions: [ChatSession] = []
    /// Current session id.
    @Published var currentSessionID: String = ""
    /// V6.2 containers (roles/domains).
    @Published var containers: [ContainerItem] = []

    /// - Parameter defaults: injected for unit-test isolation (default .standard).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let persisted = try? JSONDecoder().decode(PersistedState.self, from: data) {
            sessions = persisted.sessions
            // Back-compat for old data: if the current id is invalid, fall back to the first session.
            if sessions.contains(where: { $0.id == persisted.currentID }) {
                currentSessionID = persisted.currentID
            } else {
                currentSessionID = sessions.first?.id ?? ""
            }
        }
        // V6.2 containers persisted separately (own key; does not touch the old sessions payload).
        if let cdata = defaults.data(forKey: containerKey),
           let cs = try? JSONDecoder().decode([ContainerItem].self, from: cdata) {
            containers = cs
        }
    }

    // MARK: - Session lifecycle

    /// When there are no sessions, create "New Chat" and make it current; idempotent.
    func ensureInitialSession() {
        guard sessions.isEmpty else { return }
        let s = makeSession(title: "New Chat")
        sessions.append(s)
        currentSessionID = s.id
        persist()
    }

    /// Create a session (append + switch current + persist).
    @discardableResult
    func createSession(title: String = "New Chat") -> ChatSession {
        let s = makeSession(title: title)
        sessions.append(s)
        currentSessionID = s.id
        persist()
        return s
    }

    /// V6.2 create an owned session under a container (role/domain).
    @discardableResult
    func createSession(title: String = "New Chat",
                       containerKind: ContainerKind,
                       containerID: String) -> ChatSession {
        let s = makeSession(title: title,
                            containerKind: containerKind,
                            containerID: containerID)
        sessions.append(s)
        currentSessionID = s.id
        persist()
        return s
    }

    // MARK: - V6.2 containers (roles/domains)

    /// Filter the container list by kind.
    func containers(of kind: ContainerKind) -> [ContainerItem] {
        containers.filter { $0.kind == kind }
    }

    /// Create or reuse a container (same name+kind returns the existing one idempotently). Persisted.
    @discardableResult
    func upsertContainer(kind: ContainerKind, name: String) -> ContainerItem {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? (kind == .role ? "New Role" : "New Domain") : trimmed
        if let hit = containers.first(where: { $0.kind == kind && $0.name == finalName }) {
            return hit
        }
        let c = ContainerItem(id: UUID().uuidString, kind: kind, name: finalName)
        containers.append(c)
        persistContainers()
        return c
    }

    /// Delete a container (its child sessions are deleted too; allowed as long as at least one session remains).
    @discardableResult
    func deleteContainer(id: String) -> Bool {
        guard let c = containers.first(where: { $0.id == id }) else { return false }
        let childIDs = sessions.filter { $0.containerID == id }.map { $0.id }
        containers.removeAll { $0.id == id }
        sessions.removeAll { $0.containerID == id }
        if childIDs.contains(currentSessionID) {
            currentSessionID = sessions.first?.id ?? ""
        }
        persistContainers()
        persist()
        return true
    }

    /// Delete a session; rejected when sessions.count <= 1 (returns false).
    @discardableResult
    func deleteSession(id: String) -> Bool {
        guard sessions.count > 1 else { return false }
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return false }
        sessions.remove(at: idx)
        if currentSessionID == id {
            currentSessionID = sessions.first?.id ?? ""
        }
        persist()
        return true
    }

    func renameSession(id: String, title: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].title = title
        sessions[idx].updatedAt = Date()
        persist()
    }

    // MARK: - V6.3 talk-then-file: filing / unfiling sessions

    /// File a session into a container (role/domain).
    func setContainer(sessionID: String, kind: ContainerKind, containerID: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[idx].containerKind = kind
        sessions[idx].containerID = containerID
        sessions[idx].updatedAt = Date()
        persist()
    }

    /// Move back to ungrouped (clear ownership).
    func clearContainer(sessionID: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[idx].containerKind = nil
        sessions[idx].containerID = nil
        sessions[idx].updatedAt = Date()
        persist()
    }

    /// Switch current + persist.
    func switchTo(id: String) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        currentSessionID = id
        persist()
    }

    // MARK: - Messages

    /// Overwrite a session's messages and refresh updatedAt.
    func saveMessages(_ messages: [StoredMessage], for sessionID: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[idx].messages = messages
        sessions[idx].updatedAt = Date()
        persist()
    }

    func loadMessages(for sessionID: String) -> [StoredMessage] {
        sessions.first { $0.id == sessionID }?.messages ?? []
    }

    /// Mark a session as updated (updatedAt = now) + persist.
    func touch(sessionID: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[idx].updatedAt = Date()
        persist()
    }

    // MARK: - Convenience access

    var currentSession: ChatSession? {
        sessions.first { $0.id == currentSessionID } ?? sessions.first
    }

    // MARK: - Internal

    private func makeSession(title: String) -> ChatSession {
        ChatSession(id: UUID().uuidString,
                    title: title,
                    createdAt: Date(),
                    updatedAt: Date(),
                    messages: [])
    }

    private func makeSession(title: String,
                             containerKind: ContainerKind,
                             containerID: String) -> ChatSession {
        ChatSession(id: UUID().uuidString,
                    title: title,
                    createdAt: Date(),
                    updatedAt: Date(),
                    messages: [],
                    containerKind: containerKind,
                    containerID: containerID)
    }

    private func persist() {
        let state = PersistedState(sessions: sessions, currentID: currentSessionID)
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: key)
        }
    }

    private func persistContainers() {
        if let data = try? JSONEncoder().encode(containers) {
            defaults.set(data, forKey: containerKey)
        }
    }
}
