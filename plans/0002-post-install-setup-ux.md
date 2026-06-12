# Plan: Friendlier Post-Install Setup (CLI-driven walkthrough)

Status: Implemented (PR #5)
Date: 2026-06-12

> **Implementation correction (2026-06-12):** risk/assumption #4 below was **wrong**.
> macOS attributes a CLI tool's TCC requests to its *responsible process* — the
> launching terminal — not to the tool's own code identity, so AX/Automation
> checks run from `tabz` report the *terminal's* grants (a false positive on any
> dev machine where the terminal already has them). The Accessibility and
> Automation checks were therefore moved **into the daemon** (which Launch
> Services runs as itself, carrying Tabzilla's real TCC identity), reached over a
> file + `SIGUSR1` request/response probe (`PermissionProbe` /
> `PermissionProbeClient`). When the daemon isn't running those checks report
> `?` *unknown* rather than guessing. Default-browser / daemon / config checks
> stay CLI-local (they don't go through TCC). See the updated #4 below.

## Problem

After `brew install --cask tabzilladev/tap/tabzilla`, a new user faces a long, mostly
undiscoverable sequence before Tabzilla does anything useful. Today nothing guides them.

The current manual journey:

1. **Gatekeeper (unsigned app).** First launch is *blocked* with no "Open anyway" button.
   User must go to System Settings → Privacy & Security → Security → scroll → find the
   blocked-app notice → "Open Anyway". A *second* launch attempt then shows a dialog that
   finally has an "Open Anyway" button. (Can't be removed without code signing, which is
   out of scope for now.)
2. **Accessibility permission.** Tabzilla reads the frontmost window title of the source
   app (`getSourceWindowTitle` in `TabzillaApp.swift:265`) via the AX API. Requires
   System Settings → Privacy & Security → Accessibility → add + enable Tabzilla. Today the
   app never checks or prompts — it just silently returns `nil` and routing rules that
   depend on `sourceWindowTitle` quietly don't match.
3. **Automation permission (per target browser).** Tabzilla drives Chrome / Chrome Beta
   via Scripting Bridge Apple Events (`ChromeController.m`). macOS gates this behind the
   Automation list, per (controller app → target app) pair. Today the app doesn't detect
   denial — Scripting Bridge calls silently fail or throw.
4. **Default web browser.** User must set Tabzilla in System Settings → Desktop & Dock →
   Default web browser. Not automatic (and shouldn't be — see [[0001-chrome-profile-and-instance-targeting]] context: Tabzilla is a router, not a hijacker).

That's 4 distinct system-settings excursions, most with no in-app guidance.

## Constraint & key decision

**The walkthrough is delivered through the CLI, not a GUI.** Tabzilla is a pure
`.accessory` daemon today (`TabzillaApp.swift:62`, `LSUIElement` in Info.plist) — no
window, no menu-bar item. Building onboarding GUI would mean introducing a whole UI layer.
Instead we lean on the already-installed `tabz` command (symlinked to PATH by the cask's
`binary` stanza) and the existing ArgumentParser subcommand pattern
(`CLI.swift:15`).

The Homebrew cask `caveats` stanza is the one piece of "automatic" surface we get — it
prints after install and points the user at `tabz setup`.

## Goals

- One command — `tabz setup` — that walks the user through every step in order, checks
  current state, explains *why* each permission is needed, and opens the exact System
  Settings pane for them.
- A non-interactive `tabz doctor` that reports the status of every requirement (for
  re-checking, support, and scripting).
- Cask `caveats` that surface the unsigned-app gotcha and tell the user to run `tabz setup`.
- Zero new GUI; no new daemon/login-agent requirement.

## Non-goals

- Code signing / notarization (would remove step 1 entirely, but out of scope for now).
- Programmatically forcing the default browser (macOS requires user consent via its own
  dialog; we can *trigger* that dialog but not bypass it).
- A login LaunchAgent (separate concern; note it as a future item).

---

## Design

### Component 1 — `tabz doctor` (status check, read-only)

A new subcommand that inspects each requirement and prints a status line. Pure
read-only; safe to run anytime. Also the engine `tabz setup` reuses.

Checks:

| Check | How | Source reference |
|-------|-----|------------------|
| Accessibility granted | `AXIsProcessTrusted()` (no-prompt variant), **evaluated in the daemon** via the probe | `Permissions.swift`; AX also used at `TabzillaApp.swift` |
| Automation → Chrome | `AEDeterminePermissionToAutomateTarget(...)` with the Chrome bundle id, `askUserIfNeeded=false`, **evaluated in the daemon** | `Permissions.swift`; SB calls in `ChromeController.m` |
| Automation → Chrome Beta | same, `com.google.Chrome.beta` | " |
| Default browser is Tabzilla | `NSWorkspace.urlForApplication(toOpen:)` (non-deprecated) compared to `dev.tabzilla.Tabzilla` — CLI-local, not TCC | `Permissions.swift` |
| Daemon running | existing PID check | `CLI.Status` / `DaemonPID` |
| Config present | existing config search | `ConfigurationManager.findConfigPath()` |

The AX and Automation rows are **probed from the daemon** (see the correction note
at the top) — the CLI can't evaluate them truthfully itself. If the daemon isn't
running they report `?` *unknown*.

Output format: one line per check, `✓ / ✗ / ? / —`, with a one-line hint on
failure or unknown. Support `--json` (mirrors `tabz dump` style) for scripting and
bug reports.

Which browsers to check for Automation: derive from config (`browsersFromConfig`,
extracted from `CLI.Dump` into `Config.swift` so it's shared and SPM-testable) so
it covers whatever the user actually routes to, not a hardcoded list.

### Component 2 — `tabz setup` (interactive walkthrough)

Runs the `doctor` checks in dependency order; for each *failing* one, explains it and
performs the smallest helpful action, then waits for the user to confirm before
re-checking. Idempotent — re-running skips satisfied steps.

Per-step behavior:

1. **Accessibility**
   - If missing: explain ("Tabzilla reads the title of the window you clicked a link in,
     so rules can match on it"), then call
     `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` to fire the
     system prompt, AND `open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"`
     to deep-link the pane. Wait for Enter, re-check.

2. **Automation (per configured Chrome-family browser)**
   - If missing: explain, then *trigger the prompt by attempting a benign Scripting Bridge
     call* (the only way macOS shows the Automation consent dialog is an actual AE attempt;
     `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded=true` is the clean
     trigger). Deep-link `...?Privacy_Automation`. Wait, re-check.
   - Note: if previously denied, the prompt won't re-show; instruct the user to toggle it
     in the pane. `doctor` distinguishes "not yet asked" vs "denied".

3. **Default browser**
   - If not Tabzilla: explain it's the last step, then call
     `LSSetDefaultHandlerForURLScheme("http", "dev.tabzilla.Tabzilla")`. macOS shows its
     own consent dialog ("Use Tabzilla" / "Keep Using <current>") — user-consented, can't
     bypass, which is the desired behavior. **Verified working from a CLI process**
     (2026-06-12): on accept the call returns `OSStatus == 0` and the change sticks; on
     decline it's a no-op (earlier `-54`/`permErr` was simply a declined dialog, not an
     API limitation). Setting the `http` handler reassigns the whole browser role, so
     `https` follows automatically — one call suffices. No pop-up appears if Tabzilla is
     already the handler (nothing to confirm), so the step is naturally idempotent.
     `NSWorkspace.setDefaultApplicationToOpen(...URLsWithScheme:)` is the modern
     equivalent if a non-deprecated API is preferred. Re-check after; if still not
     Tabzilla, the user declined — explain and offer to retry or deep-link Desktop & Dock.
   - **Sequencing:** the dialog can only name Tabzilla once it's registered with Launch
     Services (installed + launched past Gatekeeper at least once). Run this step last,
     after the app has been launched.

4. **Summary** — print final `doctor` table; celebrate when all green; remind how to edit
   config (`~/.config/tabz/config.yaml`) and re-run `tabz setup` anytime.

Gatekeeper (step 1 in the Problem) can't be scripted away, but `setup` should *detect*
whether it's even running with the needed TCC access and, in its intro text, mention the
unsigned-app "Open Anyway" path so a confused user has a pointer.

### Component 3 — Homebrew cask `caveats`

Add a `caveats` stanza to `Casks/tabzilla.rb` (in `tabzilladev/homebrew-tap`). It prints
after install:

```ruby
caveats <<~EOS
  Tabzilla is not yet code-signed. On first launch macOS will block it:
    System Settings → Privacy & Security → scroll to Security → "Open Anyway"
    (you may need to try launching twice).

  Then finish setup — this checks permissions and sets Tabzilla as your
  default browser:
    tabz setup

  Re-check anytime with:
    tabz doctor
EOS
```

This is the only "push" surface post-install; everything else is pull (`tabz setup`).

### Component 4 — App-side nudge (optional, smaller)

When the daemon handles a URL but a required permission is missing (e.g. Accessibility
denied so `getSourceWindowTitle` returned nil, or an Automation AE failed), log a clear,
actionable line via `os_log` (e.g. "Accessibility not granted — run `tabz setup`"). Cheap,
and it converts silent failures (today's behavior) into discoverable ones. No UI needed.

### Component 5 — Teardown: clean uninstall via cask `zap`

The mirror of setup. macOS persists state *outside* the app bundle, keyed by bundle id,
so a plain uninstall leaves it behind — and reinstalling the same bundle id silently
re-adopts it. Observed directly: after deleting the app, Accessibility/Automation grants
and the default-browser binding all "reappeared" on reinstall with no user action.

**Where the state lives** (verified on macOS, `dev.tabzilla.Tabzilla`):

| State | Location | Cleared by |
|-------|----------|------------|
| Default http/https handler ("default browser") + URL-scheme capability | `~/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist` | `lsregister -kill -r` **full rebuild** (after app removal); macOS then self-heals the default to another installed browser |
| Accessibility grant | TCC DB (`kTCCServiceAccessibility`) | `tccutil reset Accessibility dev.tabzilla.Tabzilla` |
| Automation grant | TCC DB (`kTCCServiceAppleEvents`) | `tccutil reset AppleEvents dev.tabzilla.Tabzilla` |
| Gatekeeper "Open Anyway" approval | code-identity keyed (not a per-app file) | not cleanly resettable; a fresh `brew install` re-quarantines and re-triggers it |

**Two findings that shaped `make uninstall` (already implemented) and apply to `zap`:**

1. **`lsregister -u` is insufficient** — it removes the app's *capability* registration
   but NOT the persisted default-browser *choice* in `LSHandlers`. Only a full
   `lsregister -kill -r -domain local -domain user -domain system` rebuild drops the stale
   binding. This is why the earlier `-u`-based attempt let the default "reappear" on
   reinstall.
2. **Teardown doesn't need to reassign the default handler.** Once the bundle is gone and
   LS is rebuilt, macOS self-heals the default to a real browser — so `make uninstall`
   relies on that, not on setting a handler. (Note: `LSSetDefaultHandlerForURLScheme`
   *does* work from a CLI — see Component 2 step 3 — but it requires the user-consent
   dialog, which is appropriate for `setup` but pointless for teardown.)
3. **Ordering:** the app bundle must be removed *before* the LS rebuild, or lsregister
   re-asserts Tabzilla.

**Dev-loop tool (done):** folded into `make uninstall` — it removes the app, rebuilds LS,
and runs both `tccutil reset`s in one step (a separate `reset-state` target was
unnecessary: `make install` already removes the old bundle itself, so the fast reinstall
loop never needs a standalone reset, and `uninstall` is the only place a full wipe is
wanted). Doing it in one target also removes the cross-target ordering footgun.

**End-user surface:** extend the cask `zap` stanza so `brew uninstall --zap --cask tabzilla`
fully cleans up. Today `zap` only does `trash:` (config files). Add the system-state resets
via `zap`'s script hooks:

```ruby
zap trash: [
       "~/.config/tabz",
       "~/.tabz.yaml",
     ],
     # Homebrew removes the app bundle before running these.
     # (Confirm exact zap script DSL — quoted args/lists — when implementing.)
```

Open question for implementation: `zap` supports `trash:` and `delete:`/`rmdir:` cleanly,
but running arbitrary commands (`tccutil`, `lsregister`) needs the `signal:`/script form or
a `uninstall ... :script` hook — confirm the supported DSL and that it runs *after* bundle
removal. If `zap` can't run commands portably, fall back to documenting the `make uninstall`
equivalents in the README for users who want a full wipe. Keep this out of `tabz uninstall`
(don't add one) — `brew uninstall --zap` is the conventional, non-racing path
(see [[0001-chrome-profile-and-instance-targeting]] note on letting Homebrew own removal).

---

## Affected files

| File | Change |
|------|--------|
| `Sources/CLI.swift` | Register `Doctor` + `Setup` subcommands in `subcommands:`. `browsersFromConfig` moved out to `Config.swift`. |
| `Sources/Doctor.swift` (new) | `DoctorEngine` (builds the report; AX/Automation via the daemon probe), `tabz doctor` + `tabz setup` commands, and the CLI-side `PermissionProbeClient` (writes request, sends `SIGUSR1`, polls for the response). SPM-excluded (depends on `DaemonPID`). |
| `Sources/Permissions.swift` (new) | Wrap AX (`AXIsProcessTrusted[WithOptions]`), Automation (`AEDeterminePermissionToAutomateTarget`), default-browser read (`NSWorkspace.urlForApplication(toOpen:)`) + set (`LSSetDefaultHandlerForURLScheme`, verified from CLI w/ consent dialog) + System-Settings deep-link URLs. Also the `PermissionProbe` types + daemon-side `evaluate()`/`serviceRequest()` and the pure `DoctorReport` model. Unit-tested. |
| `Sources/TabzillaApp.swift` | Handle `SIGUSR1` → `PermissionProbe.serviceRequest()` (daemon evaluates AX/Automation with its own TCC identity). (Component 4) On AX/AE failure, emit an actionable `os_log` hint, around `getSourceWindowTitle` and the Executor error paths. |
| `Casks/tabzilla.rb` (tap repo) | Add `caveats` stanza (Component 3); extend `zap` to reset TCC + rebuild Launch Services (Component 5). Separate repo `tabzilladev/homebrew-tap`. |
| `Makefile` | `uninstall` stops the daemon first, then removes the app, rebuilds Launch Services, and requests TCC resets (Component 5 dev-loop tool) — **done**. Honest "reset requested" wording since adhoc-signed grants may survive (#5). |
| `README.md` / `DEVELOPMENT.md` | Replace the manual "set as default browser" steps with `tabz setup`; document `tabz doctor`; document full-wipe uninstall (`brew uninstall --zap`, or `make uninstall` for devs). |

## Testing

- Unit: `doctor`'s default-browser comparison and JSON output (pure logic).
- Manual matrix (the permission APIs can't be unit-tested): fresh user / each permission
  individually denied / all granted → `tabz doctor` reports correctly; `tabz setup`
  advances and is idempotent on re-run.
- Cask: `brew style` after adding `caveats`; verify the text prints on install once the
  repo is public (the asset URL 404s while private — see [[release-private-repo-blocker]]).
- Automation prompt nuance: verify behavior in both "never asked" and "previously denied"
  states (the consent dialog only appears the first time).

## Open questions / risks

1. **Automation prompt is one-shot.** macOS only shows the consent dialog on the first AE
   attempt; once denied, only a manual toggle works. `setup` must detect this and give
   manual instructions rather than spinning. Mitigated by `AEDeterminePermissionToAutomateTarget`
   returning a distinct "denied" vs "not determined" status.
2. ~~**Default-browser API may itself prompt or require the app be frontmost.**~~
   **Resolved 2026-06-12 by manual test:** `LSSetDefaultHandlerForURLScheme` works from a
   non-frontmost CLI process — it triggers the system consent dialog and, on accept,
   returns `OSStatus == 0` and the change sticks (round-tripped Chrome↔Safari). The only
   precondition is that Tabzilla be LS-registered so the dialog can name it (handled by
   the step-3 sequencing note). Deep-link to Desktop & Dock remains the fallback if the
   user declines.
3. **Deep-link URLs are undocumented** (`x-apple.systempreferences:...`) and have drifted
   across macOS versions. Pin to the panes verified on the supported floor (Ventura, per
   the cask `depends_on macos: :ventura`) and treat them as best-effort (always also print
   the click-path in text).
4. ~~**CLI invokes from `tabz` symlink** → grants attributed to the app bundle are seen by
   the CLI invocation (same identity).~~ **FALSE — disproven 2026-06-12.** macOS attributes
   a CLI tool's TCC requests to its *responsible process* (the launching terminal), not to
   the tool's own code identity, even though it's the same binary as the daemon. A brand-new
   never-granted binary reports `AXIsProcessTrusted() == true` when run from a terminal that
   has the grant. **Resolution:** AX/Automation are evaluated **in the daemon** (Launch
   Services runs it as itself → real Tabzilla TCC identity) via a file + `SIGUSR1` probe
   (`PermissionProbe`), and report `?` *unknown* when the daemon is down. This is the single
   biggest deviation from the original design.
5. **Unsigned + TCC.** The app is adhoc-signed, so TCC grants aren't reliably keyed to the
   bundle id: `tccutil reset <bundle-id>` often clears nothing and grants survive
   reinstall, and rebuilding can invalidate prior grants. `make uninstall` / the cask `zap`
   say "reset requested" (not "reset") and point users at `tabz doctor` + manual removal in
   System Settings. Code signing is the real fix (a non-goal here).

## Recommended sequencing

1. **`tabz doctor`** first — read-only, immediately useful, and it's the engine `setup`
   reuses. (Note: running it from a terminal does **not** cheaply validate the TCC-identity
   assumption #4 — it gives a false positive; only an installed-daemon test against a
   fresh-granted state reveals the truth. See #4.)
2. **Cask `caveats`** — trivial, high-leverage; can ship as soon as `doctor`/`setup` names
   are settled (even before they're fully built, pointing at `tabz doctor`).
3. **`tabz setup`** — the guided flow, built on `doctor`'s checks.
4. **App-side `os_log` nudges** (Component 4) — small, do alongside or after.
5. Docs last.
