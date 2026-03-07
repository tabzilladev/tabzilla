import XCTest
@testable import Tabzilla

/// Integration tests: Config → RuleEngine → RouteResolver → ResolvedRoute
///
/// Each test wires a Config with a RuleEngine and a synthetic BrowserSnapshot
/// to verify the full routing pipeline without a browser.
final class RoutingPipelineTests: XCTestCase {
    private let resolver = RouteResolver()
    private let chromeBundleId = "com.google.Chrome"
    private let safariBundleId = "com.apple.Safari"

    // MARK: - Helpers

    private func makeConfig(
        defaults: Config.Defaults = Config.Defaults(browser: "com.google.Chrome"),
        rules: [Config.Rule] = []
    ) -> Config {
        Config(defaults: defaults, rules: rules)
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

    // MARK: - useTab with capture groups

    func testUseTabWithCaptureGroupsMatchesExistingTab() throws {
        let config = makeConfig(rules: [
            Config.Rule(
                name: "gdocs",
                url: "docs\\.google\\.com/document/d/([^/]+)",
                useTab: "docs\\.google\\.com/document/d/\\1"
            ),
        ])
        let engine = RuleEngine(config: config)

        let url = try XCTUnwrap(URL(string: "https://docs.google.com/document/d/ABC123/edit"))
        let action = engine.testMatch(url: url)

        let tab = makeTab(id: "t42", index: 3, url: "https://docs.google.com/document/d/ABC123/view")
        let window = makeWindow(id: "w1", tabs: [tab])
        let snapshot = makeSnapshot(windows: [window])

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .navigateTab(bundleId, windowId, tabId, _, _, _) = result else {
            return XCTFail("Expected .navigateTab, got \(result)")
        }
        XCTAssertEqual(bundleId, chromeBundleId)
        XCTAssertEqual(windowId, "w1")
        XCTAssertEqual(tabId, "t42")
    }

    // MARK: - focusTab with capture groups

    func testFocusTabWithCaptureGroupsMatchesExistingTab() throws {
        let config = makeConfig(rules: [
            Config.Rule(
                name: "gdocs-focus",
                url: "docs\\.google\\.com/document/d/([^/]+)",
                focusTab: "docs\\.google\\.com/document/d/\\1"
            ),
        ])
        let engine = RuleEngine(config: config)

        let url = try XCTUnwrap(URL(string: "https://docs.google.com/document/d/XYZ789/edit"))
        let action = engine.testMatch(url: url)

        let tab = makeTab(id: "t7", index: 2, url: "https://docs.google.com/document/d/XYZ789/view")
        let window = makeWindow(id: "w2", tabs: [tab])
        let snapshot = makeSnapshot(windows: [window])

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .focusTab(bundleId, windowId, tabIndex, _) = result else {
            return XCTFail("Expected .focusTab, got \(result)")
        }
        XCTAssertEqual(bundleId, chromeBundleId)
        XCTAssertEqual(windowId, "w2")
        XCTAssertEqual(tabIndex, 2)
    }

    // MARK: - followTab matches, opens in matched tab's window

    func testFollowTabMatchOpensInMatchedTabsWindow() throws {
        let config = makeConfig(rules: [
            Config.Rule(
                name: "acme",
                url: "github\\.com/acme",
                followTab: "github\\.com/acme"
            ),
        ])
        let engine = RuleEngine(config: config)

        let url = try XCTUnwrap(URL(string: "https://github.com/acme/new-feature"))
        let action = engine.testMatch(url: url)

        let tab = makeTab(id: "t1", index: 1, url: "https://github.com/acme/widgets")
        let window = makeWindow(id: "w5", name: "Code", tabs: [tab])
        let snapshot = makeSnapshot(windows: [window])

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .openInWindow(bundleId, windowId, resultUrl, _) = result else {
            return XCTFail("Expected .openInWindow, got \(result)")
        }
        XCTAssertEqual(bundleId, chromeBundleId)
        XCTAssertEqual(windowId, "w5")
        XCTAssertEqual(resultUrl, url.absoluteString)
    }

    // MARK: - Tab miss falls through to window target from rule

    func testTabMissFallsThroughToWindowTarget() throws {
        let config = makeConfig(rules: [
            Config.Rule(
                name: "work",
                url: "github\\.com",
                window: "Work",
                focusTab: "nonexistent\\.pattern"
            ),
        ])
        let engine = RuleEngine(config: config)

        let url = try XCTUnwrap(URL(string: "https://github.com/user/repo"))
        let action = engine.testMatch(url: url)

        let workWindow = makeWindow(id: "w3", name: "Work", tabs: [])
        let snapshot = makeSnapshot(windows: [workWindow])

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .openInWindow(_, windowId, _, _) = result else {
            return XCTFail("Expected .openInWindow, got \(result)")
        }
        XCTAssertEqual(windowId, "w3")
    }

    // MARK: - Tab miss falls through to window create

    func testTabMissFallsThroughToCreateWindow() throws {
        let config = makeConfig(rules: [
            Config.Rule(
                name: "work",
                url: "github\\.com",
                window: "Work",
                focusTab: "nonexistent\\.pattern"
            ),
        ])
        let engine = RuleEngine(config: config)

        let url = try XCTUnwrap(URL(string: "https://github.com/user/repo"))
        let action = engine.testMatch(url: url)

        // No window named "Work" in snapshot
        let snapshot = makeSnapshot(windows: [makeWindow(id: "w1", name: "Personal")])

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .createWindow(_, windowName, _, _) = result else {
            return XCTFail("Expected .createWindow, got \(result)")
        }
        XCTAssertEqual(windowName, "Work")
    }

    // MARK: - Priority: focusTab beats useTab

    func testFocusTabBeatsuseTabWhenBothPatternMatch() throws {
        let config = makeConfig(rules: [
            Config.Rule(
                name: "github",
                url: "github\\.com",
                useTab: "github\\.com",
                focusTab: "github\\.com"
            ),
        ])
        let engine = RuleEngine(config: config)

        let url = try XCTUnwrap(URL(string: "https://github.com/user/repo"))
        let action = engine.testMatch(url: url)

        // focusTab comes before useTab in the tabActions array (rule engine priority order)
        XCTAssertEqual(action.tabActions.first?.kind, .focus, "focusTab should be first in tabActions")

        let tab = makeTab(id: "t1", index: 1, url: "https://github.com/user/repo")
        let window = makeWindow(id: "w1", tabs: [tab])
        let snapshot = makeSnapshot(windows: [window])

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case .focusTab = result else {
            return XCTFail("Expected .focusTab (focus wins over use), got \(result)")
        }
    }

    // MARK: - focusTab miss, useTab hit

    func testFocusTabMissUseTabHitReturnsNavigateTab() throws {
        let config = makeConfig(rules: [
            Config.Rule(
                name: "mixed",
                url: "github\\.com",
                useTab: "github\\.com",
                focusTab: "nonexistent\\.pattern"
            ),
        ])
        let engine = RuleEngine(config: config)

        let url = try XCTUnwrap(URL(string: "https://github.com/user/repo"))
        let action = engine.testMatch(url: url)

        let tab = makeTab(id: "t1", index: 1, url: "https://github.com/user/repo")
        let window = makeWindow(id: "w1", tabs: [tab])
        let snapshot = makeSnapshot(windows: [window])

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case .navigateTab = result else {
            return XCTFail("Expected .navigateTab (focusTab miss, useTab hit), got \(result)")
        }
    }

    // MARK: - No rules match → defaults

    func testNoRulesMatchUsesDefaultsAndOpensInDefaultWindow() throws {
        let config = makeConfig(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "github", url: "github\\.com", window: "Code"),
            ]
        )
        let engine = RuleEngine(config: config)

