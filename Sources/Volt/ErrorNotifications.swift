import Foundation
import SwiftUI

struct OperationErrorContext: Equatable, Sendable {
    var tabID: UUID?
    var server: String?
    var localPath: String?
    var remotePath: String?
    var transferID: UUID?
    var batchID: UUID?
}

struct OperationFailure: Identifiable, Equatable, Sendable {
    let id: UUID
    let operation: String
    let message: String
    let context: OperationErrorContext

    var details: String {
        var lines = ["\(operation): \(message)"]
        if let server = context.server { lines.append("Server: \(server)") }
        if let path = context.localPath { lines.append("Local: \(path)") }
        if let path = context.remotePath { lines.append("Remote: \(path)") }
        return lines.joined(separator: "\n")
    }
}

struct ErrorNotice: Identifiable, Equatable, Sendable {
    let id: UUID
    let batchID: UUID?
    var failures: [OperationFailure]
    var title: String {
        failures.count > 1 ? "\(failures.count) operations failed" : "\(failures[0].operation) failed"
    }
    var details: String { failures.map(\.details).joined(separator: "\n\n") }
}

struct ErrorNoticeQueue: Sendable {
    private(set) var notices: [ErrorNotice] = []

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let appError = error as? AppError, case .hostKeyRejected = appError { return true }
        // These exact messages originate from Volt's explicit Cancel actions.
        return ["Transfer cancelled.", "Transfer cancelled before publish.", "Upload cancelled.",
                "Host key verification cancelled."].contains(error.localizedDescription)
    }

    mutating func report(_ error: Error, operation: String, context: OperationErrorContext,
                         eventID: UUID = UUID(), cancelled: Bool = false) {
        let requiresInspection = error.localizedDescription.contains("Upload publish outcome is unknown.")
        guard requiresInspection || (!cancelled && !Self.isCancellation(error)) else { return }
        guard !notices.contains(where: { $0.failures.contains(where: { $0.id == eventID }) }) else { return }
        let failure = OperationFailure(id: eventID, operation: operation,
                                       message: error.localizedDescription, context: context)
        if let batchID = context.batchID, let index = notices.firstIndex(where: { $0.batchID == batchID }) {
            notices[index].failures.append(failure)
        } else {
            notices.append(ErrorNotice(id: UUID(), batchID: context.batchID, failures: [failure]))
        }
    }

    mutating func dismiss(_ id: UUID) { notices.removeAll { $0.id == id } }
}

struct ErrorBanner: View {
    @ObservedObject var model: AppModel
    @State private var showsDetails = false

    var body: some View {
        if let notice = model.errorNotices.notices.first {
            ErrorNoticeContent(notice: notice, pendingCount: model.errorNotices.notices.count,
                               showsDetails: $showsDetails, onDismiss: {
                model.errorNotices.dismiss(notice.id)
            }, onShowTransfers: {
                model.transferPanelTab = .transfers
                model.showsTransfers = true
            })
            .onChange(of: notice.id) { _, _ in showsDetails = false }
        }
    }
}

struct ErrorNoticeContent: View {
    let notice: ErrorNotice
    let pendingCount: Int
    @Binding var showsDetails: Bool
    let onDismiss: () -> Void
    let onShowTransfers: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text(notice.title).fontWeight(.semibold)
                    Text(notice.failures[0].message).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    detailButtons
                    Spacer(minLength: 8)
                    dismissButtons
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack { detailButtons }
                    HStack { dismissButtons }
                }
            }
            if showsDetails {
                ScrollView {
                    Text(notice.details)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
                Button("Copy Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(notice.details, forType: .string)
                }
            }
        }
        .font(.callout)
        .padding(10)
        .background(Color.red.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var detailButtons: some View {
        Button(showsDetails ? "Hide Details" : "Details") { showsDetails.toggle() }
        if notice.failures.contains(where: { $0.context.transferID != nil }) {
            Button("Show Transfers", action: onShowTransfers)
        }
    }

    @ViewBuilder private var dismissButtons: some View {
        if pendingCount > 1 {
            Text("\(pendingCount) notices").foregroundStyle(.secondary)
        }
        Button("Dismiss", action: onDismiss)
    }
}
