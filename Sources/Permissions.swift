import AppKit
import ApplicationServices
import CoreServices
import Foundation

/// Tabzilla's own bundle identifier — the identity that TCC permission grants
/// (Accessibility, Automation) and the Launch Services default-browser binding
/// are all keyed to. The CLI runs the same binary as the daemon, so grants
/// attributed to the app bundle apply to `tabz` invocations too.
let tabzillaBundleID = "dev.tabzilla.Tabzilla"

// MARK: - Status types

/// Tri-state (plus N/A) for a TCC permission. `notDetermined` distinguishes
/// "never asked" (the system consent dialog can still be triggered) from
/// `denied` (the user must toggle it manually — the dialog won't re-show).
enum PermissionState: String, Codable {
    case granted
    case denied
    case notDetermined
    case notApplicable
}

/// Display status for a single `doctor` check.
enum CheckStatus: String, Encodable {
    case pass // ✓
    case fail // ✗ — action required
    case notDetermined // ✗ — not yet granted, prompt available
    case unknown // ? — couldn't be determined (e.g. daemon not running)
    case notApplicable // —

    var symbol: String {
        switch self {
        case .pass: "✓"
        case .fail, .notDetermined: "✗"
        case .unknown: "?"
        case .notApplicable: "—"
        }
    }

    /// Whether `setup` should act on this check.
    var needsAttention: Bool {
        self == .fail || self == .notDetermined
    }
}

// MARK: - Permission queries & actions

enum Permissions {
    // MARK: Accessibility

    /// Whether Accessibility (AX) is granted — no prompt.
    static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Fire the system Accessibility prompt. This adds Tabzilla to the
    /// Accessibility list (unchecked) and surfaces the consent dialog.
    /// Returns the current trust state (almost always false on first call).
    @discardableResult
    static func promptAccessibility() -> Bool {
        // Key value is that of `kAXTrustedCheckOptionPrompt`; using the literal
        // sidesteps the Unmanaged<CFString>-vs-CFString SDK ambiguity.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Automation (Apple Events)

    /// Automation permission for sending Apple Events to `targetBundleID`.
    /// When `prompt` is true the one-time consent dialog is shown on first ask
    /// (and the call blocks until the user responds). Once denied, the dialog
    /// never re-shows — the result is `.denied` and the user must toggle it
    /// manually in System Settings.
    static func automationState(forTargetBundleID targetBundleID: String, prompt: Bool) -> PermissionState {
        var target = AEAddressDesc()
        let bytes = Array(targetBundleID.utf8)
        let createStatus = bytes.withUnsafeBytes { buf in
            AECreateDesc(typeApplicationBundleID, buf.baseAddress, buf.count, &target)
        }
        guard createStatus == noErr else { return .notDetermined }
        defer { AEDisposeDesc(&target) }

        let err = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, prompt)
        switch err {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            // Only returned when prompt == false: consent has never been asked.
            return .notDetermined
        default:
            // procNotFound (target not running) and anything else: indeterminate.
            return .notDetermined
        }
    }

    // MARK: Default browser

