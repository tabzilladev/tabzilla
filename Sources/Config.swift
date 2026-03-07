import Foundation
import Yams

// MARK: - Configuration Models

struct Config: Codable {
    let version: Int
    let defaults: Defaults
    let rules: [Rule]

    struct Defaults: Codable {
        let browser: String
        let window: String?

        init(browser: String = "com.google.Chrome", window: String? = nil) {
            self.browser = browser
            self.window = window
        }
    }

    struct Rule: Codable {
        let name: String?
        let url: String?
        let sourceApp: String?
        let sourceWindowTitle: String?
        let browser: String?
        let window: String?
        let useTab: String?
        let focusTab: String?
        let followTab: String?

        init(
            name: String? = nil,
            url: String? = nil,
            sourceApp: String? = nil,
            sourceWindowTitle: String? = nil,
            browser: String? = nil,
            window: String? = nil,
            useTab: String? = nil,
            focusTab: String? = nil,
            followTab: String? = nil
        ) {
            self.name = name
            self.url = url
            self.sourceApp = sourceApp
            self.sourceWindowTitle = sourceWindowTitle
            self.browser = browser
            self.window = window
            self.useTab = useTab
            self.focusTab = focusTab
            self.followTab = followTab
        }
    }

    init(version: Int = 1, defaults: Defaults = Defaults(), rules: [Rule] = []) {
        self.version = version
        self.defaults = defaults
        self.rules = rules
    }
}

// MARK: - Configuration Manager

enum ConfigurationManager {
    /// Search paths for config file (in order of priority)
    static var searchPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.config/tabz/config.yaml",
            "\(home)/Library/Application Support/Tabzilla/config.yaml",
            "\(home)/.tabz.yaml",
        ]
    }

    /// Find the first existing config file path
    static func findConfigPath() -> String? {
        for path in searchPaths where FileManager.default.fileExists(atPath: path) {
            return path
        }
        return nil
    }

    private static var cachedFingerprint: ConfigFingerprint?

    /// Load configuration from the first found config file.
    /// Returns the config and whether it differed from the last loaded config.
    static func loadConfig() throws -> (config: Config, changed: Bool) {
        let path = findConfigPath()
        let fingerprint = path.flatMap { ConfigFingerprint.of(path: $0) }
        let changed = fingerprint != cachedFingerprint
        cachedFingerprint = fingerprint

        if let configPath = path {
            return try (loadConfig(from: configPath), changed)
        }

        // No config file found - return in-memory defaults
        return (Config(), changed)
    }

    /// Load configuration from a specific path
    static func loadConfig(from path: String) throws -> Config {
        let expandedPath = (path as NSString).expandingTildeInPath
        let contents = try String(contentsOfFile: expandedPath, encoding: .utf8)
        let decoder = YAMLDecoder()
        return try decoder.decode(Config.self, from: contents)
    }

    /// Resolve and load config from an optional explicit path, or search defaults.
    static func resolveConfig(from configPath: String?) throws -> Config {
        if let path = configPath {
            return try loadConfig(from: path)
        }
        return try loadConfig().config
    }
}

// MARK: - Config Freshness

struct ConfigFingerprint: Equatable {
    let path: String
    let modificationDate: Date
    let inode: UInt64

    static func of(path: String) -> ConfigFingerprint? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        else { return nil }
        return ConfigFingerprint(path: path, modificationDate: mtime, inode: inode)
    }
}
