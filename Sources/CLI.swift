import AppKit
import ArgumentParser
import Foundation
import os

private let logger = Logger(subsystem: "dev.tabzilla.Tabzilla", category: "cli")
/// Kept as a literal (not read from bundle) so it works outside the app bundle (SPM tests, CLI).
let appVersion = "0.2.2"

struct CLI: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "tabz",
        abstract: "URL routing daemon for macOS",
        version: appVersion,
        subcommands: [Open.self, Test.self, Status.self, Dump.self, Reload.self, Stop.self],
        defaultSubcommand: nil
    )
}

// MARK: - Route Helper

private struct LoadedRoute {
    let config: Config
    let configPath: String?
    let action: RouteAction
}

private func loadAndRoute(
    url: URL, configPath: String?, sourceApp: String?, sourceWindowTitle: String?
) throws -> LoadedRoute {
    let loadedConfig: Config
    do {
        loadedConfig = try ConfigurationManager.resolveConfig(from: configPath)
    } catch {
        throw ValidationError("Failed to load config: \(error.localizedDescription)")
    }

    let resolvedConfigPath = configPath.map { ($0 as NSString).expandingTildeInPath }
        ?? ConfigurationManager.findConfigPath()
    let engine = RuleEngine(config: loadedConfig)
    let action = engine.testMatch(url: url, sourceApp: sourceApp, sourceWindowTitle: sourceWindowTitle)
    return LoadedRoute(config: loadedConfig, configPath: resolvedConfigPath, action: action)
}

