import SwiftUI
import AppKit

@main
struct TabzillaApp {
    static func main() {
        // Check if running with CLI arguments
        let args = CommandLine.arguments
        // The `-NS` and `-Apple` prefix filter is necessary because macOS injects system flags
        // (like `-NSDocumentRevisionsDebugMode`, `-ApplePersistenceIgnoreState`) when launching
        // the app bundle.
        if args.count > 1 && !args[1].starts(with: "-NS") && !args[1].starts(with: "-Apple") {
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
    private var fileWatcher: FileWatcher?
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

        // Load configuration
        loadConfiguration()

        // Write PID file for CLI commands
        writePIDFile()

        Logger.shared.log("Tabzilla daemon started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        removePIDFile()
        Logger.shared.log("Tabzilla daemon stopped")
    }

    private func loadConfiguration() {
        do {
            let config = try ConfigurationManager.loadConfig()
            self.config = config
            ruleEngine = RuleEngine(config: config)
            executor = Executor()

            // Configure logger from config
            if let logging = config.logging {
                Logger.shared.configure(enabled: logging.enabled, path: logging.path)
            }

            // Set up file watching for config reload
            if let configPath = ConfigurationManager.findConfigPath() {
                setupFileWatcher(for: configPath)
            }

            Logger.shared.log("Configuration loaded successfully")
        } catch {
            Logger.shared.log("Failed to load configuration: \(error)")
        }
    }

    private func setupFileWatcher(for path: String) {
        fileWatcher = FileWatcher(path: path) { [weak self] in
            Logger.shared.log("Config file changed, reloading...")
            self?.reloadConfiguration()
        }
    }

    func reloadConfiguration() {
        do {
            let config = try ConfigurationManager.loadConfig()
            self.config = config
            ruleEngine = RuleEngine(config: config)

            // Reconfigure logger from config
            if let logging = config.logging {
                Logger.shared.configure(enabled: logging.enabled, path: logging.path)
            }

            Logger.shared.log("Configuration reloaded successfully")
        } catch {
            Logger.shared.log("Failed to reload configuration: \(error)")
        }
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

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            Logger.shared.log("Failed to parse URL from Apple Event")
            return
        }

        // Get source app information
        let sourceApp = getSourceApp(from: event)
        let sourceWindowTitle = sourceApp.flatMap { getSourceWindowTitle(for: $0) }

        let request = RouteRequest(
            url: url,
            sourceApp: sourceApp,
            sourceWindowTitle: sourceWindowTitle,
            timestamp: Date()
        )

        Logger.shared.log("Received URL: \(url), sourceApp: \(sourceApp ?? "unknown"), sourceWindowTitle: \(sourceWindowTitle ?? "unknown")")

        routeURL(request: request)
    }

    @objc private func handleOpenDocumentsEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let listDescriptor = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else {
            Logger.shared.log("Failed to get document list from Apple Event")
            return
        }

        // Get source app information
        let sourceApp = getSourceApp(from: event)
        let sourceWindowTitle = sourceApp.flatMap { getSourceWindowTitle(for: $0) }

        // Iterate through all documents in the list
        let itemCount = listDescriptor.numberOfItems
        guard itemCount > 0 else { return }
        for i in 1...itemCount {
            guard let itemDescriptor = listDescriptor.atIndex(i) else {
                continue
            }

            // Try to get file URL - documents come as file references
            var url: URL?

            // Try coercing to file URL
            if let fileURLDescriptor = itemDescriptor.coerce(toDescriptorType: typeFileURL),
               let urlString = fileURLDescriptor.stringValue {
                url = URL(string: urlString)
            }

            // Fallback: try as alias/bookmark and resolve to path
            if url == nil {
                let data = itemDescriptor.data
                var isStale = false
                if let bookmarkURL = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                    url = bookmarkURL
                }
            }

            guard let fileURL = url else {
                Logger.shared.log("Failed to parse file URL at index \(i)")
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
                sourceWindowTitle: sourceWindowTitle,
                timestamp: Date()
            )

            Logger.shared.log("Received file: \(fileURL), sourceApp: \(sourceApp ?? "unknown"), sourceWindowTitle: \(sourceWindowTitle ?? "unknown")")

            routeURL(request: request)
        }
    }

    private func isURLShortcutFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "webloc" || ext == "url"
    }

    private func openFileWithDefaultBrowser(_ fileURL: URL) {
        guard let config = config else {
            Logger.shared.log("No config, falling back to NSWorkspace.open for \(fileURL.lastPathComponent)")
            NSWorkspace.shared.open(fileURL)
            return
        }

        let bundleId = config.defaults.browser
        guard let browserURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            Logger.shared.log("Default browser \(bundleId) not found, falling back for \(fileURL.lastPathComponent)")
            NSWorkspace.shared.open(fileURL)
            return
        }

        NSWorkspace.shared.open([fileURL], withApplicationAt: browserURL, configuration: NSWorkspace.OpenConfiguration())
        Logger.shared.log("Delegated \(fileURL.lastPathComponent) to \(bundleId)")
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
        // Use Accessibility API - works for all apps including Electron apps like Slack
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // Get the focused window
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        if result == .success, let window = focusedWindow {
            var titleValue: CFTypeRef?
            // Force-cast is safe: AXUIElementCopyAttributeValue with kAXFocusedWindowAttribute
            // always returns an AXUIElement per the Accessibility API contract.
            let titleResult = AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue)

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
        guard let engine = ruleEngine, let exec = executor else {
            Logger.shared.log("Rule engine or executor not initialized")
            openURLInDefaultBrowser(request.url)
            return
        }

        let action = engine.route(request: request)
        Logger.shared.log("Route action: browser=\(action.browser), window=\(action.windowTarget?.name ?? "none")")

        do {
            try exec.execute(action: action)
        } catch {
            Logger.shared.log("Failed to execute action: \(error)")
            openURLInDefaultBrowser(request.url)
        }
    }

    private func openURLInDefaultBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: - PID File Management

    private func writePIDFile() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let pidFilePath = TabzillaPaths.pidFile
        let pidDir = (pidFilePath as NSString).deletingLastPathComponent

        do {
            try FileManager.default.createDirectory(atPath: pidDir, withIntermediateDirectories: true)
            try "\(pid)".write(toFile: pidFilePath, atomically: true, encoding: .utf8)
        } catch {
            Logger.shared.log("Failed to write PID file: \(error)")
        }
    }

    private func removePIDFile() {
        try? FileManager.default.removeItem(atPath: TabzillaPaths.pidFile)
    }
}
