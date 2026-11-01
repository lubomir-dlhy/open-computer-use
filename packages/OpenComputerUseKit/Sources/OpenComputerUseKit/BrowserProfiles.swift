import Foundation

struct BrowserProfile: Equatable {
    var directory: String
    var name: String
    var email: String
    var note: String?

    var label: String {
        let account = email.isEmpty || email == name ? "" : " (\(email))"
        return "\(name)\(account)"
    }
}

/// Chrome profiles that have the extension, read from Chrome's own files, plus the
/// user's defaults and notes from `browser-profiles.json`:
/// `{"default": "me@gmail.com", "notes": {"work.com": "Work: Jira, AWS"}}`.
enum BrowserProfiles {
    static let chromeRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)

    static var configURL: URL {
        BrowserNativeHost.socketDirectory.deletingLastPathComponent().appendingPathComponent("browser-profiles.json")
    }

    struct Config {
        var defaultProfile: String?
        var notes: [String: String] = [:]
    }

    static func config() -> Config {
        guard let data = try? Data(contentsOf: configURL),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return Config() }
        return Config(defaultProfile: object["default"] as? String, notes: object["notes"] as? [String: String] ?? [:])
    }

    /// Profiles in Chrome's Local State that have the extension installed.
    static func installed() -> [BrowserProfile] {
        let notes = config().notes
        return all().filter { profile in
            let directory = chromeRoot.appendingPathComponent(profile.directory)
            return ["Secure Preferences", "Preferences"].contains { file in
                (try? Data(contentsOf: directory.appendingPathComponent(file)))?
                    .range(of: Data(BrowserNativeHost.extensionID.utf8)) != nil
            }
        }.map { profile in
            var profile = profile
            profile.note = notes.first { matches(profile, $0.key) }?.value
            return profile
        }
    }

    static func all() -> [BrowserProfile] {
        guard let data = try? Data(contentsOf: chromeRoot.appendingPathComponent("Local State")),
              let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cache = (state["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] else { return [] }
        return cache.map { directory, info in
            BrowserProfile(directory: directory, name: info["name"] as? String ?? directory, email: info["user_name"] as? String ?? "")
        }.sorted { $0.directory.localizedStandardCompare($1.directory) == .orderedAscending }
    }

    /// The profile directory whose extension storage holds `token`.
    static func directory(holding token: String) -> String? {
        let needle = Data(token.utf8)
        let directories = (try? FileManager.default.contentsOfDirectory(atPath: chromeRoot.path)) ?? []
        for directory in directories {
            let storage = chromeRoot.appendingPathComponent(directory)
                .appendingPathComponent("Local Extension Settings/\(BrowserNativeHost.extensionID)")
            let files = (try? FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)) ?? []
            if files.contains(where: { (try? Data(contentsOf: $0, options: .mappedIfSafe))?.range(of: needle) != nil }) {
                return directory
            }
        }
        return nil
    }

    static func profile(holding token: String) -> BrowserProfile? {
        guard let directory = directory(holding: token) else { return nil }
        return installed().first { $0.directory == directory }
            ?? all().first { $0.directory == directory }
            ?? BrowserProfile(directory: directory, name: directory, email: "")
    }

    static func matches(_ profile: BrowserProfile, _ query: String) -> Bool {
        let query = query.lowercased()
        return [profile.name, profile.email, profile.directory].contains { field in
            let field = field.lowercased()
            return !field.isEmpty && (field == query || field.contains(query) || query.contains(field) && field.count > 3)
        }
    }

    /// One best match by name, email or directory.
    static func select(_ query: String, from profiles: [BrowserProfile]) -> BrowserProfile? {
        let direct = profiles.filter { matches($0, query) }
        if direct.count == 1 { return direct[0] }
        return direct.first { [$0.name, $0.email, $0.directory].contains { $0.lowercased() == query.lowercased() } }
    }

    static func defaultProfile(among profiles: [BrowserProfile]) -> BrowserProfile? {
        if let configured = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_BROWSER_PROFILE"] ?? config().defaultProfile {
            return select(configured, from: profiles)
        }
        return nil
    }

    /// The `profile` parameter's description: what the agent needs to choose without a call.
    static func parameterDescription() -> String {
        let profiles = installed()
        var text = "Chrome profile by name or email; pick the one whose account the task belongs to (an organisation's work in its profile)."
        guard profiles.count > 1 else { return text + " Default: the profile in use." }
        let preferred = defaultProfile(among: profiles)
        text += " Profiles: " + profiles.map { profile in
            var entry = profile.label
            if let note = profile.note { entry += " — \(note)" }
            if profile == preferred { entry += " [default]" }
            return entry
        }.joined(separator: "; ") + "."
        return text
    }
}
