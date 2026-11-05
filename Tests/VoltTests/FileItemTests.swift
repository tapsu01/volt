import Foundation
import Testing
@testable import Volt

@Suite(.timeLimit(.minutes(1)))
struct FileItemTests {
    private func item(isDirectory: Bool, permissions: UInt32?) -> FileItem {
        FileItem(name: "x", path: "/remote/x", isDirectory: isDirectory, permissions: permissions)
    }

    @Test func symlinkIsDetectedFromModeBits() {
        #expect(item(isDirectory: false, permissions: 0o120777).isSymlink)
        #expect(!item(isDirectory: false, permissions: 0o100644).isSymlink)
        #expect(!item(isDirectory: true, permissions: 0o040755).isSymlink)
        #expect(!item(isDirectory: false, permissions: nil).isSymlink)
    }

    @Test func unresolvedSymlinkIsNotAFolderUntilStatConfirmsIt() {
        var link = item(isDirectory: false, permissions: 0o120777)
        #expect(!link.opensAsFolder)
        #expect(!link.isRegularFile)
        #expect(link.iconName(folder: "folder.fill", file: "doc") == "link")

        link.linkTargetIsDirectory = true
        #expect(link.opensAsFolder)
        #expect(!link.isDirectory, "traversal must keep treating the link as a non-directory")
        #expect(link.iconName(folder: "folder.fill", file: "doc") == "folder.fill")
    }

    @Test func plainEntriesKeepTheirIcons() {
        #expect(item(isDirectory: true, permissions: 0o040755).iconName(folder: "folder", file: "doc") == "folder")
        #expect(item(isDirectory: false, permissions: 0o100644).iconName(folder: "folder", file: "doc") == "doc")
    }
}
