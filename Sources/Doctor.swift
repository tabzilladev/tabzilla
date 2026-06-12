import AppKit
import ArgumentParser
import Foundation

// MARK: - Permission probe client (CLI side)

/// CLI half of the daemon permission probe (daemon half lives in Permissions.swift).
/// Writes a request file, signals the daemon with SIGUSR1, and polls for the
/// token-matched response. Returns nil if the daemon isn't running or doesn't
/// answer within `timeout` — callers map that to an "unknown" status.
enum PermissionProbeClient {
    /// Quick read-only checks; the daemon answers near-instantly.
    static let readTimeout: TimeInterval = 3
    /// Interactive prompts: the daemon blocks on a system consent dialog while
    /// the user responds, so allow plenty of time.
    static let promptTimeout: TimeInterval = 180

    static func request(_ request: PermissionProbe.Request, timeout: TimeInterval) -> PermissionProbe.Result? {
        guard let pid = DaemonPID.get(), DaemonPID.isRunning(pid) else { return nil }

        let responsePath = PermissionProbe.responsePath(token: request.token)
        try? FileManager.default.removeItem(atPath: responsePath) // paranoia; token is unique

        try? FileManager.default.createDirectory(
            atPath: PermissionProbe.supportDir, withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(request),
              (try? data.write(to: URL(fileURLWithPath: PermissionProbe.requestPath))) != nil,
              kill(pid, SIGUSR1) == 0
        else {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let respData = FileManager.default.contents(atPath: responsePath),
               let result = try? JSONDecoder().decode(PermissionProbe.Result.self, from: respData),
               result.token == request.token
            {
                try? FileManager.default.removeItem(atPath: responsePath)
                return result
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }
}

// MARK: - Daemon control (CLI side)

/// Launching/locating the Tabzilla daemon from the CLI.
enum DaemonControl {
    static func isRunning() -> Bool {
        (DaemonPID.get().map { DaemonPID.isRunning($0) }) ?? false
    }

    /// Launch the daemon via Launch Services and wait (up to `timeout`) for it to
    /// write its PID file. Returns true once it's running.
    ///
    /// Critically, the daemon must be launched by Launch Services (`open`), NOT
    /// spawned as a child of this CLI process — a child would inherit the
    /// terminal's TCC responsible-process attribution, which is the exact bug the
    /// daemon probe exists to avoid. `open` makes launchd the parent, so the
    /// daemon carries Tabzilla's own TCC identity.
    @discardableResult
    static func ensureRunning(timeout: TimeInterval = 10) -> Bool {
        if isRunning() { return true }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: tabzillaBundleID) else {
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false

        let group = DispatchGroup()
        group.enter()
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in
            group.leave()
        }
        group.wait()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRunning() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return isRunning()
    }
}

// MARK: - Doctor engine

/// Builds the `DoctorReport`. Accessibility and Automation are evaluated by the
/// daemon (via `PermissionProbeClient`) because macOS attributes a CLI tool's TCC
/// requests to the launching terminal, not to Tabzilla — so checking them here
/// would report the terminal's grants. The default-browser, daemon, and config
/// checks don't go through TCC and are answered locally.
enum DoctorEngine {
    static func buildReport(configPath: String?) -> DoctorReport {
        var checks: [DoctorReport.Check] = []

        // Accessibility + Automation: evaluated by the daemon (correct TCC identity).
        checks.append(contentsOf: permissionChecks(configPath: configPath))

        // Default browser (Launch Services — not TCC, so local is correct)
        let current = Permissions.defaultBrowserBundleID()
        let isDefault = isTabzillaDefaultBrowser(current)
        let defaultHint = "currently \(current ?? "unknown") — run `tabz setup` to make Tabzilla the default"
        checks.append(.init(
            name: "Default browser",
            status: isDefault ? .pass : .fail,
            detail: isDefault ? nil : defaultHint
        ))

        // Daemon running
        let daemonRunning = (DaemonPID.get().map { DaemonPID.isRunning($0) }) ?? false
        checks.append(.init(
            name: "Daemon running",
            status: daemonRunning ? .pass : .fail,
            detail: daemonRunning ? nil : "not running — launch Tabzilla.app (it runs in the background)"
        ))

        // Config present
        let configFound = (configPath.map { ($0 as NSString).expandingTildeInPath })
            ?? ConfigurationManager.findConfigPath()
        let hasConfig = configFound != nil
        checks.append(.init(
            name: "Config present",
            status: hasConfig ? .pass : .notApplicable,
            detail: hasConfig ? nil : "no config file found — using built-in defaults (~/.config/tabz/config.yaml)"
        ))

        return DoctorReport(checks: checks)
    }

    /// The Accessibility + Automation checks, all evaluated by the daemon. When
    /// the daemon isn't running (or doesn't answer) these report `.unknown`
    /// rather than the misleading result a CLI-local TCC query would give.
    private static func permissionChecks(configPath: String?) -> [DoctorReport.Check] {
        var checks: [DoctorReport.Check] = []

        let browsers = chromeBrowsers(configPath: configPath)
        let installed = browsers.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }

        let daemonRunning = (DaemonPID.get().map { DaemonPID.isRunning($0) }) ?? false
        let probe: PermissionProbe.Result? = daemonRunning
            ? PermissionProbeClient.request(
                PermissionProbe.Request(checkAccessibility: true, automationTargets: installed),
                timeout: PermissionProbeClient.readTimeout
            )
            : nil
        let unknownHint = daemonRunning
            ? "daemon didn't respond — try again"
            : "can't check — start the daemon (launch Tabzilla.app), then re-run"

        // Accessibility (daemon-evaluated)
        switch probe?.accessibility {
        case .some(true):
            checks.append(.init(name: "Accessibility", status: .pass, detail: nil))
        case .some(false):
            checks.append(.init(
                name: "Accessibility", status: .notDetermined,
                detail: "needed to read the source window title for rule matching — run `tabz setup`"
            ))
        case .none:
            checks.append(.init(name: "Accessibility", status: .unknown, detail: unknownHint))
        }

        // Automation per configured Chrome-family browser (daemon-evaluated)
        for bundleID in browsers {
            let name = "Automation → \(bundleID)"
            if !installed.contains(bundleID) {
                checks.append(.init(name: name, status: .notApplicable, detail: "not installed"))
                continue
            }
            guard let probe else {
                checks.append(.init(name: name, status: .unknown, detail: unknownHint))
                continue
            }
            let (status, detail) = automationCheck(probe.automation[bundleID])
            checks.append(.init(name: name, status: status, detail: detail))
        }

        return checks
    }

    /// Map a probed Automation state to a doctor check status + hint.
    static func automationCheck(_ state: PermissionState?) -> (CheckStatus, String?) {
        switch state {
        case .granted:
            (.pass, nil)
        case .denied:
            (.fail, "previously denied — enable it in System Settings › Privacy & Security › Automation")
        case .notDetermined, .notApplicable, .none:
            (.notDetermined, "not yet granted — run `tabz setup`")
        }
    }

    /// Chrome-family browsers referenced by the config — the only ones that use
    /// Scripting Bridge / Apple Events and therefore need Automation permission.
    static func chromeBrowsers(configPath: String?) -> [String] {
        guard let config = try? ConfigurationManager.resolveConfig(from: configPath) else {
            return []
        }
        return browsersFromConfig(config).filter { isChromeBasedBrowser($0) }.sorted()
    }
}

// MARK: - Doctor Command

extension CLI {
    struct Doctor: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Check the status of every Tabzilla requirement (read-only)"
        )

