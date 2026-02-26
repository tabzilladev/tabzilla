import Foundation

// MARK: - Resolved Route

/// Describes exactly what the Executor should do — produced by pure resolution logic.
enum ResolvedRoute {
    /// Focus an existing tab (no navigation).
    case focusTab(bundleId: String, windowId: String, tabIndex: Int, matchedRule: String?)

    /// Focus an existing tab and navigate it to a new URL.
    case navigateTab(bundleId: String, windowId: String, tabId: String, tabIndex: Int, url: String, matchedRule: String?)

    /// Open URL as a new tab inside an already-known window.
    case openInWindow(bundleId: String, windowId: String, url: String, matchedRule: String?)

    /// Named window doesn't exist yet — ask Chrome to create it.
    case createWindow(bundleId: String, windowName: String, url: String, matchedRule: String?)

    /// Use NSWorkspace to open the URL (non-Chrome browser, or no tab/window match).
    case openWithWorkspace(bundleId: String, url: URL, matchedRule: String?)
}

// MARK: - Route Resolver

struct RouteResolver {

    /// Resolve a RouteAction against a browser snapshot into a concrete ResolvedRoute.
    ///
    /// - Parameters:
    ///   - action: The routing action produced by the rule engine.
    ///   - snapshot: A snapshot of the current browser windows/tabs, or nil for non-Chrome browsers.
    ///   - isChromeBasedBrowser: Whether the target browser supports Scripting Bridge.
    func resolve(
        action: RouteAction,
        snapshot: BrowserSnapshot?,
        isChromeBasedBrowser: Bool
    ) -> ResolvedRoute {
        let url = action.routeURL.absoluteString
        let bundleId = action.browser
        let matchedRule = action.matchedRule

        // 1. Non-Chrome browser → open with workspace.
        guard isChromeBasedBrowser else {
            return .openWithWorkspace(bundleId: bundleId, url: action.routeURL, matchedRule: matchedRule)
        }

        let preferredWindow = action.windowTarget ?? ""

        // 2. Try each tab action in priority order.
        for tabAction in action.tabActions {
            guard let flat = findTab(
                matchingPattern: tabAction.pattern,
                preferredWindow: preferredWindow,
                snapshot: snapshot
            ) else {
                continue
            }

            switch tabAction.kind {
            case .focus:
                return .focusTab(
                    bundleId: bundleId,
                    windowId: flat.windowId,
                    tabIndex: flat.tabIndex,
                    matchedRule: matchedRule
                )

            case .use:
                return .navigateTab(
                    bundleId: bundleId,
                    windowId: flat.windowId,
                    tabId: flat.tabId,
                    tabIndex: flat.tabIndex,
                    url: url,
                    matchedRule: matchedRule
                )

            case .follow:
                return .openInWindow(
                    bundleId: bundleId,
                    windowId: flat.windowId,
                    url: url,
                    matchedRule: matchedRule
                )
            }
        }

        // 3. No tab action matched — try window target.
        guard let windowTarget = action.windowTarget else {
            return .openWithWorkspace(bundleId: bundleId, url: action.routeURL, matchedRule: matchedRule)
        }

        // 4. Named window exists → open in it; otherwise create it.
        if let window = findWindow(named: windowTarget, snapshot: snapshot) {
            return .openInWindow(
                bundleId: bundleId,
                windowId: window.id,
                url: url,
                matchedRule: matchedRule
            )
        } else {
            return .createWindow(
                bundleId: bundleId,
                windowName: windowTarget,
                url: url,
                matchedRule: matchedRule
            )
        }
    }

    // MARK: - Private Helpers

    /// Find the first tab whose URL matches `pattern`, searching the preferred window first.
    /// Invalid regex patterns are silently skipped (matching current ObjC behavior).
    private func findTab(
        matchingPattern pattern: String,
        preferredWindow: String,
        snapshot: BrowserSnapshot?
    ) -> BrowserSnapshot.FlatTab? {
        guard let snapshot = snapshot else { return nil }

        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        } catch {
            // Invalid pattern — skip silently.
            return nil
        }

        // Search preferred window first.
        let (preferredWindows, otherWindows): ([WindowSnapshot], [WindowSnapshot])
        if preferredWindow.isEmpty {
            preferredWindows = []
            otherWindows = snapshot.windows
        } else {
            let lower = preferredWindow.lowercased()
            preferredWindows = snapshot.windows.filter { $0.name.lowercased() == lower }
            otherWindows = snapshot.windows.filter { $0.name.lowercased() != lower }
        }

        for window in preferredWindows + otherWindows {
            for tab in window.tabs {
                let range = NSRange(tab.url.startIndex..., in: tab.url)
                if regex.firstMatch(in: tab.url, options: [], range: range) != nil {
                    return BrowserSnapshot.FlatTab(
                        windowId: window.id,
                        windowName: window.name,
                        tabId: tab.id,
                        tabIndex: tab.index,
                        url: tab.url
                    )
                }
            }
        }

        return nil
    }

    /// Find a window by case-insensitive exact match on givenName.
    private func findWindow(named name: String, snapshot: BrowserSnapshot?) -> WindowSnapshot? {
        guard let snapshot = snapshot else { return nil }
        let lower = name.lowercased()
        return snapshot.windows.first { $0.name.lowercased() == lower }
    }
}
