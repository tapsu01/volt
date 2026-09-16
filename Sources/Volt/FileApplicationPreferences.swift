import Foundation

struct ApplicationChoice: Sendable {
    let url: URL
    let remember: Bool
}

/// Volt-only associations. Never changes Launch Services defaults.
@MainActor
final class FileApplicationPreferences {
    struct Application: Codable, Equatable {
        let bundleIdentifier: String?
        let path: String
    }

    enum Resolution: Equatable {
        case systemDefault
        case application(URL)
        case missingApplication
    }

    private let defaults: UserDefaults
    private let key = "fileApplicationPreferences.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func fileExtension(for url: URL) -> String? {
        let suffix = url.pathExtension.lowercased()
        return suffix.isEmpty ? nil : suffix
    }

    private var applications: [String: Application] {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([String: Application].self, from: data) else { return [:] }
        return values
    }

    func hasDefault(for url: URL) -> Bool {
        guard let suffix = Self.fileExtension(for: url) else { return false }
        return applications[suffix] != nil
    }

    func reset(for url: URL) {
        guard let suffix = Self.fileExtension(for: url) else { return }
        var values = applications
        values.removeValue(forKey: suffix)
        save(values)
    }

    func recordSuccessfulOpen(_ choice: ApplicationChoice, for fileURL: URL) {
        guard choice.remember, let suffix = Self.fileExtension(for: fileURL) else { return }
        var values = applications
        values[suffix] = Application(bundleIdentifier: Bundle(url: choice.url)?.bundleIdentifier, path: choice.url.path)
        save(values)
    }

    func resolve(for fileURL: URL, explicitApplication: URL?,
                 findBundle: (String) -> URL?, isAvailable: (URL) -> Bool) -> Resolution {
        if let explicitApplication { return .application(explicitApplication) }
        guard let suffix = Self.fileExtension(for: fileURL), let saved = applications[suffix] else {
            return .systemDefault
        }
        if let identifier = saved.bundleIdentifier, let url = findBundle(identifier), isAvailable(url) {
            return .application(url)
        }
        let url = URL(fileURLWithPath: saved.path)
        return isAvailable(url) ? .application(url) : .missingApplication
    }

    private func save(_ values: [String: Application]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: key)
    }
}
