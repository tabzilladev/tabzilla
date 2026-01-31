import Foundation
import AppKit

/// Executes route actions by controlling browsers
class Executor {

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
            try openURLInBrowser(action.rewrittenURL, bundleId: bundleId)
        }
    }

    private func executeChromeAction(action: RouteAction, browserBundleId: String) throws {
        let url = action.rewrittenURL.absoluteString
        let windowName = action.windowTarget?.name ?? "Default"

        // First, check for tab reuse if specified
        if let tabAction = action.tabAction {
            if let tabInfo = chromeController.findTab(
                matchingPattern: tabAction.pattern,
                preferredWindow: windowName,
                bundleId: browserBundleId
            ) {
                Logger.shared.log("Found matching tab in window '\(tabInfo.windowName)', focusing")
                chromeController.focusTab(
                    withWindowId: tabInfo.windowId,
                    tabIndex: tabInfo.tabIndex,
                    bundleId: browserBundleId
                )
                if tabAction.navigate {
                    Logger.shared.log("Navigating tab to \(url)")
                    chromeController.navigateTab(
                        withWindowId: tabInfo.windowId,
                        tabId: tabInfo.tabId,
                        toURL: url,
                        bundleId: browserBundleId
                    )
                }
                return
            }
        }

        // No tab to reuse - open in target window
        var error: NSError?
        let success = chromeController.openURL(
            url,
            inWindow: windowName,
            bundleId: browserBundleId,
            error: &error
        )

        if !success {
            let message = error?.localizedDescription ?? "Unknown error"
            Logger.shared.log("Failed to open URL in Chrome: \(message)")
            throw ExecutorError.scriptingError(message)
        }

        Logger.shared.log("Opened URL in Chrome window '\(windowName)'")
    }

    private func openURLInBrowser(_ url: URL, bundleId: String) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        guard let browserURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            throw ExecutorError.browserNotFound(bundleId)
        }

        NSWorkspace.shared.open([url], withApplicationAt: browserURL, configuration: configuration) { app, error in
            if let error = error {
                Logger.shared.log("Failed to open URL: \(error)")
            }
        }
    }
}
