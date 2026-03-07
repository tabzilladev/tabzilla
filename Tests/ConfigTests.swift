import XCTest
import Yams
@testable import Tabzilla

final class ConfigTests: XCTestCase {
    // MARK: - YAML Parsing

    func testParseMinimalConfig() throws {
        let yaml = """
        version: 1
        defaults:
          browser: com.google.Chrome
          window: Default
        rules: []
        """

        let config = try parseYAML(yaml)

        XCTAssertEqual(config.version, 1)
        XCTAssertEqual(config.defaults.browser, "com.google.Chrome")
        XCTAssertEqual(config.defaults.window, "Default")
        XCTAssertTrue(config.rules.isEmpty)
    }

    func testParseFullConfig() throws {
        let yaml = """
        version: 1
        defaults:
          browser: com.google.Chrome
          window: Default

        rules:
          - name: work
            url: corp\\.example\\.com
            browser: com.google.Chrome.beta
            window: Work

          - name: slack-work
            sourceApp: ^com\\.tinyspeck\\.slackmacgap$
            sourceWindowTitle: (?i)work
            window: Slack-Work

          - name: google-docs
            url: docs\\.google\\.com/document/d/([^/]+)
            useTab: docs\\.google\\.com/document/d/\\1

          - url: .*
        """

        let config = try parseYAML(yaml)

        XCTAssertEqual(config.version, 1)
        XCTAssertEqual(config.rules.count, 4)

        // First rule
        XCTAssertEqual(config.rules[0].name, "work")
        XCTAssertEqual(config.rules[0].url, "corp\\.example\\.com")
        XCTAssertEqual(config.rules[0].browser, "com.google.Chrome.beta")
        XCTAssertEqual(config.rules[0].window, "Work")

        // Second rule
        XCTAssertEqual(config.rules[1].name, "slack-work")
        XCTAssertEqual(config.rules[1].sourceApp, "^com\\.tinyspeck\\.slackmacgap$")
        XCTAssertEqual(config.rules[1].sourceWindowTitle, "(?i)work")

        // Third rule - tab reuse
        XCTAssertEqual(config.rules[2].name, "google-docs")
        XCTAssertEqual(config.rules[2].useTab, "docs\\.google\\.com/document/d/\\1")

        // Fourth rule - catch-all
        XCTAssertEqual(config.rules[3].url, ".*")
        XCTAssertNil(config.rules[3].name)
    }

    func testParseConfigWithFocusTab() throws {
        let yaml = """
        version: 1
        defaults:
          browser: com.google.Chrome
          window: Default
        rules:
          - name: jira
            url: jira\\.example\\.com/browse/(\\w+-\\d+)
            focusTab: jira\\.example\\.com/browse/\\1
        """

        let config = try parseYAML(yaml)

        XCTAssertEqual(config.rules[0].focusTab, "jira\\.example\\.com/browse/\\1")
        XCTAssertNil(config.rules[0].useTab)
    }

    // MARK: - Config Search Paths

    func testSearchPathsOrder() {
        let paths = ConfigurationManager.searchPaths
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        XCTAssertEqual(paths.count, 3)
        XCTAssertEqual(paths[0], "\(home)/.config/tabz/config.yaml")
        XCTAssertEqual(paths[1], "\(home)/Library/Application Support/Tabzilla/config.yaml")
        XCTAssertEqual(paths[2], "\(home)/.tabz.yaml")
    }

    // MARK: - ConfigurationManager File Loading

    func testLoadConfigFromValidFile() throws {
        let yaml = """
        version: 1
        defaults:
          browser: com.google.Chrome.beta
          window: TestWindow
        rules:
          - name: test-rule
            url: example\\.com
            window: Example
        """

        let tempDir = FileManager.default.temporaryDirectory
        let configPath = tempDir.appendingPathComponent("tabz-test-\(UUID().uuidString).yaml")
        try yaml.write(to: configPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: configPath) }

        let config = try ConfigurationManager.loadConfig(from: configPath.path)

        XCTAssertEqual(config.version, 1)
        XCTAssertEqual(config.defaults.browser, "com.google.Chrome.beta")
        XCTAssertEqual(config.defaults.window, "TestWindow")
        XCTAssertEqual(config.rules.count, 1)
        XCTAssertEqual(config.rules[0].name, "test-rule")
    }

    func testLoadConfigFromInvalidFileThrows() throws {
        let invalidYaml = """
        version: 1
        defaults:
          browser: [malformed yaml
        """

        let tempDir = FileManager.default.temporaryDirectory
        let configPath = tempDir.appendingPathComponent("tabz-test-\(UUID().uuidString).yaml")
        try invalidYaml.write(to: configPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: configPath) }

        XCTAssertThrowsError(try ConfigurationManager.loadConfig(from: configPath.path))
    }

    func testLoadConfigFromNonexistentFileThrows() {
        let bogusPath = "/tmp/tabz-nonexistent-\(UUID().uuidString).yaml"

        XCTAssertThrowsError(try ConfigurationManager.loadConfig(from: bogusPath))
    }

    // MARK: - Invalid Config Handling

    func testInvalidYAML() {
        let yaml = """
        version: 1
        defaults:
          browser: [invalid yaml
        """

        XCTAssertThrowsError(try parseYAML(yaml))
    }

    func testMissingRequiredFields() {
        // Missing defaults
        let yaml1 = """
        version: 1
        rules: []
        """

        XCTAssertThrowsError(try parseYAML(yaml1))

        // Missing version
        let yaml2 = """
        defaults:
          browser: com.google.Chrome
          window: Default
        rules: []
        """

        XCTAssertThrowsError(try parseYAML(yaml2))
    }

    // MARK: - Helpers

    private func parseYAML(_ yaml: String) throws -> Config {
        let decoder = YAMLDecoder()
        return try decoder.decode(Config.self, from: yaml)
    }
}
