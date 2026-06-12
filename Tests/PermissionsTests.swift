import XCTest
@testable import Tabzilla

final class PermissionsTests: XCTestCase {
    // MARK: - browsersFromConfig

    func testBrowsersFromConfigIncludesDefaultAndRuleOverrides() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome"),
            rules: [
                Config.Rule(url: "a", browser: "com.google.Chrome.beta"),
                Config.Rule(url: "b", browser: "com.apple.Safari"),
                Config.Rule(url: "c"), // no override — should not add anything
            ]
        )

        XCTAssertEqual(
            browsersFromConfig(config),
            ["com.google.Chrome", "com.google.Chrome.beta", "com.apple.Safari"]
        )
    }

    func testBrowsersFromConfigDeduplicates() {
        let config = Config(
            defaults: Config.Defaults(browser: "com.google.Chrome"),
            rules: [
                Config.Rule(url: "a", browser: "com.google.Chrome"),
                Config.Rule(url: "b", browser: "com.google.Chrome"),
            ]
        )

        XCTAssertEqual(browsersFromConfig(config), ["com.google.Chrome"])
    }

    func testBrowsersFromConfigDefaultOnly() {
        let config = Config(defaults: Config.Defaults(browser: "com.google.Chrome"), rules: [])
        XCTAssertEqual(browsersFromConfig(config), ["com.google.Chrome"])
    }

    // MARK: - isTabzillaDefaultBrowser

    func testIsTabzillaDefaultBrowser() {
        XCTAssertTrue(isTabzillaDefaultBrowser("dev.tabzilla.Tabzilla"))
        XCTAssertFalse(isTabzillaDefaultBrowser("com.google.Chrome"))
        XCTAssertFalse(isTabzillaDefaultBrowser(nil))
    }

    // MARK: - CheckStatus

    func testCheckStatusSymbols() {
        XCTAssertEqual(CheckStatus.pass.symbol, "✓")
        XCTAssertEqual(CheckStatus.fail.symbol, "✗")
        XCTAssertEqual(CheckStatus.notDetermined.symbol, "✗")
        XCTAssertEqual(CheckStatus.unknown.symbol, "?")
        XCTAssertEqual(CheckStatus.notApplicable.symbol, "—")
    }

    func testCheckStatusNeedsAttention() {
        XCTAssertTrue(CheckStatus.fail.needsAttention)
        XCTAssertTrue(CheckStatus.notDetermined.needsAttention)
        XCTAssertFalse(CheckStatus.pass.needsAttention)
        XCTAssertFalse(CheckStatus.notApplicable.needsAttention)
    }

    // MARK: - DoctorReport with unknown status

    func testDoctorReportUnknownIsNotAllClear() {
        let report = DoctorReport(checks: [
            .init(name: "Accessibility", status: .unknown, detail: "daemon down"),
        ])
        XCTAssertFalse(report.allClear)
    }

    func testDoctorReportTextLinesShowsHintForUnknown() {
        let report = DoctorReport(checks: [
            .init(name: "Accessibility", status: .unknown, detail: "start the daemon"),
        ])
        let text = report.textLines().joined(separator: "\n")
        XCTAssertTrue(text.contains("?"))
        XCTAssertTrue(text.contains("start the daemon"))
    }

    // MARK: - PermissionProbe

    func testPermissionProbeRequestResultRoundTrip() throws {
        let request = PermissionProbe.Request(
            token: "tok-123",
            checkAccessibility: true,
            promptAccessibility: false,
            automationTargets: ["com.google.Chrome"],
            promptAutomation: true
        )
        let reqData = try JSONEncoder().encode(request)
        let decodedReq = try JSONDecoder().decode(PermissionProbe.Request.self, from: reqData)
        XCTAssertEqual(decodedReq.token, "tok-123")
        XCTAssertTrue(decodedReq.checkAccessibility)
        XCTAssertFalse(decodedReq.promptAccessibility)
        XCTAssertEqual(decodedReq.automationTargets, ["com.google.Chrome"])
        XCTAssertTrue(decodedReq.promptAutomation)

        let result = PermissionProbe.Result(
            token: "tok-123",
            accessibility: true,
            automation: ["com.google.Chrome": .granted, "com.google.Chrome.beta": .denied]
        )
        let resData = try JSONEncoder().encode(result)
        let decodedRes = try JSONDecoder().decode(PermissionProbe.Result.self, from: resData)
        XCTAssertEqual(decodedRes.token, "tok-123")
        XCTAssertEqual(decodedRes.accessibility, true)
        XCTAssertEqual(decodedRes.automation["com.google.Chrome"], .granted)
        XCTAssertEqual(decodedRes.automation["com.google.Chrome.beta"], .denied)
    }

    func testPermissionProbeResponsePathUsesToken() {
        let path = PermissionProbe.responsePath(token: "abc")
        XCTAssertTrue(path.hasSuffix("probe-response-abc.json"))
        XCTAssertTrue(path.contains("Tabzilla"))
    }

    func testPermissionProbeRequestDefaultTokenIsUnique() {
        let first = PermissionProbe.Request()
        let second = PermissionProbe.Request()
        XCTAssertNotEqual(first.token, second.token)
    }

    func testPermissionProbeEvaluateOnlyReportsRequestedFields() {
        // Accessibility not requested → result.accessibility is nil.
        // No automation targets → empty automation map. (Pure: doesn't touch TCC.)
        let result = PermissionProbe.evaluate(PermissionProbe.Request())
        XCTAssertNil(result.accessibility)
        XCTAssertTrue(result.automation.isEmpty)
    }

    // MARK: - DoctorReport

    func testDoctorReportAllClear() {
        let report = DoctorReport(checks: [
            .init(name: "A", status: .pass, detail: nil),
            .init(name: "B", status: .notApplicable, detail: "n/a"),
        ])
        XCTAssertTrue(report.allClear)
    }

    func testDoctorReportNotAllClear() {
        let report = DoctorReport(checks: [
            .init(name: "A", status: .pass, detail: nil),
            .init(name: "B", status: .fail, detail: "fix me"),
        ])
        XCTAssertFalse(report.allClear)

        let notDetermined = DoctorReport(checks: [
            .init(name: "A", status: .notDetermined, detail: "grant me"),
        ])
        XCTAssertFalse(notDetermined.allClear)
    }

    func testDoctorReportTextLinesShowsHintOnlyForFailures() {
        let report = DoctorReport(checks: [
            .init(name: "Pass", status: .pass, detail: "should not appear"),
            .init(name: "Fail", status: .fail, detail: "should appear"),
            .init(name: "NA", status: .notApplicable, detail: "should not appear"),
        ])
        let text = report.textLines().joined(separator: "\n")

        XCTAssertTrue(text.contains("✓"))
        XCTAssertTrue(text.contains("✗"))
        XCTAssertTrue(text.contains("should appear"))
        XCTAssertFalse(text.contains("should not appear"))
    }

    func testDoctorReportJSONEncodesStatusAndDetail() throws {
        let report = DoctorReport(checks: [
            .init(name: "Default browser", status: .fail, detail: "currently Chrome"),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        let json = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(json.contains("\"status\":\"fail\""))
        XCTAssertTrue(json.contains("\"detail\":\"currently Chrome\""))
        XCTAssertTrue(json.contains("\"name\":\"Default browser\""))
    }

    func testDoctorReportJSONOmitsNilDetail() throws {
        let report = DoctorReport(checks: [
            .init(name: "Accessibility", status: .pass, detail: nil),
        ])
        let data = try JSONEncoder().encode(report)
        let json = String(data: data, encoding: .utf8) ?? ""

        XCTAssertFalse(json.contains("detail"))
    }
}
