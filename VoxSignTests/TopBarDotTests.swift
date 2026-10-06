//
//  TopBarDotTests.swift
//  VoxSignTests
//
//  v2.4 top-bar status-dot pure-function tests: all connection-state x harness-state mappings.
//

import XCTest
@testable import VoxSign

final class TopBarDotTests: XCTestCase {

    // offline is always red (regardless of harness state).
    func testOfflineAlwaysRed() {
        XCTAssertEqual(TopBarDot.tone(conn: .offline, harness: .idle), .red)
        XCTAssertEqual(TopBarDot.tone(conn: .offline, harness: .busy), .red)
        XCTAssertEqual(TopBarDot.tone(conn: .offline, harness: .decision), .red)
    }

    // online: decision -> orange.
    func testOnlineDecisionOrange() {
        XCTAssertEqual(TopBarDot.tone(conn: .online, harness: .decision), .orange)
    }

    // online: busy / idle -> blue.
    func testOnlineBusyAndIdleBlue() {
        XCTAssertEqual(TopBarDot.tone(conn: .online, harness: .busy), .blue)
        XCTAssertEqual(TopBarDot.tone(conn: .online, harness: .idle), .blue)
    }

    // reconnecting / unknown -> gray (regardless of harness state).
    func testReconnectingAndUnknownGray() {
        for conn: ConnectionState in [.reconnecting, .unknown] {
            XCTAssertEqual(TopBarDot.tone(conn: conn, harness: .idle), .gray)
            XCTAssertEqual(TopBarDot.tone(conn: conn, harness: .busy), .gray)
            XCTAssertEqual(TopBarDot.tone(conn: conn, harness: .decision), .gray)
        }
    }
}
