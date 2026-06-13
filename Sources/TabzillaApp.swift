import AppKit
import os
import SwiftUI

private let logger = Logger(subsystem: "dev.tabzilla.Tabzilla", category: "app")

@main
struct TabzillaApp {
    static func main() {
        // Check if running with CLI arguments
        let args = CommandLine.arguments
        // The `-NS` and `-Apple` prefix filter is necessary because macOS injects system flags
        // (like `-NSDocumentRevisionsDebugMode`, `-ApplePersistenceIgnoreState`) when launching
        // the app bundle.
        let hasUserArgs = args.count > 1 && !args[1].starts(with: "-NS") && !args[1].starts(with: "-Apple")
        if hasUserArgs {
            // `doctor` and `setup` read/grant Accessibility & Automation, which
            // macOS attributes to the *responsible process* — the launching
            // terminal — not to Tabzilla, unless we disclaim. Re-exec these two
            // (and only these) as our own responsible process so the checks and
            // consent prompts are attributed to dev.tabzilla.Tabzilla. Other
            // subcommands don't touch TCC and daemon mode must not be re-exec'd.
            if ["doctor", "setup"].contains(args[1]) {
                TabzillaDisclaimReexecIfNeeded()
            }
            CLI.main()
        } else if args.count == 1, isatty(STDIN_FILENO) != 0 {
            // No arguments from an interactive terminal: print usage and exit.
            // When launched via `open`, Launch Services, or launchd, stdin is not a tty,
            // so daemon mode is unaffected.
            CLI.main()
        } else {
            // Daemon mode
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.run()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var config: Config?
    private var ruleEngine: RuleEngine?
    private var executor: Executor?

    private var sighupSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Register for URL events BEFORE didFinishLaunching
        // This ensures we catch URLs that launched the app
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // Register for open document events (for local HTML files)
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocumentsEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon (LSUIElement behavior)
        NSApp.setActivationPolicy(.accessory)

        // Set up signal handlers for CLI commands
        setupSignalHandlers()

        reloadConfiguration()
        executor = Executor()

        // Write PID file for CLI commands
        writePIDFile()

        logger.info("Tabzilla daemon started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        removePIDFile()
        logger.info("Tabzilla daemon stopped")
    }

    @discardableResult
    func reloadConfiguration() -> RuleEngine? {
        do {
            let (config, changed) = try ConfigurationManager.loadConfig()
            if changed {
                self.config = config

                let engine = RuleEngine(config: config)
                ruleEngine = engine
                logger.info("Configuration loaded successfully")
            }
        } catch {
            logger.error("Failed to load configuration: \(error, privacy: .public)")
        }
        return ruleEngine
    }

    private func setupSignalHandlers() {
        // DispatchSource requires signals to be ignored before installing a source handler
        signal(SIGHUP, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        // SIGHUP: reload config
        let hupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        hupSource.setEventHandler { [weak self] in
            self?.reloadConfiguration()
        }
        hupSource.resume()
        sighupSource = hupSource

        // SIGTERM: graceful shutdown
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler {
            NSApp.terminate(nil)
        }
        termSource.resume()
        sigtermSource = termSource
    }

    @objc private func handleGetURLEvent(
        _ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor
    ) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString)
        else {
            logger.error("Failed to parse URL from Apple Event")
            return
        }

        // Get source app information
        let sourceApp = getSourceApp(from: event)
        let sourceWindowTitle = sourceApp.flatMap { getSourceWindowTitle(for: $0) }

        let request = RouteRequest(
            url: url,
            sourceApp: sourceApp,
            sourceWindowTitle: sourceWindowTitle
        )

        let app = sourceApp ?? "unknown"
        let title = sourceWindowTitle ?? "unknown"
        logger.info("Received URL: \(url, privacy: .private) app=\(app, privacy: .public) title=\(title, privacy: .private)")

        routeURL(request: request)
    }

    @objc private func handleOpenDocumentsEvent(
        _ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor
    ) {
        guard let listDescriptor = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else {
            logger.error("Failed to get document list from Apple Event")
            return
        }

        // Get source app information
        let sourceApp = getSourceApp(from: event)
        let sourceWindowTitle = sourceApp.flatMap { getSourceWindowTitle(for: $0) }

        // Iterate through all documents in the list
        let itemCount = listDescriptor.numberOfItems
        guard itemCount > 0 else { return }
        for index in 1...itemCount {
            guard let itemDescriptor = listDescriptor.atIndex(index) else {
                continue
            }

            // Try to get file URL - documents come as file references
            var url: URL?

            // Try coercing to file URL
            if let fileURLDescriptor = itemDescriptor.coerce(toDescriptorType: typeFileURL),
               let urlString = fileURLDescriptor.stringValue
            {
                url = URL(string: urlString)
            }

            // Fallback: try as alias/bookmark and resolve to path
            if url == nil {
                let data = itemDescriptor.data
                var isStale = false
                if let bookmarkURL = try? URL(
                    resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale
                ) {
                    url = bookmarkURL
                }
            }

            guard let fileURL = url else {
                logger.error("Failed to parse file URL at index \(index, privacy: .public)")
                continue
            }

            // Delegate URL shortcut files (.webloc, .url) directly to default browser
            if isURLShortcutFile(fileURL) {
                openFileWithDefaultBrowser(fileURL)
                continue
            }

            let request = RouteRequest(
                url: fileURL,
                sourceApp: sourceApp,
                sourceWindowTitle: sourceWindowTitle
            )

            let app = sourceApp ?? "unknown"
            let title = sourceWindowTitle ?? "unknown"
            logger.info("file: \(fileURL, privacy: .private) app=\(app, privacy: .public) title=\(title, privacy: .private)")

            routeURL(request: request)
        }
    }

    private func isURLShortcutFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "webloc" || ext == "url"
    }

