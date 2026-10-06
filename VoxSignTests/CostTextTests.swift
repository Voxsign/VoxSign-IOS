//
//  CostTextTests.swift
//  VoxSignTests
//
//  Pure-function tests for the usage caption: hidden when the server returns nil;
//  otherwise formatted as "Used n".
//

import XCTest
@testable import VoxSign

final class CostTextTests: XCTestCase {

    // Server returns nil -> whole row hidden.
    func testNilHidesRow() {
        XCTAssertNil(CostText.caption(for: nil))
    }

    // 0 is shown as-is (server reports 0 tokens).
    func testZeroFormatted() {
        XCTAssertEqual(CostText.caption(for: 0), "Used 0")
    }

    // Typical usage.
    func testTypicalTokens() {
        XCTAssertEqual(CostText.caption(for: 123), "Used 123")
    }

    // Large token count.
    func testLargeTokens() {
        XCTAssertEqual(CostText.caption(for: 987654), "Used 987654")
    }
}
