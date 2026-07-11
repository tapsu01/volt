import Testing
import Foundation
@testable import VoltCore

private let base = URL(fileURLWithPath: "/tmp/base")

// MARK: - Phải bị từ chối (nil)

@Test func rejectsTraversal() {
    #expect(safeLocalDestination(base: base, name: "../x") == nil)
    #expect(safeLocalDestination(base: base, name: "..") == nil)
    #expect(safeLocalDestination(base: base, name: ".") == nil)
}

@Test func rejectsPathSeparator() {
    #expect(safeLocalDestination(base: base, name: "a/b") == nil)
    #expect(safeLocalDestination(base: base, name: "/etc/passwd") == nil)
    #expect(safeLocalDestination(base: base, name: "sub/../../x") == nil)
}

@Test func rejectsEmpty() {
    #expect(safeLocalDestination(base: base, name: "") == nil)
}

@Test func rejectsControlAndNulCharacters() {
    #expect(safeLocalDestination(base: base, name: "a\u{0}b") == nil)   // NUL
    #expect(safeLocalDestination(base: base, name: "a\u{01}b") == nil)  // control byte
    #expect(safeLocalDestination(base: base, name: "a\u{7f}b") == nil)  // DEL
    #expect(safeLocalDestination(base: base, name: "line\nbreak") == nil)
}

// MARK: - Phải hợp lệ (đích nằm trong base)

@Test func acceptsOrdinaryNames() {
    for name in ["file.txt", "tên có dấu cách.txt", ".env", "archive.tar.gz",
                 "..hidden", "file..txt", "tài liệu.pdf", "...", "café.md"] {
        guard let dest = safeLocalDestination(base: base, name: name) else {
            Issue.record("Đáng lẽ hợp lệ: \(name)")
            continue
        }
        // Đích phải là base + đúng 1 component, đúng tên.
        #expect(dest.deletingLastPathComponent().path == base.path, "Sai thư mục cha cho: \(name)")
        #expect(dest.lastPathComponent == name, "Sai tên cho: \(name)")
    }
}

// Tên dài 255 UTF-8 bytes: chỉ khẳng định KHÔNG bị coi nhầm là traversal — không khẳng định
// download sẽ thành công (filesystem thực có thể từ chối, đó là chuyện của tầng ghi).
@Test func acceptsLongNameWithinLimit() {
    let name = String(repeating: "a", count: 255) // 255 ký tự ASCII = 255 UTF-8 bytes
    #expect(name.utf8.count == 255)
    #expect(safeLocalDestination(base: base, name: name) != nil)
}

// MARK: - Containment: không nhầm prefix chuỗi

@Test func containmentDoesNotConfusePrefix() {
    // Với base /tmp/base, một component đơn không thể tạo ra đích trong /tmp/base2.
    let dest = safeLocalDestination(base: base, name: "file.txt")
    #expect(dest != nil)
    #expect(dest?.path == "/tmp/base/file.txt")
    #expect(dest?.path.hasPrefix("/tmp/base2") == false)

    // base khác (base vs base2) cho đích khác, không lẫn.
    let base2 = URL(fileURLWithPath: "/tmp/base2")
    #expect(safeLocalDestination(base: base2, name: "file.txt")?.path == "/tmp/base2/file.txt")
}