private func printRouteResult(action: RouteAction, indent: String = "") {
    print("\(indent)Matched Rule: \(action.matchedRule ?? "(default)")")
    print("\(indent)Browser:      \(action.browser)")
    if let window = action.windowTarget {
        print("\(indent)Window:       \(window)")
    }
    if !action.tabActions.isEmpty {
        let tabDescriptions = action.tabActions.map { tab -> String in
            let tabType = switch tab.kind {
            case .focus: "focusTab"
            case .use: "useTab"
            case .follow: "followTab"
            }
            return "\(tabType)=\"\(tab.pattern)\""
        }
        print("\(indent)Tab Actions:  \(tabDescriptions.joined(separator: " -> "))")
    }
    print("\(indent)Final URL:    \(action.routeURL)")
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
        var verbose = false

        func run() throws {
            guard let openURL = URL(string: url) else {
                throw ValidationError("Invalid URL: \(url)")
            }

            let route = try loadAndRoute(
                url: openURL, configPath: config, sourceApp: sourceApp, sourceWindowTitle: sourceWindowTitle
            )

            let action = route.action

            if verbose {
                print("URL:          \(url)")
                if let sourceApp {
                    print("Source App:   \(sourceApp)")
                }
                if let sourceWindowTitle {
                    print("Source Title: \(sourceWindowTitle)")
                }
                print("")
                printRouteResult(action: action)
                print("Config:       \(route.configPath ?? "default")")
                print("")
            }

            // Execute the action
            let executor = Executor()
            do {
                let bro = action.browser
                let win = action.windowTarget ?? "none"
                logger.info("open \(url, privacy: .private) browser=\(bro, privacy: .public) window=\(win, privacy: .public)")
                try executor.execute(action: action)
                if verbose {
                    print("Opened successfully.")
                }
            } catch {
                logger.error("Failed to open URL: \(error, privacy: .public)")
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
        var verbose = false

        func run() throws {
            guard let testURL = URL(string: url) else {
                throw ValidationError("Invalid URL: \(url)")
            }

            let route = try loadAndRoute(
                url: testURL, configPath: config, sourceApp: sourceApp, sourceWindowTitle: sourceWindowTitle
            )

            // Print results
            print("URL:          \(url)")
            if let sourceApp {
                print("Source App:   \(sourceApp)")
            }
            if let sourceWindowTitle {
                print("Source Title: \(sourceWindowTitle)")
            }
            print("")
            print("Result:")
            printRouteResult(action: route.action, indent: "  ")

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
            print("───────────────")
            print("")
            print("Version: \(appVersion)")

            if isRunning, let pid {
                let daemonVersion = DaemonPID.getVersion()
                if let version = daemonVersion {
                    let mismatch = version != appVersion ? " (restart to update)" : ""
                    print("Daemon:  Running (PID \(pid)) [\(version)]\(mismatch)")
                } else {
                    print("Daemon:  Running (PID \(pid))")
                }
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
    let version: String
    let daemon: DaemonState
    let config: ConfigInfo
    let browsers: [BrowserState]
}

private struct DaemonState: Encodable {
    let running: Bool
    let pid: pid_t?
    let version: String?
}

private struct ConfigInfo: Encodable {
    let searchPaths: [String]
    let path: String?
    let valid: Bool
    let config: Config?
    let error: String?
}

private struct BrowserState: Encodable {
    let bundleId: String
    let installed: Bool
    let supportsScriptingBridge: Bool
    let running: Bool?
    let windowCount: Int?
    let windows: [WindowSnapshot]?
    let error: String?
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
            let daemonVersion = isRunning ? DaemonPID.getVersion() : nil
            let daemonState = DaemonState(running: isRunning, pid: isRunning ? pid : nil, version: daemonVersion)

            // Config state
            let configPath = config.map { ($0 as NSString).expandingTildeInPath }
                ?? ConfigurationManager.findConfigPath()

            let configInfo: ConfigInfo
            let browsers: [BrowserState]
            do {
                let loadedConfig = try ConfigurationManager.resolveConfig(from: config)
                configInfo = ConfigInfo(
                    searchPaths: ConfigurationManager.searchPaths,
                    path: configPath,
                    valid: true,
                    config: loadedConfig,
                    error: nil
                )
                browsers = getBrowserState(for: loadedConfig)
            } catch {
                configInfo = ConfigInfo(
                    searchPaths: ConfigurationManager.searchPaths,
                    path: configPath,
                    valid: false,
                    config: nil,
                    error: error.localizedDescription
                )
                browsers = []
            }

            let output = DumpOutput(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                version: appVersion,
                daemon: daemonState,
                config: configInfo,
                browsers: browsers
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(output)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                throw ValidationError("Failed to encode output as UTF-8")
            }
            print(jsonString)
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
                let isChromeBasedBrowser = isChromeBasedBrowser(bundleId)

                if isChromeBasedBrowser, isInstalled {
                    if let rawWindows = chromeController.getAllWindows(forBundleId: bundleId) {
                        let windows = BrowserSnapshot.from(rawWindows as [NSDictionary]).windows
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
                        return BrowserState(
                            bundleId: bundleId,
                            installed: isInstalled,
                            supportsScriptingBridge: true,
                            running: false,
                            windowCount: nil,
                            windows: nil,
                            error: "Could not query browser state"
                        )
                    }
                } else {
                    return BrowserState(
                        bundleId: bundleId,
                        installed: isInstalled,
                        supportsScriptingBridge: false,
                        running: isAppRunning(bundleId: bundleId),
                        windowCount: nil,
                        windows: nil,
                        error: nil
                    )
                }
            }
        }

        /// Check if an app is running by bundle ID
        private func isAppRunning(bundleId: String) -> Bool {
            NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
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
            try DaemonPID.sendSignal(SIGHUP, name: "reload")
        }
    }
}

// MARK: - Stop Command

extension CLI {
    struct Stop: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Stop the daemon"
        )

        func run() throws {
            try DaemonPID.sendSignal(SIGTERM, name: "stop")
        }
    }
}

// MARK: - Shared Helpers

enum DaemonPID {
    static var pidFile: String {
        guard let supportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            return "~/Library/Application Support/Tabzilla/tabz.pid"
        }
        return supportDir.appendingPathComponent("Tabzilla/tabz.pid").path
    }

    static func get() -> pid_t? {
        let pidPath = pidFile
        guard let pidString = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = pid_t(pidString.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }
        return pid
    }

    static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    static func getVersion() -> String? {
        guard let pid = get(), isRunning(pid) else { return nil }
        guard let app = NSRunningApplication(processIdentifier: pid),
              let bundleURL = app.bundleURL else { return nil }
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: plistURL) else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    static func sendSignal(_ sig: Int32, name: String) throws {
        guard let pid = get() else {
            throw ValidationError("Daemon is not running (no PID file found)")
        }
        guard isRunning(pid) else {
            throw ValidationError("Daemon is not running (PID \(pid) not found)")
        }
        if kill(pid, sig) == 0 {
            print("Sent \(name) signal to daemon (PID \(pid))")
        } else {
            throw ValidationError("Failed to send signal to daemon: \(String(cString: strerror(errno)))")
        }
    }
}
