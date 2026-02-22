import Foundation
import Yams

// MARK: - Configuration Models

struct Config: Codable {
    let version: Int
    let defaults: Defaults
    let rules: [Rule]
    let logging: LoggingConfig?

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

        init(name: String? = nil, url: String? = nil, sourceApp: String? = nil,
             sourceWindowTitle: String? = nil, browser: String? = nil, window: String? = nil,
             useTab: String? = nil, focusTab: String? = nil, followTab: String? = nil) {
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

    struct LoggingConfig: Codable {
        let enabled: Bool
        let path: String?
    }

    init(version: Int = 1, defaults: Defaults = Defaults(), rules: [Rule] = [], logging: LoggingConfig? = nil) {
        self.version = version
        self.defaults = defaults
        self.rules = rules
        self.logging = logging
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
            "\(home)/.tabz.yaml"
        ]
    }

    /// Find the first existing config file path
    static func findConfigPath() -> String? {
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Load configuration from the first found config file
    static func loadConfig() throws -> Config {
        if let configPath = findConfigPath() {
            return try loadConfig(from: configPath)
        }

        // No config file found - create default and load it
        try createDefaultConfig()
        if let configPath = findConfigPath() {
            return try loadConfig(from: configPath)
        }
        return Config()
    }

    /// Load configuration from a specific path
    static func loadConfig(from path: String) throws -> Config {
        let expandedPath = (path as NSString).expandingTildeInPath
        let contents = try String(contentsOfFile: expandedPath, encoding: .utf8)
        let decoder = YAMLDecoder()
        return try decoder.decode(Config.self, from: contents)
    }

    /// Create default config file at the preferred location
    static func createDefaultConfig() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.config/tabz"
        let configPath = "\(configDir)/config.yaml"

        // Create directory if needed
        try FileManager.default.createDirectory(
            atPath: configDir,
            withIntermediateDirectories: true
        )

        // Load default config from bundle resources or use embedded default
        let defaultConfig = defaultConfigYAML
        try defaultConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    /// Default configuration YAML content
    private static var defaultConfigYAML: String {
        """
        # Tabzilla Configuration
        # https://github.com/bdupras/tabzilla
        #
        # This file defines how URLs are routed to browsers and windows.
        # All matching uses ICU regex (NSRegularExpression).
        #
        # Config file search order:
        #   1. ~/.config/tabz/config.yaml
        #   2. ~/Library/Application Support/Tabzilla/config.yaml
        #   3. ~/.tabz.yaml

        version: 1

        defaults:
          browser: com.google.Chrome
          # window: Default  # Optional: omit to let the browser decide

        rules:
          # Example: Route work domains to a specific browser and window
          # - url: (?i)corp\\.example\\.com|jira\\.example\\.com
          #   browser: com.google.Chrome.beta
          #   window: Work

          # Example: Route based on source app (Slack workspace)
          # - sourceApp: ^com\\.tinyspeck\\.slackmacgap$
          #   sourceWindowTitle: (?i)work
          #   browser: com.google.Chrome.beta
          #   window: Work

          # Example: Tab reuse for Google Docs (reuse tab for same document)
          # - url: docs\\.google\\.com/document/d/([^/]+)
          #   useTab: docs\\.google\\.com/document/d/\\1

          # Catch-all rule (uses defaults)
          - url: .*

        # Optional: Enable logging for debugging
        # logging:
        #   enabled: true
        #   path: ~/Library/Logs/Tabzilla/tabz.log
        """
    }
}

// MARK: - File Watcher

class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let fileDescriptor: Int32
    private let callback: () -> Void
    private var debounceWork: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.3

    init?(path: String, callback: @escaping () -> Void) {
        self.callback = callback

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        self.fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.debounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.callback()
            }
            self.debounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + self.debounceInterval, execute: work)
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        self.source = source
    }

    deinit {
        debounceWork?.cancel()
        source?.cancel()
    }
}

// MARK: - Shared Paths

enum TabzillaPaths {
    static var pidFile: String {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return supportDir.appendingPathComponent("Tabzilla/tabz.pid").path
    }
}

// MARK: - Logger

@objc class Logger: NSObject {
    @objc static let shared = Logger()

    private var logEnabled = false
    private var logPath: String?

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()

    private override init() {}

    private func isPathWithinHome(_ path: String) -> Bool {
        let resolved = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        let home = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).standardizingPath
        return resolved.hasPrefix(home + "/") || resolved == home
    }

    func configure(enabled: Bool, path: String?) {
        if enabled, let path = path {
            guard isPathWithinHome(path) else {
                fputs("warning: log path '\(path)' is outside home directory; logging disabled\n", stderr)
                self.logEnabled = false
                self.logPath = nil
                return
            }
            let expandedPath = (path as NSString).expandingTildeInPath
            let logDir = (expandedPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(
                atPath: logDir,
                withIntermediateDirectories: true
            )
        }
        self.logEnabled = enabled
        self.logPath = path
    }

    @objc func log(_ message: String) {
        let timestamp = Self.dateFormatter.string(from: Date())
        let logMessage = "[\(timestamp)] \(message)\n"

        // Always log to stderr for debugging
        #if DEBUG
        fputs(logMessage, stderr)
        #endif

        guard logEnabled, let path = logPath else { return }

        let expandedPath = (path as NSString).expandingTildeInPath
        guard isPathWithinHome(expandedPath) else { return }
        if let data = logMessage.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: expandedPath) {
                if let handle = FileHandle(forWritingAtPath: expandedPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                FileManager.default.createFile(atPath: expandedPath, contents: data)
            }
        }
    }
}
