import AppKit
import ArgumentParser
import Foundation

// MARK: - Doctor engine

/// Builds the `DoctorReport` by running every requirement check. Shared by
/// `tabz doctor` (read-only) and `tabz setup` (which re-checks after acting).
///
/// `promptAutomation` controls whether the Automation check is allowed to fire
/// the one-time consent dialog — `doctor` passes false (silent), `setup` may
/// pass true while walking a step.
enum DoctorEngine {
    static func buildReport(configPath: String?, promptAutomation: Bool = false) -> DoctorReport {
        var checks: [DoctorReport.Check] = []

        // Accessibility
        let axOK = Permissions.accessibilityGranted()
        checks.append(.init(
            name: "Accessibility",
            status: axOK ? .pass : .notDetermined,
            detail: axOK ? nil : "needed to read the source window title for rule matching — run `tabz setup`"
        ))

        // Automation, per configured Chrome-family browser
        for bundleID in chromeBrowsers(configPath: configPath) {
            let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
            let name = "Automation → \(bundleID)"
            if !installed {
                checks.append(.init(name: name, status: .notApplicable, detail: "not installed"))
                continue
            }
            let state = Permissions.automationState(forTargetBundleID: bundleID, prompt: promptAutomation)
            switch state {
            case .granted:
                checks.append(.init(name: name, status: .pass, detail: nil))
            case .denied:
                checks.append(.init(
                    name: name, status: .fail,
                    detail: "previously denied — enable it in System Settings › Privacy & Security › Automation"
                ))
            case .notDetermined, .notApplicable:
                checks.append(.init(
                    name: name, status: .notDetermined,
                    detail: "not yet granted — run `tabz setup`"
                ))
            }
        }

        // Default browser
        let current = Permissions.defaultBrowserBundleID()
        let isDefault = isTabzillaDefaultBrowser(current)
        let defaultHint = "currently \(current ?? "unknown") — run `tabz setup` to make Tabzilla the default"
        checks.append(.init(
            name: "Default browser",
            status: isDefault ? .pass : .fail,
            detail: isDefault ? nil : defaultHint
        ))

        // Daemon running
        let pid = DaemonPID.get()
        let running = pid.map { DaemonPID.isRunning($0) } ?? false
        checks.append(.init(
            name: "Daemon running",
            status: running ? .pass : .fail,
            detail: running ? nil : "not running — launch Tabzilla.app (it runs in the background)"
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

        func run() throws {
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

            stepAccessibility()
            stepAutomation()
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
            if Permissions.accessibilityGranted() {
                print("✓ Accessibility — already granted.")
                return
            }
            print("→ Accessibility")
            print("  Tabzilla reads the title of the window you clicked a link in, so rules")
            print("  can match on it. Grant Accessibility to enable that.")
            print("")
            Permissions.promptAccessibility()
            Permissions.openSettings(Permissions.SettingsURL.accessibility)
            print("  Opened System Settings › Privacy & Security › Accessibility.")
            print("  Enable Tabzilla there (toggle it on), then press Enter to continue.")
            waitForEnter()
            if Permissions.accessibilityGranted() {
                print("  ✓ Accessibility granted.")
            } else {
                print("  ✗ Still not granted — you can finish this later; re-run `tabz setup`.")
            }
            print("")
        }

        private func stepAutomation() {
            let browsers = DoctorEngine.chromeBrowsers(configPath: config)
            for bundleID in browsers {
                guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
                    continue // not installed — nothing to grant
                }
                let state = Permissions.automationState(forTargetBundleID: bundleID, prompt: false)
                switch state {
                case .granted:
                    print("✓ Automation → \(bundleID) — already granted.")
                case .denied:
                    print("→ Automation → \(bundleID)")
                    print("  Previously denied. macOS won't re-show the prompt, so enable it manually:")
                    print("  System Settings › Privacy & Security › Automation › Tabzilla › \(bundleID).")
                    Permissions.openSettings(Permissions.SettingsURL.automation)
                    print("  Opened the Automation pane. Toggle it on, then press Enter.")
                    waitForEnter()
                case .notDetermined, .notApplicable:
                    print("→ Automation → \(bundleID)")
                    print("  Tabzilla drives \(bundleID) to place links in the right window/tab.")
                    print("  macOS will now ask for permission — click OK.")
                    print("")
                    // Triggering with prompt:true fires the one-time consent dialog.
                    let result = Permissions.automationState(forTargetBundleID: bundleID, prompt: true)
                    if result == .granted {
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

        private func waitForEnter() {
            _ = readLine()
        }
    }
}