        // URL that doesn't match any rule
        let url = try XCTUnwrap(URL(string: "https://example.com/page"))
        let action = engine.testMatch(url: url)

        XCTAssertNil(action.matchedRule)
        XCTAssertEqual(action.windowTarget, "Default")

        let defaultWindow = makeWindow(id: "w1", name: "Default", tabs: [])
        let snapshot = makeSnapshot(windows: [defaultWindow])

        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: true)

        guard case let .openInWindow(bundleId, windowId, _, _) = result else {
            return XCTFail("Expected .openInWindow with default window, got \(result)")
        }
        XCTAssertEqual(bundleId, chromeBundleId)
        XCTAssertEqual(windowId, "w1")
    }

    // MARK: - Non-Chrome browser in rule

    func testNonChromeBrowserInRuleReturnsOpenWithWorkspace() throws {
        let config = makeConfig(rules: [
            Config.Rule(
                name: "safari-rule",
                url: "example\\.com",
                browser: safariBundleId
            ),
        ])
        let engine = RuleEngine(config: config)

        let url = try XCTUnwrap(URL(string: "https://example.com/page"))
        let action = engine.testMatch(url: url)

        XCTAssertEqual(action.browser, safariBundleId)

        let snapshot = makeSnapshot(windows: [makeWindow()])
        let result = resolver.resolve(action: action, snapshot: snapshot, isChromeBasedBrowser: false)

        guard case let .openWithWorkspace(bundleId, resultUrl, _) = result else {
            return XCTFail("Expected .openWithWorkspace for non-Chrome browser, got \(result)")
        }
        XCTAssertEqual(bundleId, safariBundleId)
        XCTAssertEqual(resultUrl.absoluteString, url.absoluteString)
    }
}