    private func openFileWithDefaultBrowser(_ fileURL: URL) {
        guard let config else {
            logger
                .info("No config, falling back to NSWorkspace.open for \(fileURL.lastPathComponent, privacy: .private)")
            NSWorkspace.shared.open(fileURL)
            return
        }

        let bundleId = config.defaults.browser
        guard let browserURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            let filename = fileURL.lastPathComponent
            logger.error("Browser \(bundleId, privacy: .public) not found")
            logger.error("Falling back for \(filename, privacy: .private)")
            NSWorkspace.shared.open(fileURL)
            return
        }

        NSWorkspace.shared.open(
            [fileURL], withApplicationAt: browserURL, configuration: NSWorkspace.OpenConfiguration()
        )
        logger.info("Delegated \(fileURL.lastPathComponent, privacy: .private) to \(bundleId, privacy: .public)")
    }

    private func getSourceApp(from event: NSAppleEventDescriptor) -> String? {
        // Direct path: coerce the original sender address to a bundle ID.
        if let sourceDescriptor = event.attributeDescriptor(forKeyword: AEKeyword(keyOriginalAddressAttr)) {
            if let bundleIDDescriptor = sourceDescriptor.coerce(toDescriptorType: typeApplicationBundleID) {
                if let bundleId = bundleIDDescriptor.stringValue {
                    return bundleId
                }
            }
        }

        // Fallback for apps that don't include the bundle ID attribute: read the
        // sender's PID from the event and resolve the bundle ID via NSRunningApplication.
        if let pidDescriptor = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr)) {
            let pid = pidDescriptor.int32Value
            if pid > 0 {
                if let app = NSRunningApplication(processIdentifier: pid) {
                    return app.bundleIdentifier
                }
            }
        }

        return nil
    }

    private func getSourceWindowTitle(for bundleId: String) -> String? {
        // Accessibility is required to read window titles. Without it the AX calls
        // below silently return nil and any rule that matches on sourceWindowTitle
        // quietly won't fire — so surface an actionable hint instead.
        guard Permissions.accessibilityGranted() else {
            logger.error("Accessibility not granted — window-title rules won't match. Run `tabz setup`.")
            return nil
        }

        // Use Accessibility API - works for all apps including Electron apps like Slack
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // Get the focused window
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        if result == .success, let window = focusedWindow {
            // AXUIElementCopyAttributeValue returns an AXUIElement for window attributes per the AX API contract.
            let axWindow = window as! AXUIElement
            var titleValue: CFTypeRef?
            let titleResult = AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue)

            if titleResult == .success, let title = titleValue as? String {
                return title
            }
        }

        // Fallback: try to get front window from window list
        var windowList: CFTypeRef?
        let listResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowList)

        if listResult == .success, let windows = windowList as? [AXUIElement], let frontWindow = windows.first {
            var titleValue: CFTypeRef?
            let titleResult = AXUIElementCopyAttributeValue(frontWindow, kAXTitleAttribute as CFString, &titleValue)

            if titleResult == .success, let title = titleValue as? String {
                return title
            }
        }

        return nil
    }

    private func routeURL(request: RouteRequest) {
        guard let engine = reloadConfiguration(), let exec = executor else {
            logger.error("Rule engine or executor not initialized")
            openURLInFallbackBrowser(request.url)
            return
        }

        let action = engine.route(request: request)
        let win = action.windowTarget ?? "none"
        logger.info("Route action: browser=\(action.browser, privacy: .public) window=\(win, privacy: .public)")

        do {
            try exec.execute(action: action)
        } catch {
            logger.error("Failed to execute action: \(error, privacy: .public)")
            openURLInFallbackBrowser(request.url)
        }
    }

    private func openURLInFallbackBrowser(_ url: URL) {
        let chrome = "com.google.Chrome"
        let safari = "com.apple.Safari"
        let bundleId = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chrome) != nil ? chrome : safari
        logger.error("Routing failed — opening in fallback browser (\(bundleId, privacy: .public))")
        logger.error("Fallback URL: \(url, privacy: .private)")
        guard let browserURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: browserURL, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - PID File Management

    private func writePIDFile() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let pidFilePath = DaemonPID.pidFile
        let pidDir = (pidFilePath as NSString).deletingLastPathComponent

        do {
            try FileManager.default.createDirectory(atPath: pidDir, withIntermediateDirectories: true)
            try "\(pid)".write(toFile: pidFilePath, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write PID file: \(error, privacy: .public)")
        }
    }

    private func removePIDFile() {
        try? FileManager.default.removeItem(atPath: DaemonPID.pidFile)
    }
}
