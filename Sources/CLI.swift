import Foundation
import ArgumentParser
import AppKit

struct CLI: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "tabz",
        abstract: "URL routing daemon for macOS",
        version: "0.1.0",
        subcommands: [Open.self, Test.self, Status.self, Dump.self, Reload.self, Quit.self],
        defaultSubcommand: nil
    )
}

// MARK: - Route Helper

private enum RouteHelper {
    struct LoadedRoute {
        let config: Config
        let configPath: String?
        let action: RouteAction
    }

    static func loadAndRoute(url: URL, configPath: String?, sourceApp: String?, sourceWindowTitle: String?) throws -> LoadedRoute {
        let loadedConfig: Config
        let resolvedConfigPath: String?
        do {
            if let path = configPath {
                let expandedPath = (path as NSString).expandingTildeInPath
                loadedConfig = try ConfigurationManager.loadConfig(from: expandedPath)
                resolvedConfigPath = expandedPath
            } else {
                loadedConfig = try ConfigurationManager.loadConfig().config
                resolvedConfigPath = ConfigurationManager.findConfigPath()
            }
        } catch {
            throw ValidationError("Failed to load config: \(error.localizedDescription)")
        }

        let engine = RuleEngine(config: loadedConfig)
        let action = engine.testMatch(url: url, sourceApp: sourceApp, sourceWindowTitle: sourceWindowTitle)
        return LoadedRoute(config: loadedConfig, configPath: resolvedConfigPath, action: action)
    }

    static func printRouteResult(action: RouteAction, indent: String = "") {
        print("\(indent)Matched Rule: \(action.matchedRule ?? "(default)")")
        print("\(indent)Browser:      \(action.browser)")
        if let window = action.windowTarget {
            print("\(indent)Window:       \(window.name)")
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
            print("\(indent)Tab Actions:  \(tabDescriptions.joined(separator: " -> "))")
        }
        print("\(indent)Final URL:    \(action.routeUrl)")
    }
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

            let route = try RouteHelper.loadAndRoute(url: openURL, configPath: config, sourceApp: sourceApp, sourceWindowTitle: sourceWindowTitle)

            // Configure logger from config
            if let logging = route.config.logging {
                Logger.shared.configure(enabled: logging.enabled, path: logging.path)
            }

            if verbose {
                print("URL:          \(url)")
                if let sourceApp = sourceApp {
                    print("Source App:   \(sourceApp)")
                }
                if let sourceWindowTitle = sourceWindowTitle {
                    print("Source Title: \(sourceWindowTitle)")
                }
                print("")
                RouteHelper.printRouteResult(action: route.action)
                print("Config:       \(route.configPath ?? "default")")
                print("")
            }

