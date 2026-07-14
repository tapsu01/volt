import Foundation
import XCTest
@testable import VoltCore

final class PathSafetyTests: XCTestCase {
    private let base = URL(fileURLWithPath: "/tmp/base")

    func testRejectsTraversal() {
        XCTAssertNil(safeLocalDestination(base: base, name: "../x"))
        XCTAssertNil(safeLocalDestination(base: base, name: ".."))
        XCTAssertNil(safeLocalDestination(base: base, name: "."))
    }

    func testRejectsPathSeparator() {
        XCTAssertNil(safeLocalDestination(base: base, name: "a/b"))
        XCTAssertNil(safeLocalDestination(base: base, name: "/etc/passwd"))
        XCTAssertNil(safeLocalDestination(base: base, name: "sub/../../x"))
    }

    func testRejectsEmpty() {
        XCTAssertNil(safeLocalDestination(base: base, name: ""))
    }

    func testRejectsControlAndNulCharacters() {
        XCTAssertNil(safeLocalDestination(base: base, name: "a\u{0}b"))
        XCTAssertNil(safeLocalDestination(base: base, name: "a\u{01}b"))
        XCTAssertNil(safeLocalDestination(base: base, name: "a\u{7f}b"))
        XCTAssertNil(safeLocalDestination(base: base, name: "line\nbreak"))
    }

    func testAcceptsOrdinaryNames() {
        for name in ["file.txt", "name with spaces.txt", ".env", "archive.tar.gz",
                     "..hidden", "file..txt", "document.pdf", "...", "cafe.md"] {
            guard let destination = safeLocalDestination(base: base, name: name) else {
                XCTFail("Expected safe destination for \(name)")
                continue
            }
            XCTAssertEqual(destination.deletingLastPathComponent().path, base.path)
            XCTAssertEqual(destination.lastPathComponent, name)
        }
    }

    func testAcceptsLongNameWithinLimit() {
        let name = String(repeating: "a", count: 255)
        XCTAssertEqual(name.utf8.count, 255)
        XCTAssertNotNil(safeLocalDestination(base: base, name: name))
    }

    func testContainmentDoesNotConfusePrefix() {
        let destination = safeLocalDestination(base: base, name: "file.txt")
        XCTAssertNotNil(destination)
        XCTAssertEqual(destination?.path, "/tmp/base/file.txt")
        XCTAssertFalse(destination?.path.hasPrefix("/tmp/base2") ?? true)

        let base2 = URL(fileURLWithPath: "/tmp/base2")
        XCTAssertEqual(safeLocalDestination(base: base2, name: "file.txt")?.path, "/tmp/base2/file.txt")
    }
}
