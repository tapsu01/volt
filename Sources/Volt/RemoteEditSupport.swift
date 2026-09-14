import Foundation

/// An immutable upload input, independent of later editor saves (including atomic saves).
struct RemoteEditUploadSnapshot: Sendable {
    let url: URL

    init(localPath: String) throws {
        let source = URL(fileURLWithPath: localPath)
        url = source.deletingLastPathComponent().appendingPathComponent(".upload-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: url)
    }

    func publishBaseline(to path: String) throws {
        try Data(contentsOf: url).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func matches(localPath: String) -> Bool {
        FileManager.default.contentsEqual(atPath: url.path, andPath: localPath)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

extension RemoteEditSession {
    /// Returns true once per stable saved version; the caller decides whether to ask or remain manual.
    mutating func observeSave(size: UInt64, modifiedAt: Date?, now: Date = Date()) -> Bool {
        guard state != .uploading else { return false }
        let signature = "\(size):\(modifiedAt?.timeIntervalSince1970 ?? 0)"
        let previous = "\(lastObservedSize):\(lastObservedModifiedAt?.timeIntervalSince1970 ?? 0)"
        guard signature != previous || (state == .modified && lastPromptedChangeSignature == nil) else {
            pendingChangeSignature = nil
            pendingChangeDetectedAt = nil
            return false
        }
        if pendingChangeSignature == signature, let detectedAt = pendingChangeDetectedAt,
           now.timeIntervalSince(detectedAt) >= 1, lastPromptedChangeSignature != signature {
            state = .modified
            lastObservedSize = size
            lastObservedModifiedAt = modifiedAt
            lastPromptedChangeSignature = signature
            pendingChangeSignature = nil
            pendingChangeDetectedAt = nil
            return true
        }
        if pendingChangeSignature != signature {
            pendingChangeSignature = signature
            pendingChangeDetectedAt = now
        }
        return false
    }

    mutating func didUpload(_ snapshot: RemoteEditUploadSnapshot) throws {
        try snapshot.publishBaseline(to: originalSnapshotPath)
        state = snapshot.matches(localPath: localPath) ? .uploaded : .modified
        // A save during upload must be eligible for a new prompt, even if already observed.
        pendingChangeSignature = nil
        pendingChangeDetectedAt = nil
        lastPromptedChangeSignature = nil
    }
}