            // Execute the action
            let executor = Executor()
            do {
                Logger.shared.log("Opening URL: \(url) -> browser=\(route.action.browser), window=\(route.action.windowTarget?.name ?? "none")")
                try executor.execute(action: route.action)
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

            let route = try RouteHelper.loadAndRoute(url: testURL, configPath: config, sourceApp: sourceApp, sourceWindowTitle: sourceWindowTitle)

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
            RouteHelper.printRouteResult(action: route.action, indent: "  ")

            if verbose {
                print("")
                print("Config loaded from: \(route.configPath ?? "default")")
                print("Total rules: \(route.config.rules.count)")
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
                let config = try ConfigurationManager.loadConfig().config
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

// MARK: - Dump Output Types

private struct DumpOutput: Encodable {
    let timestamp: String
    let daemon: DaemonState
    let config: ConfigState
    let browsers: [BrowserState]
}

private struct DaemonState: Encodable {
    let running: Bool
    let pid: pid_t?
}

private struct ConfigState: Encodable {
    let searchPaths: [String]
    let path: String?
    let valid: Bool
    let version: Int?
    let ruleCount: Int?
    let defaults: DefaultsState?
    let logging: LoggingState?
    let error: String?
}

private struct DefaultsState: Encodable {
    let browser: String
    let window: String?
}

private struct LoggingState: Encodable {
    let enabled: Bool
    let path: String?
}

private struct BrowserState: Encodable {
    let bundleId: String
    let installed: Bool
    let supportsScriptingBridge: Bool
    let running: Bool?
    let windowCount: Int?
    let windows: [WindowState]?
    let error: String?
}

private struct WindowState: Encodable {
    let id: String
    let givenName: String
    let tabCount: Int
    let tabs: [TabState]
}

private struct TabState: Encodable {
    let id: String
    let index: Int
    let url: String
    let title: String
    let active: Bool
}

private func convertWindows(_ rawWindows: [NSDictionary]) -> [WindowState] {
    return rawWindows.compactMap { w in
        guard let id = w["id"] as? String,
              let givenName = w["givenName"] as? String,
              let tabCount = w["tabCount"] as? Int,
              let rawTabs = w["tabs"] as? [[String: Any]] else { return nil }
        let tabs = rawTabs.compactMap { t -> TabState? in
            guard let tabId = t["id"] as? String,
                  let index = t["index"] as? Int,
                  let url = t["url"] as? String,
                  let title = t["title"] as? String,
                  let active = t["active"] as? Bool else { return nil }
            return TabState(id: tabId, index: index, url: url, title: title, active: active)
        }
        return WindowState(id: id, givenName: givenName, tabCount: tabCount, tabs: tabs)
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
            // Daemon state
            let pid = DaemonPID.get()
            let isRunning = pid.map { DaemonPID.isRunning($0) } ?? false
            let daemonState = DaemonState(running: isRunning, pid: isRunning ? pid : nil)

            // Config state
            let configPath: String?
            if let path = config {
                configPath = (path as NSString).expandingTildeInPath
            } else {
                configPath = ConfigurationManager.findConfigPath()
            }

            let configState: ConfigState
            let browsers: [BrowserState]
            do {
                let loadedConfig: Config
                if let path = config {
                    let expandedPath = (path as NSString).expandingTildeInPath
                    loadedConfig = try ConfigurationManager.loadConfig(from: expandedPath)
                } else {
                    loadedConfig = try ConfigurationManager.loadConfig().config
                }
                let loggingState = loadedConfig.logging.map { LoggingState(enabled: $0.enabled, path: $0.path) }
                configState = ConfigState(
                    searchPaths: ConfigurationManager.searchPaths,
                    path: configPath,
                    valid: true,
                    version: loadedConfig.version,
                    ruleCount: loadedConfig.rules.count,
                    defaults: DefaultsState(browser: loadedConfig.defaults.browser, window: loadedConfig.defaults.window),
                    logging: loggingState,
                    error: nil
                )
                browsers = getBrowserState(for: loadedConfig)
            } catch {
                configState = ConfigState(
                    searchPaths: ConfigurationManager.searchPaths,
                    path: configPath,
                    valid: false,
                    version: nil,
                    ruleCount: nil,
                    defaults: nil,
                    logging: nil,
                    error: error.localizedDescription
                )
                browsers = []
            }

            let output = DumpOutput(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                daemon: daemonState,
                config: configState,
                browsers: browsers
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let jsonData = try? encoder.encode(output),
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
        private func getBrowserState(for config: Config) -> [BrowserState] {
            let browsers = getBrowsersFromConfig(config)
            let chromeController = ChromeController.shared()

            return browsers.sorted().map { bundleId in
                let isInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
                let isChromeBasedBrowser = bundleId.hasPrefix("com.google.Chrome")

                if isChromeBasedBrowser, isInstalled {
                    if let rawWindows = chromeController.getAllWindows(forBundleId: bundleId) {
                        let windows = convertWindows(rawWindows as? [NSDictionary] ?? [])
                        return BrowserState(
                            bundleId: bundleId,
                            installed: isInstalled,
                            supportsScriptingBridge: true,
                            running: !rawWindows.isEmpty || isAppRunning(bundleId: bundleId),
                            windowCount: rawWindows.count,
                            windows: windows,
                            error: nil
                        )
                    } else {
                        return BrowserState(bundleId: bundleId, installed: isInstalled, supportsScriptingBridge: true, running: false, windowCount: nil, windows: nil, error: "Could not query browser state")
                    }
                } else {
                    return BrowserState(bundleId: bundleId, installed: isInstalled, supportsScriptingBridge: false, running: isAppRunning(bundleId: bundleId), windowCount: nil, windows: nil, error: nil)
                }
            }
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

private enum DaemonPID {
    static func get() -> pid_t? {
        let pidPath = TabzillaPaths.pidFile
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