    /// Bundle ID of the current default handler for http(s) URLs, if known.
    /// Uses the non-deprecated NSWorkspace reader.
    static func defaultBrowserBundleID() -> String? {
        guard let probe = URL(string: "https://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe),
              let bundle = Bundle(url: appURL)
        else {
            return nil
        }
        return bundle.bundleIdentifier
    }

    /// Set Tabzilla as the default handler for http (which reassigns the whole
    /// browser role, so https follows). macOS shows its own consent dialog;
    /// on accept this returns true and the change sticks, on decline it's a
    /// no-op. No dialog appears if Tabzilla is already the handler.
    @discardableResult
    static func setDefaultBrowserToTabzilla() -> Bool {
        // LSSetDefaultHandlerForURLScheme is deprecated but verified to work
        // from a (non-frontmost) CLI process with the standard consent dialog.
        let status = LSSetDefaultHandlerForURLScheme("http" as CFString, tabzillaBundleID as CFString)
        return status == noErr
    }

    // MARK: System Settings deep links

    /// `x-apple.systempreferences:` URLs for the relevant panes. Undocumented
    /// and drift across macOS versions — best-effort; always print the click
    /// path alongside. Pinned to panes verified on the Ventura support floor.
    enum SettingsURL {
        static let accessibility =
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        static let automation =
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        /// Default browser lives under Desktop & Dock on Ventura+; no reliable
        /// anchor for the dropdown itself, so open the pane and let the user scroll.
        static let desktopAndDock =
            "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
    }

    /// Open a System Settings pane by its `x-apple.systempreferences:` URL.
    static func openSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Pure comparison: does `bundleID` identify Tabzilla as the default browser?
func isTabzillaDefaultBrowser(_ bundleID: String?) -> Bool {
    bundleID == tabzillaBundleID
}

// MARK: - Permission probe (cross-process)

/// macOS attributes a CLI tool's TCC requests (Accessibility, Automation) to its
/// *responsible* process — the terminal it was launched from — not to the tool's
/// own code identity. So `AXIsProcessTrusted()` / `AEDeterminePermissionToAutomateTarget`
/// called from `tabz` report the *terminal's* grants, not Tabzilla's, and a dev
/// terminal that already has them makes every check a false positive.
///
/// To get the truth we must evaluate inside the daemon, which Launch Services
/// launched as itself and which therefore carries Tabzilla's real TCC identity.
/// This is a tiny file + SIGUSR1 request/response channel: the CLI writes a
/// request, signals the daemon, and polls for a token-matched response. The
/// daemon-side evaluation lives here (it's the same target as the daemon); the
/// CLI-side client lives in Doctor.swift (it needs DaemonPID).
enum PermissionProbe {
    /// What the CLI is asking the daemon to evaluate. A `prompt` flag may ask the
    /// daemon to fire the relevant system consent dialog (used by `tabz setup`).
    struct Request: Codable {
        /// Unique per request; echoed in the response and used in its filename so
        /// the CLI never reads a stale response from an earlier call.
        let token: String
        let checkAccessibility: Bool
        let promptAccessibility: Bool
        /// Browser bundle IDs to check Automation permission for.
        let automationTargets: [String]
        let promptAutomation: Bool

        init(
            token: String = UUID().uuidString,
            checkAccessibility: Bool = false,
            promptAccessibility: Bool = false,
            automationTargets: [String] = [],
            promptAutomation: Bool = false
        ) {
            self.token = token
            self.checkAccessibility = checkAccessibility
            self.promptAccessibility = promptAccessibility
            self.automationTargets = automationTargets
            self.promptAutomation = promptAutomation
        }
    }

    /// The daemon's answer, carrying its own (correct) TCC view.
    struct Result: Codable {
        let token: String
        /// nil when the request didn't ask about Accessibility.
        let accessibility: Bool?
        /// Automation state keyed by target bundle ID.
        let automation: [String: PermissionState]
    }

    // MARK: File locations

    /// Same directory as the PID file (`~/Library/Application Support/Tabzilla`).
    /// Kept independent of DaemonPID so this stays in the SPM-built target.
    static var supportDir: String {
        guard let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            return NSString("~/Library/Application Support/Tabzilla").expandingTildeInPath
        }
        return dir.appendingPathComponent("Tabzilla").path
    }

    static var requestPath: String {
        (supportDir as NSString).appendingPathComponent("probe-request.json")
    }

    static func responsePath(token: String) -> String {
        (supportDir as NSString).appendingPathComponent("probe-response-\(token).json")
    }

    // MARK: Daemon side

    /// Evaluate a request using *this process's* TCC identity. Meaningful only
    /// when run inside the daemon. May block briefly on a system consent dialog
    /// when a `prompt` flag is set.
    static func evaluate(_ request: Request) -> Result {
        var accessibility: Bool?
        if request.checkAccessibility {
            accessibility = request.promptAccessibility
                ? Permissions.promptAccessibility()
                : Permissions.accessibilityGranted()
        }

        var automation: [String: PermissionState] = [:]
        for target in request.automationTargets {
            automation[target] = Permissions.automationState(
                forTargetBundleID: target, prompt: request.promptAutomation
            )
        }

        return Result(token: request.token, accessibility: accessibility, automation: automation)
    }

    /// Daemon-side handler for SIGUSR1: read the request file, evaluate it, and
    /// write the token-matched response. Best-effort — any failure is silent
    /// (the CLI times out and reports `unknown`).
    static func serviceRequest() {
        guard let data = FileManager.default.contents(atPath: requestPath),
              let request = try? JSONDecoder().decode(Request.self, from: data)
        else {
            return
        }
        // Consume the request so a later stray signal doesn't re-run it.
        try? FileManager.default.removeItem(atPath: requestPath)

        let result = evaluate(request)
        guard let out = try? JSONEncoder().encode(result) else { return }
        try? out.write(to: URL(fileURLWithPath: responsePath(token: request.token)))
    }
}

// MARK: - Doctor report

/// The result of the `doctor` checks, suitable for both text and JSON output.
/// Built by the CLI (which calls the system queries above); the model and its
/// rendering are kept pure so they can be unit-tested.
struct DoctorReport: Encodable {
    struct Check: Encodable {
        let name: String
        let status: CheckStatus
        /// One-line hint shown when the check is not passing.
        let detail: String?
    }

    let checks: [Check]

    /// True when every check is satisfied (or not applicable).
    var allClear: Bool {
        checks.allSatisfy { $0.status == .pass || $0.status == .notApplicable }
    }

    /// Render as aligned `<symbol> <name>` lines with indented hints on failure.
    func textLines() -> [String] {
        let width = checks.map(\.name.count).max() ?? 0
        var lines: [String] = []
        for check in checks {
            let padded = check.name.padding(toLength: width, withPad: " ", startingAt: 0)
            lines.append("\(check.status.symbol)  \(padded)")
            if check.status != .pass, check.status != .notApplicable, let detail = check.detail {
                lines.append("   \(String(repeating: " ", count: width))  ↳ \(detail)")
            }
        }
        return lines
    }
}
