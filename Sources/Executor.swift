import AppKit
import Foundation
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
            case let .browserNotFound(bundleId):
                "Browser not found: \(bundleId)"
            case let .scriptingError(message):
                "Scripting error: \(message)"
            case let .urlOpenFailed(url):
                "Failed to open URL: \(url)"
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
        let isChromeBasedBrowser = isChromeBasedBrowser(bundleId)

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
        case let .focusTab(bundleId, windowId, tabIndex, matchedRule):
            logger.info("Focusing tab (focusTab) matchedRule=\(matchedRule ?? "none", privacy: .public)")
            chromeController.focusTab(
                withWindowId: windowId,
                tabIndex: tabIndex,
                bundleId: bundleId
            )

        case let .navigateTab(bundleId, windowId, tabId, tabIndex, url, matchedRule):
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

        case let .openInWindow(bundleId, windowId, url, matchedRule):
            logger
                .info("Opening URL in window (followTab/window) matchedRule=\(matchedRule ?? "none", privacy: .public)")
            var error: NSError?
            let success = chromeController.openURL(
                url,
                inWindowWithId: windowId,
                bundleId: bundleId,
                error: &error
            )
            if !success {
                let message = error?.localizedDescription ?? "Unknown error"
                logger.error("Failed to open URL in window: \(message, privacy: .public)")
                logAutomationHintIfDenied(bundleId)
                throw ExecutorError.scriptingError(message)
            }

        case let .createWindow(bundleId, windowName, url, matchedRule):
            logger.info("Creating window '\(windowName, privacy: .public)' rule=\(matchedRule ?? "none", privacy: .public)")
            var error: NSError?
            let success = chromeController.openURL(
                url,
                inWindow: windowName,
                bundleId: bundleId,
                error: &error
            )
            if !success {
                let message = error?.localizedDescription ?? "Unknown error"
                logger.error("Failed to create window: \(message, privacy: .public)")
                logAutomationHintIfDenied(bundleId)
                throw ExecutorError.scriptingError(message)
            }

        case let .openWithWorkspace(bundleId, url, matchedRule):
            logger.info("Opening URL with workspace matchedRule=\(matchedRule ?? "none", privacy: .public)")
            try openURLInBrowser(url, bundleId: bundleId)
        }
    }

    /// When a Scripting Bridge call fails, check whether Automation permission for
    /// the target is the likely cause and, if so, log an actionable hint. Converts
    /// a silent/cryptic Apple Event failure into something the user can fix.
    private func logAutomationHintIfDenied(_ bundleId: String) {
        let state = Permissions.automationState(forTargetBundleID: bundleId, prompt: false)
        if state != .granted {
            logger.error(
                "Automation permission for \(bundleId, privacy: .public) is not granted — run `tabz setup`."
            )
        }
    }

    private func openURLInBrowser(_ url: URL, bundleId: String) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        guard let browserURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            throw ExecutorError.browserNotFound(bundleId)
        }

        NSWorkspace.shared.open([url], withApplicationAt: browserURL, configuration: configuration) { _, error in
            if let error {
                logger.error("Failed to open URL: \(error, privacy: .public)")
            }
        }
    }
}
