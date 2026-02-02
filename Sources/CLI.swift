import Foundation
import ArgumentParser
import AppKit

struct CLI: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "tabz",
        abstract: "URL routing daemon for macOS",
        version: "1.0.0",
        subcommands: [Open.self, Test.self, Status.self, Dump.self, Reload.self, Quit.self],
        defaultSubcommand: nil
    )
}

// MARK: - Open Command

extension CLI {
    struct Open: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Route a URL to a browser based on rules"
        )

        @Argument(help: "The URL to open")
        var url: String

        @Option(name: .shortAndLong, help: "Path to config file")
        var config: String?

        @Option(name: .long, help: "Source app bundle ID")
        var sourceApp: String?

        @Option(name: .long, help: "Source app window title")
        var sourceWindowTitle: String?

        @Flag(name: .shortAndLong, help: "Show verbose output")
        var verbose: Bool = false

        func run() throws {
            guard let openURL = URL(string: url) else {
                throw ValidationError("Invalid URL: \(url)")
            }

            // Load config
            let loadedConfig: Config
            let configPath: String?
            do {
                if let path = config {
                    let expandedPath = (path as NSString).expandingTildeInPath
                    loadedConfig = try ConfigurationManager.loadConfig(from: expandedPath)
                    configPath = expandedPath
                } else {
                    loadedConfig = try ConfigurationManager.loadConfig()
                    configPath = ConfigurationManager.findConfigPath()
                }
            } catch {
                throw ValidationError("Failed to load config: \(error.localizedDescription)")
            }

            // Configure logger from config
            if let logging = loadedConfig.logging {
                Logger.shared.configure(enabled: logging.enabled, path: logging.path)
            }

            // Create rule engine and match
            let engine = RuleEngine(config: loadedConfig)
            let action = engine.testMatch(
                url: openURL,
                sourceApp: sourceApp,
                sourceWindowTitle: sourceWindowTitle
            )

            if verbose {
                print("URL:          \(url)")
                if let sourceApp = sourceApp {
                    print("Source App:   \(sourceApp)")
                }
                if let sourceWindowTitle = sourceWindowTitle {
                    print("Source Title: \(sourceWindowTitle)")
                }
                print("")
                print("Matched Rule: \(action.matchedRule ?? "(default)")")
                print("Browser:      \(action.browser)")
                if let window = action.windowTarget {
                    print("Window:       \(window.name)")
                }
                if !action.tabActions.isEmpty {
                    let tabDescriptions = action.tabActions.map { tab -> String in
                        let tabType: String
                        switch tab.kind {
                        case .focus: tabType = "focusTab"
                        case .use: tabType = "useTab"
                        case .follow: tabType = "followTab"
                        }
                        return "\(tabType)=\"\(tab.pattern)\""
                    }
                    print("Tab Actions:  \(tabDescriptions.joined(separator: " -> "))")
                }
                print("Final URL:    \(action.rewrittenURL)")
                print("Config:       \(configPath ?? "default")")
                print("")
            }

            // Execute the action
            let executor = Executor()
            do {
                Logger.shared.log("Opening URL: \(url) -> browser=\(action.browser), window=\(action.windowTarget?.name ?? "none")")
                try executor.execute(action: action)
                if verbose {
                    print("Opened successfully.")
                }
            } catch {
                Logger.shared.log("Failed to open URL: \(error)")
                throw ValidationError("Failed to open URL: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Test Command

extension CLI {
    struct Test: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Test which rule matches a URL (dry run)"
        )

        @Argument(help: "The URL to test")
        var url: String

        @Option(name: .shortAndLong, help: "Path to config file")
        var config: String?

        @Option(name: .long, help: "Source app bundle ID")
        var sourceApp: String?

        @Option(name: .long, help: "Source app window title")
        var sourceWindowTitle: String?

        @Flag(name: .shortAndLong, help: "Show verbose output")
        var verbose: Bool = false

        func run() throws {
            guard let testURL = URL(string: url) else {
                throw ValidationError("Invalid URL: \(url)")
            }

            // Load config
            let loadedConfig: Config
            let configPath: String?
            do {
                if let path = config {
                    let expandedPath = (path as NSString).expandingTildeInPath
                    loadedConfig = try ConfigurationManager.loadConfig(from: expandedPath)
                    configPath = expandedPath
                } else {
                    loadedConfig = try ConfigurationManager.loadConfig()
                    configPath = ConfigurationManager.findConfigPath()
                }
            } catch {
                throw ValidationError("Failed to load config: \(error.localizedDescription)")
            }

            // Create rule engine and test
            let engine = RuleEngine(config: loadedConfig)
            let action = engine.testMatch(
                url: testURL,
                sourceApp: sourceApp,
                sourceWindowTitle: sourceWindowTitle
            )

            // Print results
            print("URL:          \(url)")
            if let sourceApp = sourceApp {
                print("Source App:   \(sourceApp)")
            }
            if let sourceWindowTitle = sourceWindowTitle {
                print("Source Title: \(sourceWindowTitle)")
            }
            print("")
            print("Result:")
            print("  Matched Rule: \(action.matchedRule ?? "(default)")")
            print("  Browser:      \(action.browser)")
            if let window = action.windowTarget {
                print("  Window:       \(window.name)")
            }
            if !action.tabActions.isEmpty {
                let tabDescriptions = action.tabActions.map { tab -> String in
                    let tabType: String
                    switch tab.kind {
                    case .focus: tabType = "focusTab"
                    case .use: tabType = "useTab"
                    case .follow: tabType = "followTab"
                    }
                    return "\(tabType)=\"\(tab.pattern)\""
                }
                print("  Tab Actions:  \(tabDescriptions.joined(separator: " -> "))")
            }
            print("  Final URL:    \(action.rewrittenURL)")

            if verbose {
                print("")
                print("Config loaded from: \(configPath ?? "default")")
                print("Total rules: \(loadedConfig.rules.count)")
            }
        }
    }
}

// MARK: - Status Command

extension CLI {
    struct Status: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Show daemon status and configuration"
        )

        func run() throws {
            let pid = DaemonPID.get()
            let isRunning = pid.map { DaemonPID.isRunning($0) } ?? false

            print("Tabzilla Status")
            print("─────────────")
            print("")

            if isRunning, let pid = pid {
                print("Daemon:  Running (PID \(pid))")
            } else {
                print("Daemon:  Not running")
            }

            if let configPath = ConfigurationManager.findConfigPath() {
                print("Config:  \(configPath)")
            } else {
                print("Config:  Not found (will use defaults)")
            }

            print("")
            print("Config search paths (in order):")
            for path in ConfigurationManager.searchPaths {
                let exists = FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath)
                let marker = exists ? "✓" : " "
                print("  \(marker) \(path)")
            }

            // Try to load and validate config
            print("")
            do {
                let config = try ConfigurationManager.loadConfig()
                print("Config valid: Yes")
                print("  Version:  \(config.version)")
                print("  Rules:    \(config.rules.count)")
                print("  Defaults:")
                print("    Browser: \(config.defaults.browser)")
                print("    Window:  \(config.defaults.window ?? "(browser default)")")
                if let logging = config.logging {
                    print("  Logging:")
                    print("    Enabled: \(logging.enabled)")
                    if let logPath = logging.path {
                        let expandedPath = (logPath as NSString).expandingTildeInPath
                        let exists = FileManager.default.fileExists(atPath: expandedPath)
                        let marker = exists ? "✓" : " "
                        print("    Path:    \(marker) \(logPath)")
                    }
                }
            } catch {
                print("Config valid: No")
                print("  Error: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Dump Command

extension CLI {
    struct Dump: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Dump full state as JSON (for tools/agents)"
        )

        @Option(name: .shortAndLong, help: "Path to config file")
        var config: String?

        func run() throws {
            var result: [String: Any] = [
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]

            // Daemon state
            let pid = DaemonPID.get()
            let isRunning = pid.map { DaemonPID.isRunning($0) } ?? false
            var daemonState: [String: Any] = [
                "running": isRunning
            ]
            if let pid = pid, isRunning {
                daemonState["pid"] = pid
            }
            result["daemon"] = daemonState

            // Config state
            var configState: [String: Any] = [
                "searchPaths": ConfigurationManager.searchPaths
            ]

            // Determine config path
            let configPath: String?
            if let path = config {
                configPath = (path as NSString).expandingTildeInPath
            } else {
                configPath = ConfigurationManager.findConfigPath()
            }
            if let path = configPath {
                configState["path"] = path
            }

            do {
                let loadedConfig: Config
                if let path = config {
                    let expandedPath = (path as NSString).expandingTildeInPath
                    loadedConfig = try ConfigurationManager.loadConfig(from: expandedPath)
                } else {
                    loadedConfig = try ConfigurationManager.loadConfig()
                }
                configState["valid"] = true
                configState["version"] = loadedConfig.version
                configState["ruleCount"] = loadedConfig.rules.count
                var defaults: [String: Any] = ["browser": loadedConfig.defaults.browser]
                if let window = loadedConfig.defaults.window {
                    defaults["window"] = window
                }
                configState["defaults"] = defaults
                if let logging = loadedConfig.logging {
                    var loggingState: [String: Any] = ["enabled": logging.enabled]
                    if let logPath = logging.path {
                        loggingState["path"] = logPath
                    }
                    configState["logging"] = loggingState
                }

                // Browser state (requires loaded config)
                result["browsers"] = getBrowserState(for: loadedConfig)
            } catch {
                configState["valid"] = false
                configState["error"] = error.localizedDescription
                result["browsers"] = []
            }
            result["config"] = configState

            // Output JSON
            if let jsonData = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                print(jsonString)
            }
        }

        /// Extract unique browser bundle IDs from config
        private func getBrowsersFromConfig(_ config: Config) -> Set<String> {
            var browsers = Set<String>()
            browsers.insert(config.defaults.browser)
            for rule in config.rules {
                if let browser = rule.browser {
                    browsers.insert(browser)
                }
            }
            return browsers
        }

        /// Get browser state for all browsers referenced in config
        private func getBrowserState(for config: Config) -> [[String: Any]] {
            let browsers = getBrowsersFromConfig(config)
            let chromeController = ChromeController.shared()

            var browserStates: [[String: Any]] = []

            for bundleId in browsers.sorted() {
                var browserInfo: [String: Any] = [
                    "bundleId": bundleId
                ]

                // Check if browser is installed
                let isInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
                browserInfo["installed"] = isInstalled

                // Check if it's a Chrome-based browser we can query
                let isChromeBasedBrowser = bundleId.hasPrefix("com.google.Chrome")
                browserInfo["supportsScriptingBridge"] = isChromeBasedBrowser

                if isChromeBasedBrowser, isInstalled {
                    if let windows = chromeController.getAllWindows(forBundleId: bundleId) {
                        browserInfo["running"] = !windows.isEmpty || isAppRunning(bundleId: bundleId)
                        browserInfo["windowCount"] = windows.count
                        browserInfo["windows"] = windows
                    } else {
                        browserInfo["running"] = false
                        browserInfo["error"] = "Could not query browser state"
                    }
                } else if !isChromeBasedBrowser {
                    browserInfo["running"] = isAppRunning(bundleId: bundleId)
                }

                browserStates.append(browserInfo)
            }

            return browserStates
        }

        /// Check if an app is running by bundle ID
        private func isAppRunning(bundleId: String) -> Bool {
            return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
        }
    }
}

