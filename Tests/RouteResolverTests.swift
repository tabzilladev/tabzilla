import XCTest
@testable import Tabzilla

final class RouteResolverTests: XCTestCase {
    private let resolver = RouteResolver()
    private let chromeBundleId = "com.google.Chrome"
    private let safariBundleId = "com.apple.Safari"

    // MARK: - Helpers

    private func makeAction(
        browser: String = "com.google.Chrome",
        url: String = "https://example.com",
        windowTarget: String? = nil,
        tabActions: [TabAction] = [],
        matchedRule: String? = "test-rule"
    ) -> RouteAction {
        RouteAction(
            matchedRule: matchedRule,
            routeURL: URL(string: url)!,
            browser: browser,
            windowTarget: windowTarget,
            tabActions: tabActions
        )
    }

    private func makeSnapshot(windows: [WindowSnapshot] = []) -> BrowserSnapshot {
        BrowserSnapshot(windows: windows)
    }

    private func makeWindow(
        id: String = "w1",
        name: String = "Default",
        tabs: [TabSnapshot] = []
    ) -> WindowSnapshot {
        WindowSnapshot(id: id, name: name, tabCount: tabs.count, tabs: tabs)
    }

    private func makeTab(
        id: String = "t1",
        index: Int = 1,
        url: String = "https://example.com",
        title: String = "Example",
        active: Bool = false
    ) -> TabSnapshot {
        TabSnapshot(id: id, index: index, url: url, title: title, active: active)
    }

    // MARK: - Non-Chrome Browser

    func testNonChromeBrowserReturnsOpenWithWorkspace() {
        let action = makeAction(browser: safariBundleId)
        let result = resolver.resolve(action: action, snapshot: nil, isChromeBasedBrowser: false)

        guard case let .openWithWorkspace(bundleId, url, _) = result else {
            return XCTFail("Expected .openWithWorkspace, got \(result)")
        }
        XCTAssertEqual(bundleId, safariBundleId)
        XCTAssertEqual(url.absoluteString, "https://example.com")
    }

    func testNonChromeBrowserIgnoresSnapshot() {
        let snapshot = makeSnapshot(windows: [makeWindow()])
        let action = makeAction(browser: safariBundleId)
        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: false)

