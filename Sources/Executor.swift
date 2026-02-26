import Foundation
import AppKit
import os

private let logger = Logger(subsystem: "dev.tabzilla.Tabzilla", category: "executor")

/// Executes route actions by controlling browsers
struct Executor {

    enum ExecutorError: Error, LocalizedError {
        case browserNotFound(String)
        case scriptingError(String)
        case urlOpenFailed(URL)

        var errorDescription: String? {
            switch self {
            case .browserNotFound(let bundleId):
                return "Browser not found: \(bundleId)"
            case .scriptingError(let message):
                return "Scripting error: \(message)"
            case .urlOpenFailed(let url):
                return "Failed to open URL: \(url)"
            }
        }
    }

    private let chromeController = ChromeController.shared()
    private let resolver = RouteResolver()

    func execute(action: RouteAction) throws {
        let bundleId = action.browser

        // Check if browser is installed
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil else {
            throw ExecutorError.browserNotFound(bundleId)
        }

        // Check if this is a Chrome-based browser (supports window targeting via Scripting Bridge)
        let isChromeBasedBrowser = bundleId.hasPrefix("com.google.Chrome")

        // Build snapshot (Chrome-based browsers only)
        let snapshot: BrowserSnapshot? = isChromeBasedBrowser
            ? BrowserSnapshot.from(chromeController.getAllWindows(forBundleId: bundleId) as? [NSDictionary] ?? [])
            : nil

        // Resolve (pure)
        let route = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: isChromeBasedBrowser)

        // Execute (side effects only)
        try executeRoute(route)
    }

    private func executeRoute(_ route: ResolvedRoute) throws {
        switch route {
        case .focusTab(let bundleId, let windowId, let tabIndex, let matchedRule):
            logger.info("Focusing tab (focusTab) matchedRule=\(matchedRule ?? "none", privacy: .public)")
            chromeController.focusTab(
                withWindowId: windowId,
                tabIndex: tabIndex,
                bundleId: bundleId
            )

        case .navigateTab(let bundleId, let windowId, let tabId, let tabIndex, let url, let matchedRule):
            logger.info("Navigating tab (useTab) matchedRule=\(matchedRule ?? "none", privacy: .public)")
            chromeController.focusTab(
                withWindowId: windowId,
                tabIndex: tabIndex,
                bundleId: bundleId
            )
            chromeController.navigateTab(
                withWindowId: windowId,
                tabId: tabId,
                toURL: url,
                bundleId: bundleId
            )

        case .openInWindow(let bundleId, let windowId, let url, let matchedRule):
            logger.info("Opening URL in window (followTab/window) matchedRule=\(matchedRule ?? "none", privacy: .public)")
            var error: NSError?
            let success = chromeController.openURL(
                url,
                inWindowWithId: windowId,
                bundleId: bundleId,
                error: &error
            )
            if !success {
                let message = error?.localizedDescription ?? "Unknown error"
                logger.error("Failed to open URL in window: \(message)")
                throw ExecutorError.scriptingError(message)
            }

        case .createWindow(let bundleId, let windowName, let url, let matchedRule):
            logger.info("Creating window '\(windowName, privacy: .public)' matchedRule=\(matchedRule ?? "none", privacy: .public)")
            var error: NSError?
            let success = chromeController.openURL(
                url,
                inWindow: windowName,
                bundleId: bundleId,
                error: &error
            )
            if !success {
                let message = error?.localizedDescription ?? "Unknown error"
                logger.error("Failed to create window: \(message)")
                throw ExecutorError.scriptingError(message)
            }

        case .openWithWorkspace(let bundleId, let url, let matchedRule):
            logger.info("Opening URL with workspace matchedRule=\(matchedRule ?? "none", privacy: .public)")
            try openURLInBrowser(url, bundleId: bundleId)
        }
    }

    private func openURLInBrowser(_ url: URL, bundleId: String) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        guard let browserURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            throw ExecutorError.browserNotFound(bundleId)
        }

        NSWorkspace.shared.open([url], withApplicationAt: browserURL, configuration: configuration) { app, error in
            if let error = error {
                logger.error("Failed to open URL: \(error)")
            }
        }
    }
}