// MARK: - Reload Command

extension CLI {
    struct Reload: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Signal daemon to reload configuration"
        )

        func run() throws {
            guard let pid = DaemonPID.get() else {
                throw ValidationError("Daemon is not running (no PID file found)")
            }

            guard DaemonPID.isRunning(pid) else {
                throw ValidationError("Daemon is not running (PID \(pid) not found)")
            }

            // Send SIGHUP to reload config
            if kill(pid, SIGHUP) == 0 {
                print("Sent reload signal to daemon (PID \(pid))")
            } else {
                throw ValidationError("Failed to send signal to daemon: \(String(cString: strerror(errno)))")
            }
        }
    }
}

// MARK: - Quit Command

extension CLI {
    struct Quit: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Stop the daemon"
        )

        func run() throws {
            guard let pid = DaemonPID.get() else {
                throw ValidationError("Daemon is not running (no PID file found)")
            }

            guard DaemonPID.isRunning(pid) else {
                throw ValidationError("Daemon is not running (PID \(pid) not found)")
            }

            // Send SIGTERM for graceful shutdown
            if kill(pid, SIGTERM) == 0 {
                print("Sent quit signal to daemon (PID \(pid))")
            } else {
                throw ValidationError("Failed to send signal to daemon: \(String(cString: strerror(errno)))")
            }
        }
    }
}

// MARK: - Shared Helpers

private func getPIDFilePath() -> String {
    let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return supportDir.appendingPathComponent("Tabzilla/tabz.pid").path
}

private enum DaemonPID {
    static func get() -> pid_t? {
        let pidPath = getPIDFilePath()
        guard let pidString = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = pid_t(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid
    }

    static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}
