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

    func execute(action: RouteAction) throws {
        let bundleId = action.browser

        // Check if browser is installed
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil else {
            throw ExecutorError.browserNotFound(bundleId)
        }

        // Check if this is a Chrome-based browser (supports window targeting via Scripting Bridge)
        let isChromeBasedBrowser = bundleId.hasPrefix("com.google.Chrome")

        if isChromeBasedBrowser {
            try executeChromeAction(action: action, browserBundleId: bundleId)
        } else {
            // Fallback for non-Chrome browsers - just open URL
            try openURLInBrowser(action.routeURL, bundleId: bundleId)
        }
    }

    private func executeChromeAction(action: RouteAction, browserBundleId: String) throws {
        let url = action.routeURL.absoluteString
        let preferredWindow = action.windowTarget?.name ?? ""

        // Fetch tab cache once for all tab actions (avoids repeated IPC calls)
        let tabCache: [ChromeTabInfo]? = action.tabActions.isEmpty
            ? nil
            : chromeController.getAllTabs(forBundleId: browserBundleId)

        // Try each tab action in priority order (focusTab → useTab → followTab)
        for tabAction in action.tabActions {
            if let tabInfo = chromeController.findTab(
                matchingPattern: tabAction.pattern,
                preferredWindow: preferredWindow,
                bundleId: browserBundleId,
                fromTabCache: tabCache
            ) {
                switch tabAction.kind {
                case .focus:
                    logger.info("Found matching tab in window '\(tabInfo.windowName, privacy: .private)', focusing (focusTab)")
                    chromeController.focusTab(
                        withWindowId: tabInfo.windowId,
                        tabIndex: tabInfo.tabIndex,
                        bundleId: browserBundleId
                    )
                    return

                case .use:
                    logger.info("Found matching tab in window '\(tabInfo.windowName, privacy: .private)', navigating (useTab)")
                    chromeController.focusTab(
                        withWindowId: tabInfo.windowId,
                        tabIndex: tabInfo.tabIndex,
                        bundleId: browserBundleId
                    )
                    chromeController.navigateTab(
                        withWindowId: tabInfo.windowId,
                        tabId: tabInfo.tabId,
                        toURL: url,
                        bundleId: browserBundleId
                    )
                    return

                case .follow:
                    logger.info("Found matching tab in window '\(tabInfo.windowName, privacy: .private)', opening new tab in same window (followTab)")
                    var error: NSError?
                    let success = chromeController.openURL(
                        url,
                        inWindowWithId: tabInfo.windowId,
                        bundleId: browserBundleId,
                        error: &error
                    )
                    if !success {
                        let message = error?.localizedDescription ?? "Unknown error"
                        logger.error("Failed to open URL in window: \(message)")
                        throw ExecutorError.scriptingError(message)
                    }
                    return
                }
            }
            // No match for this tab action - continue to next one
            logger.debug("No matching tab for pattern '\(tabAction.pattern, privacy: .private)', trying next action")
        }

        // No tab actions matched - fall through to window targeting or browser default
        guard let windowTarget = action.windowTarget else {
            logger.debug("Opening URL with browser's default behavior")
            try openURLInBrowser(action.routeURL, bundleId: browserBundleId)
            return
        }

        // Open in target window
        var error: NSError?
        let success = chromeController.openURL(
            url,
            inWindow: windowTarget.name,
            bundleId: browserBundleId,
            error: &error
        )

        if !success {
            let message = error?.localizedDescription ?? "Unknown error"
            logger.error("Failed to open URL in Chrome: \(message)")
            throw ExecutorError.scriptingError(message)
        }

        logger.info("Opened URL in Chrome window '\(windowTarget.name, privacy: .public)'")
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
