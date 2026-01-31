import XCTest
@testable import Tabzilla

final class RuleEngineTests: XCTestCase {

    // MARK: - Basic URL Matching

    func testBasicURLMatch() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "github", url: "github\\.com", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: "Code", useTab: nil, focusTab: nil)
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
                Config.Rule(name: "github", url: "github\\.com", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: "Code", useTab: nil, focusTab: nil)
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
                Config.Rule(name: "github", url: "(?i)github\\.com", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: "Code", useTab: nil, focusTab: nil)
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
                Config.Rule(name: "slack", url: nil, sourceApp: "^com\\.tinyspeck\\.slackmacgap$", sourceWindowTitle: nil, browser: "com.google.Chrome.beta", window: "Work", useTab: nil, focusTab: nil)
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
                Config.Rule(name: "slack", url: nil, sourceApp: "^com\\.tinyspeck\\.slackmacgap$", sourceWindowTitle: nil, browser: "com.google.Chrome.beta", window: "Work", useTab: nil, focusTab: nil)
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
                Config.Rule(name: "work-slack", url: nil, sourceApp: "^com\\.tinyspeck\\.slackmacgap$", sourceWindowTitle: "(?i)work", browser: "com.google.Chrome.beta", window: "Work", useTab: nil, focusTab: nil)
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
                Config.Rule(name: "work-slack", url: nil, sourceApp: "^com\\.tinyspeck\\.slackmacgap$", sourceWindowTitle: "(?i)work", browser: "com.google.Chrome.beta", window: "Work", useTab: nil, focusTab: nil)
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
                Config.Rule(name: "work-github", url: "github\\.com", sourceApp: "^com\\.tinyspeck\\.slackmacgap$", sourceWindowTitle: "(?i)work", browser: "com.google.Chrome.beta", window: "Work-Code", useTab: nil, focusTab: nil)
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
                Config.Rule(name: "google-docs", url: "docs\\.google\\.com/document/d/([^/]+)", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: nil, useTab: "docs\\.google\\.com/document/d/\\1", focusTab: nil)
            ]
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(url: URL(string: "https://docs.google.com/document/d/ABC123/edit#heading=h.xyz")!)

        XCTAssertEqual(action.matchedRule, "google-docs")
        XCTAssertNotNil(action.tabAction)
        XCTAssertEqual(action.tabAction?.navigate, true)
        XCTAssertEqual(action.tabAction?.pattern, "docs\\.google\\.com/document/d/ABC123")
    }

    func testFocusTabPattern() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "jira", url: "jira\\.example\\.com/browse/(\\w+-\\d+)", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: nil, useTab: nil, focusTab: "jira\\.example\\.com/browse/\\1")
            ]
        )

        let engine = RuleEngine(config: config)
        let action = engine.testMatch(url: URL(string: "https://jira.example.com/browse/PROJ-123")!)

        XCTAssertEqual(action.matchedRule, "jira")
        XCTAssertNotNil(action.tabAction)
        XCTAssertEqual(action.tabAction?.navigate, false)
        XCTAssertEqual(action.tabAction?.pattern, "jira\\.example\\.com/browse/PROJ-123")
    }

    // MARK: - Rule Priority

    func testRulePriority() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome", window: "Default"),
            rules: [
                Config.Rule(name: "specific", url: "github\\.com/airbnb", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: "Airbnb", useTab: nil, focusTab: nil),
                Config.Rule(name: "general", url: "github\\.com", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: "Code", useTab: nil, focusTab: nil),
                Config.Rule(name: "catchall", url: ".*", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: nil, useTab: nil, focusTab: nil)
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
                Config.Rule(name: "invalid", url: "[invalid(regex", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: "Test", useTab: nil, focusTab: nil),
                Config.Rule(name: "catchall", url: ".*", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: nil, useTab: nil, focusTab: nil)
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
                Config.Rule(name: "work-domains", url: "(?i)(corp|jira|wiki)\\.example\\.com", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: "Work", useTab: nil, focusTab: nil),
                // Production-only pattern (matches app.myapp.com but not staging.myapp.com)
                Config.Rule(name: "prod-only", url: "://app\\.myapp\\.com", sourceApp: nil, sourceWindowTitle: nil, browser: nil, window: "Prod", useTab: nil, focusTab: nil)
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
}
