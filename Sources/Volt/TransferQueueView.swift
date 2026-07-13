import Foundation
import SwiftUI

struct TransferQueueView: View {
    @ObservedObject var model: AppModel
    var layout: AppLayoutContext
    @AppStorage("Volt.TransferQueueHeight") private var expandedHeight: Double = 210
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            if model.showsTransfers {
                resizeHandle
                if layout.isQueueCompact {
                    compactExpandedQueue
                } else {
                    expandedQueue
                }
                Divider()
            }

            compactBar
        }
        .background(VoltTheme.transferBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(VoltTheme.hairline)
                .frame(height: 1)
        }
    }

    private var queueHeight: CGFloat {
        min(420, max(150, CGFloat(expandedHeight)))
    }

    private var tableHeight: CGFloat {
        max(90, queueHeight - 70)
    }

    private var resizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(VoltTheme.transferPanelBackground)
            Capsule()
                .fill(VoltTheme.hairline)
                .frame(width: 46, height: 4)
        }
        .frame(height: 10)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = dragStartHeight ?? queueHeight
                    dragStartHeight = start
                    expandedHeight = Double(min(420, max(150, start - value.translation.height)))
                }
                .onEnded { _ in
                    dragStartHeight = nil
                }
        )
        .help("Drag to resize transfers")
    }

    private var expandedQueue: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Transfers")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    model.showsTransfers = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Table(model.transfers) {
                TableColumn("Direction") { Text($0.direction.rawValue) }.width(90)
                TableColumn("Source") { Text($0.source).lineLimit(1) }
                TableColumn("Destination") { Text($0.destination).lineLimit(1) }
                TableColumn("State") { Text($0.state.rawValue) }.width(80)
                TableColumn("Progress") { job in
                    if job.totalBytes > 0 {
                        let fraction = min(1, Double(job.transferredBytes) / Double(job.totalBytes))
                        VStack(alignment: .leading, spacing: 2) {
                            ProgressView(value: fraction)
                            Text("\(Int(fraction * 100))% · \(ByteCountFormatter.string(fromByteCount: Int64(job.transferredBytes), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(job.totalBytes), countStyle: .file))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else if job.transferredBytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(job.transferredBytes), countStyle: .file))
                    } else {
                        Text("--").foregroundStyle(.secondary)
                    }
                }.width(min: 150, ideal: 210)
                TableColumn("Message") { Text($0.message).lineLimit(1) }
                TableColumn("") { job in
                    Button("Cancel") {
                        model.cancelTransfer(job.id)
                    }
                    .disabled(job.state != .queued && job.state != .running)
                }.width(70)
            }
            .frame(height: tableHeight)
            .background(VoltTheme.paneBackground)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(VoltTheme.hairline)
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .frame(height: queueHeight)
        .background(VoltTheme.transferPanelBackground)
    }

    private var compactExpandedQueue: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transfers")
                    .font(.headline)
                Spacer()
                Button {
                    model.showsTransfers = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if model.transfers.isEmpty {
                Text("No transfers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.transfers) { job in
                            compactTransferRow(job)
                        }
                    }
                }
                .frame(maxHeight: 126)
            }
        }
        .padding(10)
        .background(VoltTheme.transferPanelBackground)
    }

    private var compactBar: some View {
        HStack(spacing: 14) {
            if layout.isQueueCompact {
                Image(systemName: model.isBusy ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                    .foregroundStyle(model.isBusy ? Color.accentColor : Color.secondary)
                Text(model.status)
                    .lineLimit(1)
                    .foregroundStyle(VoltTheme.mutedText)
            } else if let first = primaryTransfer {
                transferChip(first)
                if let second = secondaryTransfer {
                    Divider().frame(height: 26)
                    transferChip(second)
                }
                Divider().frame(height: 26)
            } else {
                Image(systemName: model.isBusy ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                    .foregroundStyle(model.isBusy ? Color.accentColor : Color.secondary)
                Text(model.status)
                    .lineLimit(1)
                    .foregroundStyle(VoltTheme.mutedText)
            }

            Button {
                model.showsTransfers.toggle()
            } label: {
                Text("\(model.transfers.count) transfers")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.plain)
            .help("Toggle transfer queue")

            Text(totalProgressText)
                .foregroundStyle(VoltTheme.mutedText)
                .lineLimit(1)

            if let etaText {
                Text("ETA \(etaText)")
                    .foregroundStyle(VoltTheme.mutedText)
                    .monospacedDigit()
            }

            Spacer(minLength: 12)

            if model.isBusy && !layout.isQueueCompact {
                ProgressView()
                    .controlSize(.small)
            }

            if !layout.isQueueCompact {
                Text(model.status)
                    .foregroundStyle(VoltTheme.mutedText)
                    .lineLimit(1)
                    .frame(maxWidth: 260, alignment: .trailing)
            }

            Button {
                model.showsTransfers.toggle()
            } label: {
                Image(systemName: model.showsTransfers ? "chevron.down" : "chevron.up")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help(model.showsTransfers ? "Hide transfers" : "Show transfers")
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(VoltTheme.transferBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(VoltTheme.hairline)
                .frame(height: 1)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.accentColor.opacity(model.transfers.isEmpty ? 0.0 : 0.75))
                .frame(width: 3)
        }
    }

    private func compactTransferRow(_ job: TransferJob) -> some View {
        HStack(spacing: 9) {
            Image(systemName: job.direction == .upload ? "square.and.arrow.up" : "square.and.arrow.down")
                .foregroundStyle(job.direction == .upload ? Color.accentColor : Color.green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: job.source).lastPathComponent)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text("\(job.direction.rawValue) · \(job.state.rawValue)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            ProgressView(value: progress(for: job))
                .frame(width: 86)
            Text("\(Int(progress(for: job) * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(VoltTheme.controlBackground)
        )
    }

    private var primaryTransfer: TransferJob? {
        model.transfers.first { $0.state == .running || $0.state == .queued } ?? model.transfers.first
    }

    private var secondaryTransfer: TransferJob? {
        guard let primaryTransfer else { return nil }
        return model.transfers.first { $0.id != primaryTransfer.id && ($0.state == .running || $0.state == .queued) }
    }

    private var totalProgressText: String {
        let transferred = model.transfers.reduce(UInt64(0)) { $0 + $1.transferredBytes }
        let total = model.transfers.reduce(UInt64(0)) { $0 + $1.totalBytes }
        guard total > 0 else { return "Total --" }
        return "Total \(ByteCountFormatter.string(fromByteCount: Int64(transferred), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))"
    }

    private func transferChip(_ job: TransferJob) -> some View {
        HStack(spacing: 9) {
            Image(systemName: job.direction == .upload ? "square.and.arrow.up" : "square.and.arrow.down")
                .foregroundStyle(job.direction == .upload ? Color.accentColor : Color.green)
            Text(URL(fileURLWithPath: job.source).lastPathComponent)
                .fontWeight(.medium)
                .lineLimit(1)
                .frame(maxWidth: 160, alignment: .leading)
            ProgressView(value: progress(for: job))
                .frame(width: 92)
            Text("\(Int(progress(for: job) * 100))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
            if let speed = speedText(for: job) {
                Text(speed)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func progress(for job: TransferJob) -> Double {
        guard job.totalBytes > 0 else {
            return job.state == .done ? 1 : 0
        }
        return min(1, Double(job.transferredBytes) / Double(job.totalBytes))
    }

    private var etaText: String? {
        let remaining = model.transfers.reduce(UInt64(0)) { partial, job in
            guard job.totalBytes > job.transferredBytes else { return partial }
            return partial + (job.totalBytes - job.transferredBytes)
        }
        guard remaining > 0, let bytesPerSecond = aggregateBytesPerSecond, bytesPerSecond > 0 else { return nil }
        return durationText(seconds: TimeInterval(Double(remaining) / bytesPerSecond))
    }

    private var aggregateBytesPerSecond: Double? {
        let running = model.transfers.filter { $0.state == .running || $0.state == .queued }
        let transferred = running.reduce(UInt64(0)) { $0 + $1.transferredBytes }
        guard transferred > 0 else { return nil }
        let earliestStart = running.compactMap(\.startedAt).min()
        guard let earliestStart else { return nil }
        let elapsed = max(0.5, Date().timeIntervalSince(earliestStart))
        return Double(transferred) / elapsed
    }

    private func speedText(for job: TransferJob) -> String? {
        guard let startedAt = job.startedAt, job.transferredBytes > 0 else { return nil }
        let elapsed = max(0.5, (job.updatedAt ?? Date()).timeIntervalSince(startedAt))
        let bytesPerSecond = Double(job.transferredBytes) / elapsed
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    private func durationText(seconds: TimeInterval) -> String {
        let wholeSeconds = max(0, Int(seconds.rounded()))
        let minutes = wholeSeconds / 60
        let seconds = wholeSeconds % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            return "\(hours)h \(remainingMinutes)m"
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
