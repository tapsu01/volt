import Foundation
import Testing
import VoltCore

@Suite(.timeLimit(.minutes(1)))
struct RemotePathTests {
    @Test func lastComponent() {
        #expect(RemotePath.lastComponent("/home/stackops") == "stackops")
        #expect(RemotePath.lastComponent("/home/stackops/") == "stackops")
        #expect(RemotePath.lastComponent("/") == "/")
        #expect(RemotePath.lastComponent("") == "")
        #expect(RemotePath.lastComponent("/var/log/app.log") == "app.log")
    }

    @Test func parent() {
        #expect(RemotePath.parent("/home/stackops") == "/home")
        #expect(RemotePath.parent("/home") == "/")
        #expect(RemotePath.parent("/") == "/")
        #expect(RemotePath.parent("/a/b/") == "/a")
        #expect(RemotePath.parent("") == "/")
    }

    @Test func join() {
        #expect(RemotePath.join("/", "x") == "/x")
        #expect(RemotePath.join("/a", "b") == "/a/b")
        #expect(RemotePath.join("/a/", "b") == "/a/b")
        #expect(RemotePath.join("a", "b") == "/a/b")
    }

    @Test func fileExtension() {
        #expect(RemotePath.fileExtension("/x/y.tar.gz") == "gz")
        #expect(RemotePath.fileExtension("/x/README") == "")
        #expect(RemotePath.fileExtension("/x/.bashrc") == "")
    }
}
