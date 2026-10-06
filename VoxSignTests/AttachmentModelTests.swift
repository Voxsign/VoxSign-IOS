//
//  AttachmentModelTests.swift
//  VoxSignTests
//
//  v2.4 attachment-model tests: construct all four kinds, Codable roundtrip, attach to a Bubble.
//

import XCTest
@testable import VoxSign

final class AttachmentModelTests: XCTestCase {

    func testAllKindsConstruct() {
        let text = Attachment(id: "1", kind: .text, title: "Pasted text", text: "body content")
        let url = Attachment(id: "2", kind: .url, title: "Reference link", text: "https://voxsign.ai")
        let image = Attachment(id: "3", kind: .image, title: "Screenshot", localPath: "/tmp/a.png")
        let file = Attachment(id: "4", kind: .file, title: "Report", fileName: "report.pdf", localPath: "/tmp/report.pdf")

        XCTAssertEqual(text.kind, .text)
        XCTAssertEqual(url.kind, .url)
        XCTAssertEqual(image.kind, .image)
        XCTAssertEqual(file.kind, .file)
        XCTAssertEqual(file.fileName, "report.pdf")
    }

    func testKindRawValues() {
        XCTAssertEqual(AttachmentKind.text.rawValue, "text")
        XCTAssertEqual(AttachmentKind.url.rawValue, "url")
        XCTAssertEqual(AttachmentKind.image.rawValue, "image")
        XCTAssertEqual(AttachmentKind.file.rawValue, "file")
    }

    func testCodableRoundtrip() throws {
        let original = Attachment(id: "abc", kind: .file, title: "Contract",
                                  text: "optional note", fileName: "contract.docx",
                                  localPath: "/docs/contract.docx")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Attachment.self, from: data)
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(decoded.kind, .file)
        XCTAssertEqual(decoded.text, "optional note")
        XCTAssertEqual(decoded.fileName, "contract.docx")
    }

    func testCodableRoundtripOptionalNils() throws {
        // Only kind + title, everything else nil: encode/decode must not crash and stay equal.
        let original = Attachment(id: "x", kind: .url, title: "Link")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Attachment.self, from: data)
        XCTAssertEqual(original, decoded)
        XCTAssertNil(decoded.text)
        XCTAssertNil(decoded.fileName)
        XCTAssertNil(decoded.localPath)
    }

    func testAttachToBubble() {
        let att = Attachment(id: "a1", kind: .text, title: "Note", text: "resource sent with the message")
        let bubble = Bubble(text: "tidy this up", fromVoice: false, attachments: [att])
        XCTAssertEqual(bubble.attachments.count, 1)
        XCTAssertEqual(bubble.attachments.first?.kind, .text)
        XCTAssertEqual(bubble.attachments.first?.title, "Note")
    }

    func testStoredMessageCarriesAttachments() throws {
        let att = Attachment(id: "a2", kind: .image, title: "Image", localPath: "/tmp/i.jpg")
        let msg = StoredMessage(id: "m1", role: "user", text: "look at this", attachments: [att])
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(StoredMessage.self, from: data)
        XCTAssertEqual(decoded.attachments.count, 1)
        XCTAssertEqual(decoded.attachments.first?.kind, .image)
    }
}
