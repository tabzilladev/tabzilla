import XCTest
@testable import Tabzilla

final class RuleEngineTests: XCTestCase {

    // MARK: - Basic URL Matching

    func testBasicURLMatch() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "github", url: "github\\.com", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: "Code", useTab: nil, focusTab: nil, followTab: nil)
            ]
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(url: URL(string: "https://github.com/user/repo")!)

        XCTAssertEqual(action.matchedRule, "github")
        XCTAssertEqual(action.windowTarget?.name, "Code")
        XCTAssertEqual(action.browser, "com.google.Chrome")  // From defaults
    }

    func testURLNoMatch() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "github", url: "github\\.com", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: "Code", useTab: nil, focusTab: nil, followTab: nil)
            ]
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(url: URL(string: "https://google.com/search")!)

        XCTAssertNil(action.matchedRule)
        XCTAssertEqual(action.windowTarget?.name, "Default")
        XCTAssertEqual(action.browser, "com.google.Chrome")
    }

    func testCaseInsensitiveURL() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "github", url: "(?i)github\\.com", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: "Code", useTab: nil, focusTab: nil, followTab: nil)
            ]
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(url: URL(string: "https://GITHUB.COM/user/repo")!)

        XCTAssertEqual(action.matchedRule, "github")
    }

    // MARK: - Source App Matching

    func testSourceAppMatch() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "slack", url: nil, sourceApp: "^com\\.tinyspeck\\.slackmacgap$", sourceWindowTitle: nil, browser: "com.google.Chrome.beta", window: "Work", useTab: nil, focusTab: nil, followTab: nil)
            ]
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(
            url: URL(string: "https://example.com")!,
            sourceApp: "com.tinyspeck.slackmacgap"
        )

        XCTAssertEqual(action.matchedRule, "slack")
        XCTAssertEqual(action.browser, "com.google.Chrome.beta")
        XCTAssertEqual(action.windowTarget?.name, "Work")
    }

    func testSourceAppNoMatch() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "slack", url: nil, sourceApp: "^com\\.tinyspeck\\.slackmacgap$", sourceWindowTitle: nil, browser: "com.google.Chrome.beta", window: "Work", useTab: nil, focusTab: nil, followTab: nil)
            ]
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(
            url: URL(string: "https://example.com")!,
            sourceApp: "com.apple.mail"
        )

        XCTAssertNil(action.matchedRule)
    }

    // MARK: - Source Window Title Matching

    func testSourceWindowTitleMatch() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "work-slack", url: nil, sourceApp: "^com\\.tinyspeck\\.slackmacgap$", sourceWindowTitle: "(?i)work", browser: "com.google.Chrome.beta", window: "Work", useTab: nil, focusTab: nil, followTab: nil)
            ]
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(
            url: URL(string: "https://example.com")!,
            sourceApp: "com.tinyspeck.slackmacgap",
            sourceWindowTitle: "general - Work Corp - Slack"
        )

        XCTAssertEqual(action.matchedRule, "work-slack")
        XCTAssertEqual(action.windowTarget?.name, "Work")
    }

    func testSourceWindowTitleNoMatch() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "work-slack", url: nil, sourceApp: "^com\\.tinyspeck\\.slackmacgap$", sourceWindowTitle: "(?i)work", browser: "com.google.Chrome.beta", window: "Work", useTab: nil, focusTab: nil, followTab: nil)
            ]
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(
            url: URL(string: "https://example.com")!,
            sourceApp: "com.tinyspeck.slackmacgap",
            sourceWindowTitle: "general - Personal - Slack"
        )

        XCTAssertNil(action.matchedRule)
    }

    // MARK: - Combined Matching (AND logic)

    func testCombinedMatch() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "work-github", url: "github\\.com", sourceApp: "^com\\.tinyspeck\\.slackmacgap$", sourceWindowTitle: "(?i)work", browser: "com.google.Chrome.beta", window: "Work-Code", useTab: nil, focusTab: nil, followTab: nil)
            ]
        )

        let engine = RuleEngine(config: config)

        // All conditions match
        let action1 = engine.testMatch(
            url: URL(string: "https://github.com/user/repo")!,
            sourceApp: "com.tinyspeck.slackmacgap",
            sourceWindowTitle: "general - Work Corp - Slack"
        )
        XCTAssertEqual(action1.matchedRule, "work-github")

        // URL doesn't match
        let action2 = engine.testMatch(
            url: URL(string: "https://google.com")!,
            sourceApp: "com.tinyspeck.slackmacgap",
            sourceWindowTitle: "general - Work Corp - Slack"
        )
        XCTAssertNil(action2.matchedRule)

        // Source app doesn't match
        let action3 = engine.testMatch(
            url: URL(string: "https://github.com/user/repo")!,
            sourceApp: "com.apple.mail",
            sourceWindowTitle: "general - Work Corp - Slack"
        )
        XCTAssertNil(action3.matchedRule)
    }

    // MARK: - Tab Reuse

    func testUseTabPattern() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "google-docs", url: "docs\\.google\\.com/document/d/([^/]+)", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: nil, useTab: "docs\\.google\\.com/document/d/\\1", focusTab: nil, followTab: nil)
            ]
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(url: URL(string: "https://docs.google.com/document/d/ABC123/edit#heading=h.xyz")!)

        XCTAssertEqual(action.matchedRule, "google-docs")
        XCTAssertEqual(action.tabActions.count, 1)
        XCTAssertEqual(action.tabActions.first?.kind, .use)
        XCTAssertEqual(action.tabActions.first?.pattern, "docs\\.google\\.com/document/d/ABC123")
    }

    func testFocusTabPattern() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "jira", url: "jira\\.example\\.com/browse/(\\w+-\\d+)", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: nil, useTab: nil, focusTab: "jira\\.example\\.com/browse/\\1", followTab: nil)
            ]
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(url: URL(string: "https://jira.example.com/browse/PROJ-123")!)

        XCTAssertEqual(action.matchedRule, "jira")
        XCTAssertEqual(action.tabActions.count, 1)
        XCTAssertEqual(action.tabActions.first?.kind, .focus)
        XCTAssertEqual(action.tabActions.first?.pattern, "jira\\.example\\.com/browse/PROJ-123")
    }

    // MARK: - Rule Priority

    func testRulePriority() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "specific", url: "github\\.com/airbnb", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: "Airbnb", useTab: nil, focusTab: nil, followTab: nil),
                Config.Rule(name: "general", url: "github\\.com", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: "Code", useTab: nil, focusTab: nil, followTab: nil),
                Config.Rule(name: "catchall", url: ".*", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: nil, useTab: nil, focusTab: nil, followTab: nil)
            ]
        )

        let engine = RuleEngine(config: config)

        // Should match most specific first
        let action1 = engine.testMatch(url: URL(string: "https://github.com/airbnb/repo")!)
        XCTAssertEqual(action1.matchedRule, "specific")
        XCTAssertEqual(action1.windowTarget?.name, "Airbnb")

        // Should match second rule
        let action2 = engine.testMatch(url: URL(string: "https://github.com/other/repo")!)
        XCTAssertEqual(action2.matchedRule, "general")
        XCTAssertEqual(action2.windowTarget?.name, "Code")

        // Should match catchall
        let action3 = engine.testMatch(url: URL(string: "https://example.com")!)
        XCTAssertEqual(action3.matchedRule, "catchall")
    }

    // MARK: - Default Fallback

    func testDefaultFallback() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome.beta", window: "MyDefault"),
            rules: []
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(url: URL(string: "https://example.com")!)

        XCTAssertNil(action.matchedRule)
        XCTAssertEqual(action.browser, "com.google.Chrome.beta")
        XCTAssertEqual(action.windowTarget?.name, "MyDefault")
    }

    // MARK: - Invalid Regex Handling

    func testInvalidRegexInURL() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "invalid", url: "[invalid(regex", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: "Test", useTab: nil, focusTab: nil, followTab: nil),
                Config.Rule(name: "catchall", url: ".*", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: nil, useTab: nil, focusTab: nil, followTab: nil)
            ]
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(url: URL(string: "https://example.com")!)

        // Should skip invalid rule and match catchall
        XCTAssertEqual(action.matchedRule, "catchall")
    }

    // MARK: - Complex Regex Patterns

    func testComplexRegexPatterns() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                // Multiple domains with OR
                Config.Rule(name: "work-domains", url: "(?i)(corp|jira|wiki)\\.example\\.com", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: "Work", useTab: nil, focusTab: nil, followTab: nil),
                // Production-only pattern (matches app.myapp.com but not staging.myapp.com)
                Config.Rule(name: "prod-only", url: "://app\\.myapp\\.com", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: "Prod", useTab: nil, focusTab: nil, followTab: nil)
            ]
        )

        let engine = RuleEngine(config: config)

        // Test multiple domains
        let action1 = engine.testMatch(url: URL(string: "https://corp.example.com/page")!)
        XCTAssertEqual(action1.matchedRule, "work-domains")

        let action2 = engine.testMatch(url: URL(string: "https://JIRA.EXAMPLE.COM/browse/PROJ-1")!)
        XCTAssertEqual(action2.matchedRule, "work-domains")

        // Test subdomain-specific pattern
        let action3 = engine.testMatch(url: URL(string: "https://app.myapp.com/dashboard")!)
        XCTAssertEqual(action3.matchedRule, "prod-only")

        let action4 = engine.testMatch(url: URL(string: "https://staging.myapp.com/dashboard")!)
        XCTAssertNil(action4.matchedRule)  // Should not match since it's staging subdomain
    }

    // MARK: - followTab Tests

    func testFollowTabPattern() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "github", url: "github\\.com/([^/]+/[^/]+)", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: nil, useTab: nil, focusTab: nil, followTab: "github\\.com/\\1")
            ]
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(url: URL(string: "https://github.com/acme/widgets")!)

        XCTAssertEqual(action.matchedRule, "github")
        XCTAssertEqual(action.tabActions.count, 1)
        XCTAssertEqual(action.tabActions.first?.kind, .follow)
        // Captured group "acme/widgets" is regex-escaped, so "/" becomes "\/"
        XCTAssertEqual(action.tabActions.first?.pattern, "github\\.com/acme\\/widgets")
    }

    func testMultipleTabActionsOrdering() {
        // Test that multiple tab actions are ordered: focusTab → useTab → followTab
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "github", url: "github\\.com/([^/]+/[^/]+)", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: nil, useTab: "github\\.com/\\1/issues", focusTab: "github\\.com/\\1$", followTab: "github\\.com")
            ]
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(url: URL(string: "https://github.com/acme/widgets")!)

        XCTAssertEqual(action.matchedRule, "github")
        XCTAssertEqual(action.tabActions.count, 3)
        // Order should be: focus, use, follow
        // Captured group "acme/widgets" is regex-escaped, so "/" becomes "\/"
        XCTAssertEqual(action.tabActions[0].kind, .focus)
        XCTAssertEqual(action.tabActions[0].pattern, "github\\.com/acme\\/widgets$")
        XCTAssertEqual(action.tabActions[1].kind, .use)
        XCTAssertEqual(action.tabActions[1].pattern, "github\\.com/acme\\/widgets/issues")
        XCTAssertEqual(action.tabActions[2].kind, .follow)
        XCTAssertEqual(action.tabActions[2].pattern, "github\\.com")
    }

    func testNoTabActionsWhenNotSpecified() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "github", url: "github\\.com", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: "Code", useTab: nil, focusTab: nil, followTab: nil)
            ]
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(url: URL(string: "https://github.com/user/repo")!)

        XCTAssertEqual(action.matchedRule, "github")
        XCTAssertTrue(action.tabActions.isEmpty)
    }

    func testSingleTabActionBackwardCompatibility() {
        // Verify that specifying only useTab still works correctly
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "docs", url: "docs\\.google\\.com", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: nil, useTab: "docs\\.google\\.com", focusTab: nil, followTab: nil)
            ]
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(url: URL(string: "https://docs.google.com/document")!)

        XCTAssertEqual(action.tabActions.count, 1)
        XCTAssertEqual(action.tabActions.first?.kind, .use)
    }

    // MARK: - Chrome URL Scheme Matching

    func testChromeURLMatch() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "chrome-internal", url: "^chrome://", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: "Settings", useTab: nil, focusTab: nil, followTab: nil)
            ]
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(url: URL(string: "chrome://newtab")!)

        XCTAssertEqual(action.matchedRule, "chrome-internal")
        XCTAssertEqual(action.windowTarget?.name, "Settings")
    }

    func testChromeURLNoMatchDifferentPage() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "chrome-settings", url: "^chrome://settings", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: "Settings", useTab: nil, focusTab: nil, followTab: nil)
            ]
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(url: URL(string: "chrome://newtab")!)

        XCTAssertNil(action.matchedRule)
    }

    func testChromeSettingsWithUseTab() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "chrome-settings", url: "^chrome://settings", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: nil, useTab: "chrome://settings", focusTab: nil, followTab: nil)
            ]
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(url: URL(string: "chrome://settings")!)

        XCTAssertEqual(action.matchedRule, "chrome-settings")
        XCTAssertEqual(action.tabActions.count, 1)
        XCTAssertEqual(action.tabActions.first?.kind, .use)
        XCTAssertEqual(action.tabActions.first?.pattern, "chrome://settings")
    }

    func testChromeExtensionURLMatch() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "extension", url: "^chrome-extension://", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: "Extensions", useTab: nil, focusTab: nil, followTab: nil)
            ]
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(url: URL(string: "chrome-extension://abcdef1234567890/options.html")!)

        XCTAssertEqual(action.matchedRule, "extension")
        XCTAssertEqual(action.windowTarget?.name, "Extensions")
    }

    func testCatchAllMatchesChromeURLs() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "catchall", url: ".*", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: nil, useTab: nil, focusTab: nil, followTab: nil)
            ]
        )

        let engine = RuleEngine(config: config)

        let action1 = engine.testMatch(url: URL(string: "chrome://newtab")!)
        XCTAssertEqual(action1.matchedRule, "catchall")

        let action2 = engine.testMatch(url: URL(string: "chrome-extension://abc/page.html")!)
        XCTAssertEqual(action2.matchedRule, "catchall")
    }

    func testCaptureGroupsAreRegexEscaped() {
        // Verify that regex metacharacters in captured groups are escaped
        // so they match literally (e.g., "?" in query strings)
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "pr-with-query", url: "github\\.com/([^/]+/[^/]+)/pull/(\\d+)(.*)", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: nil, useTab: nil, focusTab: "github\\.com/\\1/pull/\\2\\3$", followTab: "github\\.com/\\1/pull/\\2")
            ]
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(url: URL(string: "https://github.com/user/repo/pull/123?foo=bar")!)

        XCTAssertEqual(action.matchedRule, "pr-with-query")
        XCTAssertEqual(action.tabActions.count, 2)
        // The "?" should be escaped to "\?" so it matches literally
        XCTAssertEqual(action.tabActions[0].pattern, "github\\.com/user\\/repo/pull/123\\?foo=bar$")
        XCTAssertEqual(action.tabActions[1].pattern, "github\\.com/user\\/repo/pull/123")
    }
}