        @Option(name: .shortAndLong, help: "Path to config file")
        var config: String?

        @Flag(name: .long, help: "Output as JSON")
        var json = false

        @Flag(name: .long, help: "Start the daemon first if needed (to check Accessibility/Automation)")
        var start = false

        func run() throws {
            // Accessibility/Automation can only be checked via the daemon. By
            // default we leave the world untouched and report `?` when it's down;
            // `--start` launches it (and leaves it running) for a complete read.
            if start {
                _ = DaemonControl.ensureRunning()
            }

            let report = DoctorEngine.buildReport(configPath: config)

            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(report)
                guard let string = String(data: data, encoding: .utf8) else {
                    throw ValidationError("Failed to encode report as UTF-8")
                }
                print(string)
                return
            }

            print("Tabzilla Doctor")
            print("───────────────")
            print("")
            for line in report.textLines() {
                print(line)
            }
            print("")
            if report.allClear {
                print("All checks passed. Tabzilla is ready.")
            } else {
                print("Some checks need attention. Run `tabz setup` for a guided walkthrough.")
            }
        }
    }
}

// MARK: - Setup Command

extension CLI {
    struct Setup: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Guided walkthrough to grant permissions and set Tabzilla as your default browser"
        )

        @Option(name: .shortAndLong, help: "Path to config file")
        var config: String?

        func run() throws {
            printIntro()

            // Accessibility and Automation must be granted to the daemon (its TCC
            // identity), and only the daemon can fire those prompts so they're
            // attributed to Tabzilla rather than this terminal. So make sure it's
            // running first — and leave it running, since that's the state the
            // user wants anyway (a stopped daemon doesn't route links).
            let daemonUp = DaemonControl.ensureRunning()
            if daemonUp {
                stepAccessibility()
                stepAutomation()
            } else {
                print("⚠ Couldn't start Tabzilla, so permission steps are skipped.")
                print("  Make sure Tabzilla.app is installed and you've cleared the Gatekeeper")
                print("  \"Open Anyway\" block (see above), then re-run `tabz setup`.")
                print("  Continuing with the default-browser step…")
                print("")
            }
            stepDefaultBrowser()

            // Final summary
            print("")
            print("Setup summary")
            print("─────────────")
            print("")
            let report = DoctorEngine.buildReport(configPath: config)
            for line in report.textLines() {
                print(line)
            }
            print("")
            if report.allClear {
                print("🎉 All set! Tabzilla is ready to route your links.")
            } else {
                print("Some items still need attention — re-run `tabz setup` after addressing them above.")
            }
            print("")
            print("Edit your routing rules at ~/.config/tabz/config.yaml, then run `tabz reload`.")
            print("Re-check anytime with `tabz doctor`.")
        }

        // MARK: Steps

        private func printIntro() {
            print("Tabzilla Setup")
            print("──────────────")
            print("")
            print("This walks through the permissions Tabzilla needs and makes it your")
            print("default browser. It's safe to re-run anytime — completed steps are skipped.")
            print("")
            print("Note: Tabzilla isn't code-signed yet, so on first launch macOS blocks it.")
            print("If you haven't already: System Settings › Privacy & Security › scroll to")
            print("Security › \"Open Anyway\" (you may need to try launching twice).")
            print("")
        }

        private func stepAccessibility() {
            if accessibilityGranted() == true {
                print("✓ Accessibility — already granted.")
                return
            }
            print("→ Accessibility")
            print("  Tabzilla reads the title of the window you clicked a link in, so rules")
            print("  can match on it. Grant Accessibility to enable that.")
            print("")
            // Ask the daemon to fire the prompt (so it's attributed to Tabzilla),
            // and also deep-link the pane.
            _ = PermissionProbeClient.request(
                PermissionProbe.Request(checkAccessibility: true, promptAccessibility: true),
                timeout: PermissionProbeClient.readTimeout
            )
            Permissions.openSettings(Permissions.SettingsURL.accessibility)
            print("  Opened System Settings › Privacy & Security › Accessibility.")
            print("  Enable Tabzilla there (toggle it on), then press Enter to continue.")
            waitForEnter()
            switch accessibilityGranted() {
            case .some(true): print("  ✓ Accessibility granted.")
            default: print("  ✗ Still not granted — you can finish this later; re-run `tabz setup`.")
            }
            print("")
        }

        private func stepAutomation() {
            let browsers = DoctorEngine.chromeBrowsers(configPath: config)
            for bundleID in browsers {
                guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
                    continue // not installed — nothing to grant
                }
                switch automationState(for: bundleID) {
                case .granted:
                    print("✓ Automation → \(bundleID) — already granted.")
                case .denied:
                    print("→ Automation → \(bundleID)")
                    print("  Previously denied. macOS won't re-show the prompt, so enable it manually:")
                    print("  System Settings › Privacy & Security › Automation › Tabzilla › \(bundleID).")
                    Permissions.openSettings(Permissions.SettingsURL.automation)
                    print("  Opened the Automation pane. Toggle it on, then press Enter.")
                    waitForEnter()
                case .notDetermined, .notApplicable, nil:
                    print("→ Automation → \(bundleID)")
                    print("  Tabzilla drives \(bundleID) to place links in the right window/tab.")
                    print("  macOS will now ask for permission — click OK.")
                    print("")
                    // Daemon fires the consent dialog and blocks until the user
                    // responds, so poll with the long timeout.
                    let result = PermissionProbeClient.request(
                        PermissionProbe.Request(automationTargets: [bundleID], promptAutomation: true),
                        timeout: PermissionProbeClient.promptTimeout
                    )
                    if result?.automation[bundleID] == .granted {
                        print("  ✓ Automation granted for \(bundleID).")
                    } else {
                        Permissions.openSettings(Permissions.SettingsURL.automation)
                        print("  If you didn't see a dialog (or declined), enable it in the Automation")
                        print("  pane that just opened, then press Enter.")
                        waitForEnter()
                    }
                }
                print("")
            }
        }

        private func stepDefaultBrowser() {
            if isTabzillaDefaultBrowser(Permissions.defaultBrowserBundleID()) {
                print("✓ Default browser — already Tabzilla.")
                print("")
                return
            }
            print("→ Default browser")
            print("  Last step: make Tabzilla your default browser so links route through it.")
            print("  macOS will ask you to confirm — choose \"Use Tabzilla\".")
            print("")
            // Synchronous: blocks on the system consent dialog, so the state is
            // settled by the time it returns and we can re-check immediately.
            // (Launch Services, not TCC, so this works correctly from the CLI.)
            Permissions.setDefaultBrowserToTabzilla()
            if isTabzillaDefaultBrowser(Permissions.defaultBrowserBundleID()) {
                print("  ✓ Tabzilla is now your default browser.")
            } else {
                print("  ✗ Not set (you may have declined). To do it manually:")
                print("  System Settings › Desktop & Dock › Default web browser › Tabzilla.")
                Permissions.openSettings(Permissions.SettingsURL.desktopAndDock)
            }
            print("")
        }

        // MARK: Probe helpers (daemon-evaluated)

        /// Daemon's Accessibility view; nil if the daemon didn't answer.
        private func accessibilityGranted() -> Bool? {
            PermissionProbeClient.request(
                PermissionProbe.Request(checkAccessibility: true),
                timeout: PermissionProbeClient.readTimeout
            )?.accessibility
        }

        /// Daemon's Automation view for one browser; nil if it didn't answer.
        private func automationState(for bundleID: String) -> PermissionState? {
            PermissionProbeClient.request(
                PermissionProbe.Request(automationTargets: [bundleID]),
                timeout: PermissionProbeClient.readTimeout
            )?.automation[bundleID]
        }

        private func waitForEnter() {
            _ = readLine()
        }
    }
}
