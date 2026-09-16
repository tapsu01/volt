import Foundation
import Testing
@testable import Volt

@Suite @MainActor
struct FileApplicationPreferencesTests {
    private func withPreferences(_ body: (FileApplicationPreferences, UserDefaults) throws -> Void) rethrows {
        let name = "Volt.FileApplicationPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(FileApplicationPreferences(defaults: defaults), defaults)
    }

    @Test func extensionRules() {
        for (name, expected) in [("file.PHP", "php"), ("archive.tar.gz", "gz"),
                                 (".env", nil), ("README", nil), ("file.", nil), (".env.local", "local")] {
            #expect(FileApplicationPreferences.fileExtension(for: URL(fileURLWithPath: "/tmp/\(name)")) == expected)
        }
    }

    @Test func persistsAcrossInstancesAndSharesLocalRemoteExtensions() {
        withPreferences { preferences, defaults in
            let local = URL(fileURLWithPath: "/local/test.PHP")
            let remoteCopy = URL(fileURLWithPath: "/tmp/remote-edit/test.php")
            let app = URL(fileURLWithPath: "/Applications/Editor.app")
            preferences.recordSuccessfulOpen(ApplicationChoice(url: app, remember: true), for: local)
            let reloaded = FileApplicationPreferences(defaults: defaults)
            #expect(reloaded.hasDefault(for: remoteCopy))
            #expect(reloaded.resolve(for: remoteCopy, explicitApplication: nil, findBundle: { _ in nil },
                                     isAvailable: { $0 == app }) == .application(app))
            reloaded.reset(for: remoteCopy)
            #expect(!preferences.hasDefault(for: local))
        }
    }

    @Test func oneTimeChoiceOverridesWithoutReplacingDefault() {
        withPreferences { preferences, _ in
            let file = URL(fileURLWithPath: "/test.txt")
            let saved = URL(fileURLWithPath: "/Applications/Saved.app")
            let once = URL(fileURLWithPath: "/Applications/Once.app")
            preferences.recordSuccessfulOpen(ApplicationChoice(url: saved, remember: true), for: file)
            #expect(preferences.resolve(for: file, explicitApplication: once, findBundle: { _ in nil },
                                        isAvailable: { _ in false }) == .application(once))
            preferences.recordSuccessfulOpen(ApplicationChoice(url: once, remember: false), for: file)
            #expect(preferences.resolve(for: file, explicitApplication: nil, findBundle: { _ in nil },
                                        isAvailable: { _ in true }) == .application(saved))
            preferences.recordSuccessfulOpen(ApplicationChoice(url: once, remember: true), for: file)
            #expect(preferences.resolve(for: file, explicitApplication: nil, findBundle: { _ in nil },
                                        isAvailable: { _ in true }) == .application(once))
        }
    }

    @Test func missingAppPreservesPreferenceAndUnconfiguredUsesSystem() {
        withPreferences { preferences, _ in
            let file = URL(fileURLWithPath: "/test.txt")
            let app = URL(fileURLWithPath: "/Applications/Removed.app")
            #expect(preferences.resolve(for: file, explicitApplication: nil, findBundle: { _ in nil },
                                        isAvailable: { _ in false }) == .systemDefault)
            preferences.recordSuccessfulOpen(ApplicationChoice(url: app, remember: true), for: file)
            #expect(preferences.resolve(for: file, explicitApplication: nil, findBundle: { _ in nil },
                                        isAvailable: { _ in false }) == .missingApplication)
            #expect(preferences.hasDefault(for: file))
            let dotfile = URL(fileURLWithPath: "/.env")
            preferences.recordSuccessfulOpen(ApplicationChoice(url: app, remember: true), for: dotfile)
            #expect(!preferences.hasDefault(for: dotfile))
        }
    }

    @Test func bundleLookupSurvivesAppMoveAndFallsBackToSavedPath() throws {
        try withPreferences { preferences, _ in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let app = root.appendingPathComponent("Editor.app")
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let plist = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "test.volt.editor", "CFBundlePackageType": "APPL"
            ], format: .xml, options: 0)
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
            let file = URL(fileURLWithPath: "/test.txt")
            let moved = URL(fileURLWithPath: "/Applications/Moved.app")
            preferences.recordSuccessfulOpen(ApplicationChoice(url: app, remember: true), for: file)
            let resolution = preferences.resolve(for: file, explicitApplication: nil, findBundle: {
                #expect($0 == "test.volt.editor")
                return moved
            }, isAvailable: { $0 == moved })
            #expect(resolution == .application(moved))
            let fallback = preferences.resolve(for: file, explicitApplication: nil, findBundle: { _ in nil },
                                               isAvailable: { FileManager.default.fileExists(atPath: $0.path) })
            #expect(fallback == .application(URL(fileURLWithPath: app.path)))
        }
    }
}
