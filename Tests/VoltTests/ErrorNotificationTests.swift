import Foundation
import SwiftUI
import Testing
@testable import Volt

extension UploadTests {
    @Test func errorNoticesGroupOnlyWithinTheirBatchAndDismissInOrder() {
        var queue = ErrorNoticeQueue()
        let batch = UUID()
        let tab = UUID()
        let context = OperationErrorContext(tabID: tab, server: "Origin server", localPath: "/local/a",
                                            remotePath: "/remote/a", transferID: UUID(), batchID: batch)
        let failure = AppError.commandFailed("Permission denied")
        let firstEvent = UUID()
        queue.report(failure, operation: "Uploading", context: context, eventID: firstEvent)
        queue.report(failure, operation: "Uploading", context: context, eventID: firstEvent)
        #expect(queue.notices.count == 1)
        #expect(queue.notices[0].failures.count == 1)
        queue.report(failure, operation: "Connecting to SSH", context: OperationErrorContext(server: "Other server"))
        queue.report(failure, operation: "Uploading", context: context)
        #expect(queue.notices.count == 2)
        #expect(queue.notices[0].failures.count == 2)
        #expect(queue.notices[0].details.contains("Origin server"))
        #expect(queue.notices[0].details.contains("/remote/a"))
        #expect(queue.notices[0].failures[0].context.tabID == tab)
        queue.dismiss(queue.notices[0].id)
        #expect(queue.notices[0].failures[0].operation == "Connecting to SSH")
        // A new failure after dismissal must become visible again.
        queue.report(failure, operation: "Uploading", context: context)
        #expect(queue.notices.count == 2)
    }

    @Test func cancellationsDoNotHideActualErrorsOrUnknownPublishOutcomes() {
        var queue = ErrorNoticeQueue()
        let context = OperationErrorContext()
        for message in ["Transfer cancelled.", "Transfer cancelled before publish.", "Upload cancelled."] {
            queue.report(AppError.commandFailed(message), operation: "Uploading", context: context)
        }
        queue.report(CancellationError(), operation: "Search", context: context)
        queue.report(AppError.hostKeyRejected, operation: "Connecting", context: context)
        queue.report(AppError.commandFailed("Connection closed"), operation: "Search", context: context, cancelled: true)
        #expect(queue.notices.isEmpty)
        let message = "Upload publish outcome is unknown. Inspect temporary file /remote/file.volt-part-123 before retrying."
        queue.report(AppError.commandFailed(message), operation: "Uploading", context: context, cancelled: true)
        #expect(queue.notices[0].details.contains(message))
        queue.report(AppError.commandFailed("Server cancelled the request due to an error"), operation: "Uploading", context: context)
        #expect(queue.notices.count == 2)
    }

    @Test func independentErrorsAndLongDetailsAreRetained() {
        var queue = ErrorNoticeQueue()
        let message = String(repeating: "technical details\n", count: 500)
        queue.report(AppError.commandFailed(message), operation: "Downloading", context: OperationErrorContext())
        #expect(queue.notices[0].details.contains(message))
        queue.report(AppError.commandFailed("Authentication failed"), operation: "Connecting to SSH", context: OperationErrorContext())
        #expect(queue.notices.count == 2)
        queue.dismiss(queue.notices[0].id)
        #expect(queue.notices[0].details.contains("Authentication failed"))
        queue.dismiss(queue.notices[0].id)
        #expect(queue.notices.isEmpty)
    }
}

// Optional visual QA: render the real SwiftUI banner without loading user connections.
extension UploadTests {
    @Test @MainActor func errorBannerVisualQA() throws {
        guard let directory = ProcessInfo.processInfo.environment["VOLT_ERROR_SNAPSHOT_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var queue = ErrorNoticeQueue()
        let context = OperationErrorContext(server: "Example server (127.0.0.1:2222)", localPath: "/local/report.txt",
                                            remotePath: "/restricted/report.txt", transferID: UUID(), batchID: UUID())
        queue.report(AppError.commandFailed("Could not create temporary remote upload file. Permission denied (SFTP 3). Failed opening remote file"),
                     operation: "Uploading", context: context)
        queue.report(AppError.commandFailed("Permission denied"), operation: "Uploading", context: context)
        for width in [320.0, 760.0] {
            for expanded in [false, true] {
                let content = ErrorNoticeContent(notice: queue.notices[0], pendingCount: 2,
                    showsDetails: .constant(expanded), onDismiss: {}, onShowTransfers: {})
                    .frame(width: width).background(Color.white).environment(\.colorScheme, .light)
                _ = NSApplication.shared
                let host = NSHostingView(rootView: content)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: folder.appendingPathComponent("banner-\(Int(width))-\(expanded).png"))
            }
        }
    }
}

extension UploadTests {
    @Test @MainActor func modelErrorsSurviveStatusChangesAndTabSwitches() {
        let model = AppModel(startServices: false)
        let origin = model.selectedTabID!
        let context = OperationErrorContext(tabID: origin, server: "Original server", remotePath: "/restricted")
        let secondTab = BrowserTab()
        model.tabs.append(secondTab)
        model.selectedTabID = secondTab.id
        model.reportError(AppError.commandFailed("Permission denied"), operation: "Uploading", context: context)
        model.status = "Remote folder loaded"
        model.status = "Uploaded"
        #expect(model.errorNotices.notices.count == 1)
        #expect(model.errorNotices.notices[0].details.contains("Original server"))
        #expect(model.errorNotices.notices[0].failures[0].context.tabID == origin)
        model.tabs.removeAll { $0.id == origin }
        model.reportError(AppError.commandFailed("Late failure"), operation: "Loading folder", context: context)
        #expect(model.errorNotices.notices.count == 1)
        model.errorNotices.dismiss(model.errorNotices.notices[0].id)
        #expect(model.errorNotices.notices.isEmpty)
    }
}
