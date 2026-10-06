//
//  SessionStoreTests.swift
//  VoxSignTests
//
//  v2.4 session-store tests: idempotent init / create-switch-delete / cross-session message isolation /
//  deleting the last session is rejected / persistence reload.
//  Uses an isolated UserDefaults suite so the standard suite is never polluted.
//

import XCTest
@testable import VoxSign

final class SessionStoreTests: XCTestCase {

    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "vhs-session-test-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        suiteName = nil
    }

    private func makeStore() -> SessionStore {
        // Build a fresh instance each time to simulate an in-process reload.
        SessionStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    // MARK: - ensureInitialSession idempotent

    func testEnsureInitialSessionIdempotent() {
        let store = makeStore()
        XCTAssertEqual(store.sessions.count, 0, "a brand-new store should be empty")
        store.ensureInitialSession()
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.title, "New Chat")
        XCTAssertEqual(store.currentSessionID, store.sessions.first?.id)

        // Calling again must not create a duplicate.
        store.ensureInitialSession()
        XCTAssertEqual(store.sessions.count, 1, "ensureInitialSession is idempotent")
    }

    // MARK: - create / switch / delete

    func testCreateSwitchDelete() {
        let store = makeStore()
        store.ensureInitialSession()
        let first = store.currentSession!

        let second = store.createSession(title: "Work")
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.currentSessionID, second.id, "creating switches to the new session")

        store.switchTo(id: first.id)
        XCTAssertEqual(store.currentSessionID, first.id)

        // Delete a non-current session.
        XCTAssertTrue(store.deleteSession(id: second.id))
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.currentSessionID, first.id, "deleting a non-current session does not change the current one")
    }

    func testDeleteCurrentSessionFallsBack() {
        let store = makeStore()
        store.ensureInitialSession()
        let first = store.currentSession!
        let second = store.createSession(title: "Temp")

        // The current session is second; deleting second -> fall back to the remaining first.
        XCTAssertEqual(store.currentSessionID, second.id)
        XCTAssertTrue(store.deleteSession(id: second.id))
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.currentSessionID, first.id, "after deleting the current session, switch to the remaining first")
    }

    // MARK: - Cross-session message isolation

    func testCrossSessionMessageIsolation() {
        let store = makeStore()
        store.ensureInitialSession()
        let a = store.currentSession!
        let b = store.createSession(title: "Session B")

        // Session A stores a message.
        store.saveMessages([StoredMessage(id: "m-a1", role: "user", text: "A's message")], for: a.id)

        // Switch to B and store different messages.
        store.switchTo(id: b.id)
        store.saveMessages([StoredMessage(id: "m-b1", role: "user", text: "B's message"),
                            StoredMessage(id: "m-b2", role: "harness", text: "B's reply")], for: b.id)

        // Switch back to A: data intact, not polluted by B.
        store.switchTo(id: a.id)
        let aMsgs = store.loadMessages(for: a.id)
        XCTAssertEqual(aMsgs.count, 1)
        XCTAssertEqual(aMsgs.first?.text, "A's message")

        // B's data is independent.
        let bMsgs = store.loadMessages(for: b.id)
        XCTAssertEqual(bMsgs.count, 2)
        XCTAssertEqual(bMsgs.first?.text, "B's message")
    }

    // MARK: - Deleting the last session is rejected

    func testDeleteLastSessionRejected() {
        let store = makeStore()
        store.ensureInitialSession()
        XCTAssertEqual(store.sessions.count, 1)
        let only = store.currentSession!

        XCTAssertFalse(store.deleteSession(id: only.id), "deleting the only session should be rejected")
        XCTAssertEqual(store.sessions.count, 1, "rejected: session count unchanged")
        XCTAssertEqual(store.currentSessionID, only.id)
    }

    // MARK: - Persistence reload

    func testPersistenceReload() {
        let store = makeStore()
        store.ensureInitialSession()
        let b = store.createSession(title: "Persistence test")
        store.saveMessages([StoredMessage(id: "m1", role: "user", text: "message to persist")], for: b.id)
        store.switchTo(id: b.id)

        // A fresh instance reads back (same suite).
        let reloaded = SessionStore(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(reloaded.sessions.count, 2, "session count restored after reload")
        XCTAssertEqual(reloaded.currentSessionID, b.id, "current session id restored after reload")
        let msgs = reloaded.loadMessages(for: b.id)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs.first?.text, "message to persist")
        XCTAssertEqual(reloaded.sessions.first(where: { $0.id == b.id })?.title, "Persistence test")
    }

    // MARK: - rename / touch

    func testRenameAndTouch() {
        let store = makeStore()
        store.ensureInitialSession()
        let id = store.currentSessionID
        store.renameSession(id: id, title: "New title")
        XCTAssertEqual(store.sessions.first?.title, "New title")

        let before = store.sessions.first?.updatedAt ?? Date.distantPast
        // touch refreshes updatedAt.
        Thread.sleep(forTimeInterval: 0.05)
        store.touch(sessionID: id)
        let after = store.sessions.first?.updatedAt ?? Date.distantPast
        XCTAssertGreaterThan(after, before)
    }
}