        guard case .openWithWorkspace = result else {
            return XCTFail("Expected .openWithWorkspace, got \(result)")
        }
    }

    func testNonChromeBrowserPreservesMatchedRule() {
        let action = makeAction(browser: safariBundleId, matchedRule: "my-rule")
        let result = resolver.resolve(action: action, snapshot: nil, isChromeBasedBrowser: false)

        guard case let .openWithWorkspace(_, _, matchedRule) = result else {
            return XCTFail("Expected .openWithWorkspace, got \(result)")
        }
        XCTAssertEqual(matchedRule, "my-rule")
    }

    // MARK: - focusTab

    func testFocusTabMatchReturnsfocusTab() {
        let tab = makeTab(id: "t1", index: 2, url: "https://github.com/user/repo")
        let window = makeWindow(id: "w1", name: "Code", tabs: [tab])
        let snapshot = makeSnapshot(windows: [window])
        let action = makeAction(
            tabActions: [TabAction(pattern: "github\\.com", kind: .focus)]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .focusTab(bundleId, windowId, tabIndex, _) = result else {
            return XCTFail("Expected .focusTab, got \(result)")
        }
        XCTAssertEqual(bundleId, chromeBundleId)
        XCTAssertEqual(windowId, "w1")
        XCTAssertEqual(tabIndex, 2)
    }

    // MARK: - useTab (navigateTab)

    func testUseTabMatchReturnsNavigateTab() {
        let tab = makeTab(id: "t42", index: 3, url: "https://docs.google.com/document/d/ABC123/edit")
        let window = makeWindow(id: "w1", tabs: [tab])
        let snapshot = makeSnapshot(windows: [window])
        let action = makeAction(
            url: "https://docs.google.com/document/d/ABC123/edit",
            tabActions: [TabAction(pattern: "docs\\.google\\.com/document/d/ABC123", kind: .use)]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .navigateTab(bundleId, windowId, tabId, tabIndex, url, _) = result else {
            return XCTFail("Expected .navigateTab, got \(result)")
        }
        XCTAssertEqual(bundleId, chromeBundleId)
        XCTAssertEqual(windowId, "w1")
        XCTAssertEqual(tabId, "t42")
        XCTAssertEqual(tabIndex, 3)
        XCTAssertEqual(url, "https://docs.google.com/document/d/ABC123/edit")
    }

    // MARK: - followTab (openInWindow from matched tab)

    func testFollowTabMatchReturnsOpenInWindow() {
        let tab = makeTab(id: "t1", index: 1, url: "https://github.com/acme/widgets")
        let window = makeWindow(id: "w5", tabs: [tab])
        let snapshot = makeSnapshot(windows: [window])
        let action = makeAction(
            tabActions: [TabAction(pattern: "github\\.com/acme", kind: .follow)]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .openInWindow(bundleId, windowId, url, _) = result else {
            return XCTFail("Expected .openInWindow, got \(result)")
        }
        XCTAssertEqual(bundleId, chromeBundleId)
        XCTAssertEqual(windowId, "w5")
        XCTAssertEqual(url, "https://example.com")
    }

    // MARK: - Tab Action Priority

    func testFocusWinsOverUseWhenBothMatch() {
        let tab = makeTab(id: "t1", index: 1, url: "https://github.com/acme/repo")
        let window = makeWindow(id: "w1", tabs: [tab])
        let snapshot = makeSnapshot(windows: [window])
        let action = makeAction(
            tabActions: [
                TabAction(pattern: "github\\.com", kind: .focus),
                TabAction(pattern: "github\\.com", kind: .use),
            ]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case .focusTab = result else {
            return XCTFail("Expected .focusTab (focus wins over use), got \(result)")
        }
    }

    func testUseWinsOverFollowWhenBothMatch() {
        let tab = makeTab(id: "t1", index: 1, url: "https://github.com/acme/repo")
        let window = makeWindow(id: "w1", tabs: [tab])
        let snapshot = makeSnapshot(windows: [window])
        let action = makeAction(
            tabActions: [
                TabAction(pattern: "github\\.com", kind: .use),
                TabAction(pattern: "github\\.com", kind: .follow),
            ]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case .navigateTab = result else {
            return XCTFail("Expected .navigateTab (use wins over follow), got \(result)")
        }
    }

    func testFirstMatchingTabActionWins() {
        // focusTab pattern doesn't match, useTab does — should return navigateTab
        let tab = makeTab(id: "t1", index: 1, url: "https://github.com/acme/repo")
        let window = makeWindow(id: "w1", tabs: [tab])
        let snapshot = makeSnapshot(windows: [window])
        let action = makeAction(
            tabActions: [
                TabAction(pattern: "nonexistent\\.pattern", kind: .focus),
                TabAction(pattern: "github\\.com", kind: .use),
            ]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case .navigateTab = result else {
            return XCTFail("Expected .navigateTab, got \(result)")
        }
    }

    // MARK: - Preferred Window Bias

    func testPreferredWindowMatchedFirst() {
        let tabInOther = makeTab(id: "t1", index: 1, url: "https://github.com/acme/repo")
        let tabInPreferred = makeTab(id: "t2", index: 2, url: "https://github.com/acme/other")
        let otherWindow = makeWindow(id: "w1", name: "Other", tabs: [tabInOther])
        let preferredWindow = makeWindow(id: "w2", name: "Work", tabs: [tabInPreferred])
        let snapshot = makeSnapshot(windows: [otherWindow, preferredWindow])
        let action = makeAction(
            windowTarget: "Work",
            tabActions: [TabAction(pattern: "github\\.com", kind: .focus)]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .focusTab(_, windowId, _, _) = result else {
            return XCTFail("Expected .focusTab, got \(result)")
        }
        // Should find tab in preferred window "Work" first
        XCTAssertEqual(windowId, "w2")
    }

    func testPreferredWindowCaseInsensitiveMatch() {
        let tab = makeTab(id: "t1", index: 1, url: "https://github.com")
        let window = makeWindow(id: "w1", name: "Work", tabs: [tab])
        let snapshot = makeSnapshot(windows: [window])
        let action = makeAction(
            windowTarget: "WORK", // different case
            tabActions: [TabAction(pattern: "github\\.com", kind: .focus)]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .focusTab(_, windowId, _, _) = result else {
            return XCTFail("Expected .focusTab, got \(result)")
        }
        XCTAssertEqual(windowId, "w1")
    }

    func testFallsBackToOtherWindowsWhenNoTabInPreferred() {
        let tabInOther = makeTab(id: "t1", index: 1, url: "https://github.com/acme/repo")
        let preferredWindow = makeWindow(id: "w1", name: "Work", tabs: []) // no matching tabs
        let otherWindow = makeWindow(id: "w2", name: "Personal", tabs: [tabInOther])
        let snapshot = makeSnapshot(windows: [preferredWindow, otherWindow])
        let action = makeAction(
            windowTarget: "Work",
            tabActions: [TabAction(pattern: "github\\.com", kind: .focus)]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .focusTab(_, windowId, _, _) = result else {
            return XCTFail("Expected .focusTab, got \(result)")
        }
        // Should find tab in other window as fallback
        XCTAssertEqual(windowId, "w2")
    }

    // MARK: - Fallthrough to Named Window

    func testNamedWindowExistsReturnsOpenInWindow() {
        let window = makeWindow(id: "w3", name: "Work", tabs: [])
        let snapshot = makeSnapshot(windows: [window])
        // No tab actions, just a window target
        let action = makeAction(windowTarget: "Work")

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .openInWindow(bundleId, windowId, url, _) = result else {
            return XCTFail("Expected .openInWindow, got \(result)")
        }
        XCTAssertEqual(bundleId, chromeBundleId)
        XCTAssertEqual(windowId, "w3")
        XCTAssertEqual(url, "https://example.com")
    }

    func testNamedWindowMissingReturnsCreateWindow() {
        let snapshot = makeSnapshot(windows: []) // no windows
        let action = makeAction(windowTarget: "Work")

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .createWindow(bundleId, windowName, url, _) = result else {
            return XCTFail("Expected .createWindow, got \(result)")
        }
        XCTAssertEqual(bundleId, chromeBundleId)
        XCTAssertEqual(windowName, "Work")
        XCTAssertEqual(url, "https://example.com")
    }

    func testNamedWindowLookupCaseInsensitive() {
        let window = makeWindow(id: "w1", name: "Work")
        let snapshot = makeSnapshot(windows: [window])
        let action = makeAction(windowTarget: "WORK")

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .openInWindow(_, windowId, _, _) = result else {
            return XCTFail("Expected .openInWindow, got \(result)")
        }
        XCTAssertEqual(windowId, "w1")
    }

    func testTabNoMatchThenWindowAlsoMissingReturnsCreateWindow() {
        let snapshot = makeSnapshot(windows: [makeWindow(id: "w1", name: "Personal", tabs: [])])
        let action = makeAction(
            windowTarget: "Work", // different from snapshot window
            tabActions: [TabAction(pattern: "github\\.com", kind: .focus)]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .createWindow(_, windowName, _, _) = result else {
            return XCTFail("Expected .createWindow, got \(result)")
        }
        XCTAssertEqual(windowName, "Work")
    }

    // MARK: - Fallthrough to Workspace Open

    func testNoWindowTargetAndNoTabMatchReturnsOpenWithWorkspace() {
        let snapshot = makeSnapshot(windows: [])
        let action = makeAction(windowTarget: nil) // no tab actions, no window target

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .openWithWorkspace(bundleId, url, _) = result else {
            return XCTFail("Expected .openWithWorkspace, got \(result)")
        }
        XCTAssertEqual(bundleId, chromeBundleId)
        XCTAssertEqual(url.absoluteString, "https://example.com")
    }

    func testAllTabActionsNoMatchNoWindowTargetReturnsOpenWithWorkspace() {
        let snapshot = makeSnapshot(windows: [makeWindow(tabs: [makeTab(url: "https://other.com")])])
        let action = makeAction(
            windowTarget: nil,
            tabActions: [TabAction(pattern: "github\\.com", kind: .focus)]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case .openWithWorkspace = result else {
            return XCTFail("Expected .openWithWorkspace, got \(result)")
        }
    }

    // MARK: - Invalid Regex

    func testInvalidRegexPatternSkipped() {
        let tab = makeTab(id: "t1", index: 1, url: "https://github.com")
        let window = makeWindow(id: "w1", tabs: [tab])
        let snapshot = makeSnapshot(windows: [window])
        // Invalid regex first, then valid — should skip invalid and NOT match (different pattern)
        let action = makeAction(
            tabActions: [TabAction(pattern: "[invalid(regex", kind: .focus)]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        // Invalid pattern should be skipped, no match
        guard case .openWithWorkspace = result else {
            return XCTFail("Expected .openWithWorkspace (invalid regex skipped), got \(result)")
        }
    }

    func testInvalidRegexFollowedByValidRegex() {
        let tab = makeTab(id: "t1", index: 1, url: "https://github.com")
        let window = makeWindow(id: "w1", tabs: [tab])
        let snapshot = makeSnapshot(windows: [window])
        let action = makeAction(
            tabActions: [
                TabAction(pattern: "[invalid(regex", kind: .focus),
                TabAction(pattern: "github\\.com", kind: .use), // valid, should match
            ]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case .navigateTab = result else {
            return XCTFail("Expected .navigateTab (falls through to valid pattern), got \(result)")
        }
    }

    // MARK: - Edge Cases

    func testEmptySnapshot() {
        let snapshot = makeSnapshot(windows: [])
        let action = makeAction(
            windowTarget: "Work",
            tabActions: [TabAction(pattern: "github\\.com", kind: .focus)]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .createWindow(_, windowName, _, _) = result else {
            return XCTFail("Expected .createWindow for empty snapshot, got \(result)")
        }
        XCTAssertEqual(windowName, "Work")
    }

    func testNilSnapshotWithWindowTargetCreatesWindow() {
        let action = makeAction(windowTarget: "Work")

        let result = resolver.resolve(action: action, snapshot: nil, isChromeBasedBrowser: true)

        guard case let .createWindow(_, windowName, _, _) = result else {
            return XCTFail("Expected .createWindow for nil snapshot, got \(result)")
        }
        XCTAssertEqual(windowName, "Work")
    }

    func testNilSnapshotWithNoWindowTargetReturnsOpenWithWorkspace() {
        let action = makeAction(windowTarget: nil)

        let result = resolver.resolve(action: action, snapshot: nil, isChromeBasedBrowser: true)

        guard case .openWithWorkspace = result else {
            return XCTFail("Expected .openWithWorkspace for nil snapshot + no window target, got \(result)")
        }
    }

    func testWindowWithNoTabsStillFoundForWindowLookup() {
        let window = makeWindow(id: "w1", name: "Work", tabs: [])
        let snapshot = makeSnapshot(windows: [window])
        let action = makeAction(windowTarget: "Work")

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .openInWindow(_, windowId, _, _) = result else {
            return XCTFail("Expected .openInWindow even for empty window, got \(result)")
        }
        XCTAssertEqual(windowId, "w1")
    }

    func testMatchedRuleIsPropagated() {
        let tab = makeTab(id: "t1", index: 1, url: "https://github.com")
        let window = makeWindow(id: "w1", tabs: [tab])
        let snapshot = makeSnapshot(windows: [window])
        let action = makeAction(
            tabActions: [TabAction(pattern: "github\\.com", kind: .focus)],
            matchedRule: "my-special-rule"
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .focusTab(_, _, _, matchedRule) = result else {
            return XCTFail("Expected .focusTab, got \(result)")
        }
        XCTAssertEqual(matchedRule, "my-special-rule")
    }

    // MARK: - BrowserSnapshot.from factory

    func testBrowserSnapshotFromEmptyArray() {
        let snapshot = BrowserSnapshot.from([])
        XCTAssertTrue(snapshot.windows.isEmpty)
    }

    func testBrowserSnapshotFromValidDictionaries() {
        let rawWindows: [NSDictionary] = [
            [
                "id": "w1",
                "givenName": "Default",
                "tabCount": 2,
                "tabs": [
                    ["id": "t1", "index": 1, "url": "https://example.com", "title": "Example", "active": true],
                    ["id": "t2", "index": 2, "url": "https://github.com", "title": "GitHub", "active": false],
                ],
            ],
        ]

        let snapshot = BrowserSnapshot.from(rawWindows)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].id, "w1")
        XCTAssertEqual(snapshot.windows[0].name, "Default")
        XCTAssertEqual(snapshot.windows[0].tabCount, 2)
        XCTAssertEqual(snapshot.windows[0].tabs.count, 2)
        XCTAssertEqual(snapshot.windows[0].tabs[0].id, "t1")
        XCTAssertEqual(snapshot.windows[0].tabs[0].url, "https://example.com")
        XCTAssertTrue(snapshot.windows[0].tabs[0].active)
    }

    func testBrowserSnapshotFromSkipsMalformedWindows() {
        let rawWindows: [NSDictionary] = [
            ["id": "w1"], // missing required fields
            [
                "id": "w2",
                "givenName": "Good",
                "tabCount": 0,
                "tabs": [] as [[String: Any]],
            ],
        ]

        let snapshot = BrowserSnapshot.from(rawWindows)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].id, "w2")
    }

    // MARK: - BrowserSnapshot.flatTabs

    func testFlatTabsEmpty() {
        let snapshot = makeSnapshot(windows: [])
        XCTAssertTrue(snapshot.flatTabs().isEmpty)
    }

    func testFlatTabsAcrossMultipleWindows() {
        let tab1 = makeTab(id: "t1", index: 1, url: "https://a.com")
        let tab2 = makeTab(id: "t2", index: 2, url: "https://b.com")
        let tab3 = makeTab(id: "t3", index: 1, url: "https://c.com")
        let window1 = makeWindow(id: "w1", name: "First", tabs: [tab1, tab2])
        let window2 = makeWindow(id: "w2", name: "Second", tabs: [tab3])
        let snapshot = makeSnapshot(windows: [window1, window2])

        let flat = snapshot.flatTabs()
        XCTAssertEqual(flat.count, 3)
        XCTAssertEqual(flat[0].windowId, "w1")
        XCTAssertEqual(flat[0].windowName, "First")
        XCTAssertEqual(flat[0].tabId, "t1")
        XCTAssertEqual(flat[2].windowId, "w2")
        XCTAssertEqual(flat[2].windowName, "Second")
    }

    // MARK: - WindowSnapshot Encoding (givenName key)

    func testWindowSnapshotEncodesNameAsGivenName() throws {
        let window = makeWindow(id: "w1", name: "MyWindow")
        let encoder = JSONEncoder()
        let data = try encoder.encode(window)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["givenName"] as? String, "MyWindow")
        XCTAssertNil(json["name"])
    }

    // MARK: - Tab Ordering Within/Across Windows

    func testMultipleTabsMatchInSameWindowFirstTabWins() {
        let tab1 = makeTab(id: "t1", index: 1, url: "https://github.com/acme/repo-a")
        let tab2 = makeTab(id: "t2", index: 2, url: "https://github.com/acme/repo-b")
        let window = makeWindow(id: "w1", tabs: [tab1, tab2])
        let snapshot = makeSnapshot(windows: [window])
        let action = makeAction(
            tabActions: [TabAction(pattern: "github\\.com", kind: .focus)]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .focusTab(_, _, tabIndex, _) = result else {
            return XCTFail("Expected .focusTab, got \(result)")
        }
        XCTAssertEqual(tabIndex, 1)
    }

    func testMultipleWindowsWithSameNameFindWindowReturnsFirst() {
        let tab1 = makeTab(id: "t1", index: 1, url: "https://github.com/acme/a")
        let tab2 = makeTab(id: "t2", index: 1, url: "https://github.com/acme/b")
        let window1 = makeWindow(id: "w1", name: "Work", tabs: [tab1])
        let window2 = makeWindow(id: "w2", name: "Work", tabs: [tab2])
        let snapshot = makeSnapshot(windows: [window1, window2])
        // No tab actions — just window target lookup
        let action = makeAction(windowTarget: "Work")

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .openInWindow(_, windowId, _, _) = result else {
            return XCTFail("Expected .openInWindow, got \(result)")
        }
        XCTAssertEqual(windowId, "w1")
    }

    func testMultipleWindowsWithSameNamePreferredSearchFindsTabInFirstMatch() {
        let tab1 = makeTab(id: "t1", index: 1, url: "https://github.com/acme/a")
        let tab2 = makeTab(id: "t2", index: 1, url: "https://github.com/acme/b")
        let window1 = makeWindow(id: "w1", name: "Work", tabs: [tab1])
        let window2 = makeWindow(id: "w2", name: "Work", tabs: [tab2])
        let snapshot = makeSnapshot(windows: [window1, window2])
        let action = makeAction(
            windowTarget: "Work",
            tabActions: [TabAction(pattern: "github\\.com", kind: .focus)]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .focusTab(_, windowId, _, _) = result else {
            return XCTFail("Expected .focusTab, got \(result)")
        }
        XCTAssertEqual(windowId, "w1")
    }

    func testNoPreferredWindowTabsAcrossMultipleWindowsFirstWindowWins() {
        let tab1 = makeTab(id: "t1", index: 1, url: "https://github.com/acme/a")
        let tab2 = makeTab(id: "t2", index: 1, url: "https://github.com/acme/b")
        let window1 = makeWindow(id: "w1", name: "Alpha", tabs: [tab1])
        let window2 = makeWindow(id: "w2", name: "Beta", tabs: [tab2])
        let snapshot = makeSnapshot(windows: [window1, window2])
        let action = makeAction(
            windowTarget: nil,
            tabActions: [TabAction(pattern: "github\\.com", kind: .focus)]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .focusTab(_, windowId, _, _) = result else {
            return XCTFail("Expected .focusTab, got \(result)")
        }
        XCTAssertEqual(windowId, "w1")
    }

    // MARK: - Regex Matching Details

    func testCaseInsensitiveURLMatching() {
        let tab = makeTab(id: "t1", index: 1, url: "https://GitHub.COM/User/Repo")
        let window = makeWindow(id: "w1", tabs: [tab])
        let snapshot = makeSnapshot(windows: [window])
        let action = makeAction(
            tabActions: [TabAction(pattern: "github\\.com", kind: .focus)]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case .focusTab = result else {
            return XCTFail("Expected .focusTab (case-insensitive match), got \(result)")
        }
    }

    func testPatternMatchesMidURL() {
        let tab = makeTab(id: "t1", index: 1, url: "https://github.com/user/repo")
        let window = makeWindow(id: "w1", tabs: [tab])
        let snapshot = makeSnapshot(windows: [window])
        let action = makeAction(
            tabActions: [TabAction(pattern: "github", kind: .focus)]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case .focusTab = result else {
            return XCTFail("Expected .focusTab (partial/mid-URL match), got \(result)")
        }
    }

    func testChromeSchemeURLMatching() {
        let tab = makeTab(id: "t1", index: 1, url: "chrome://settings")
        let window = makeWindow(id: "w1", tabs: [tab])
        let snapshot = makeSnapshot(windows: [window])
        let action = makeAction(
            tabActions: [TabAction(pattern: "chrome://settings", kind: .focus)]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case .focusTab = result else {
            return XCTFail("Expected .focusTab for chrome:// URL, got \(result)")
        }
    }

    // MARK: - bundleId and url Propagation

    func testNavigateTabUsesActionRouteURLNotTabURL() {
        let tab = makeTab(id: "t42", index: 3, url: "https://docs.google.com/document/d/ABC123/edit")
        let window = makeWindow(id: "w1", tabs: [tab])
        let snapshot = makeSnapshot(windows: [window])
        let action = makeAction(
            url: "https://docs.google.com/document/d/ABC123/edit?rm=minimal",
            tabActions: [TabAction(pattern: "docs\\.google\\.com/document/d/ABC123", kind: .use)]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .navigateTab(_, _, _, _, url, _) = result else {
            return XCTFail("Expected .navigateTab, got \(result)")
        }
        // url payload must come from the action's routeURL, not the matched tab's URL
        XCTAssertEqual(url, "https://docs.google.com/document/d/ABC123/edit?rm=minimal")
        XCTAssertNotEqual(url, tab.url)
    }

    func testFollowTabUsesActionRouteURL() {
        let tab = makeTab(id: "t1", index: 1, url: "https://github.com/acme/widgets")
        let window = makeWindow(id: "w5", tabs: [tab])
        let snapshot = makeSnapshot(windows: [window])
        let action = makeAction(
            url: "https://github.com/acme/new-feature",
            tabActions: [TabAction(pattern: "github\\.com/acme", kind: .follow)]
        )

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .openInWindow(_, _, url, _) = result else {
            return XCTFail("Expected .openInWindow, got \(result)")
        }
        XCTAssertEqual(url, "https://github.com/acme/new-feature")
        XCTAssertNotEqual(url, tab.url)
    }

    func testCreateWindowPreservesWindowTargetCasingExactly() {
        let snapshot = makeSnapshot(windows: [])
        let action = makeAction(windowTarget: "Work")

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .createWindow(_, windowName, _, _) = result else {
            return XCTFail("Expected .createWindow, got \(result)")
        }
        XCTAssertEqual(windowName, "Work")
    }
}
