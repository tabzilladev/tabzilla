# Plan: Detecting & Targeting Specific Chrome Profiles / user-data-dir Instances

Status: Workstream A implemented & verified. B/C/D outstanding.
Date: 2026-06-09 (updated 2026-06-12)

## Progress

- **2026-06-12 — Spike validated the core assumption.** `SBApplication
  applicationWithProcessIdentifier:` *does* deliver Apple Events to the chosen instance
  when two processes share a bundle id; each PID returned only its own windows. The
  open question that gated Workstream A is resolved — A' (Beta-channel) is no longer a
  correctness requirement, only an optional convenience. The spike also revealed that
  `applicationWithBundleIdentifier:` resolution is **nondeterministic across launches**
  (not reliably wrong), which explains the intermittent symptom. Spike had to be written
  in **Objective-C**: `SBApplication` resolves accessors by dynamic Apple Event dispatch,
  so Swift KVC (`valueForKey:`) throws `NSUnknownKeyException` — hence the locator lives
  in the ObjC layer.
- **2026-06-12 — Workstream A implemented.** `Sources/ChromeProcessLocator.{h,m}` added
  (discovery via `KERN_PROCARGS2` split from a pure `selectInstanceFrom:` policy);
  `ChromeController.chromeAppForBundleId:` now resolves a PID and falls back to bundle-id
  targeting when ambiguous. Wired into the Xcode build + `Package.swift` SPM exclusions.
  Verified live: with both the real Chrome (86321, no flag) and a Playwright instance
  (`--user-data-dir=/tmp/poc-chrome-profile`) running, `make dump` now reports the real
  Chrome's 20 windows instead of the POC's single window. `make build`/`lint`/`format-check`
  all green.

## Problem

Tabzilla routes to "Chrome" purely by **bundle id** (`com.google.Chrome`). This breaks
in two distinct situations:

1. **Multiple Chrome *instances* sharing one bundle id.** When a second Chrome process is
   launched with its own `--user-data-dir` (e.g. Playwright/chromedriver dev-testing:
   `--user-data-dir=/tmp/poc-chrome-profile --remote-debugging-port=9222`), there are now
   two `com.google.Chrome` processes. ScriptingBridge / Apple Events can only address
   **one process per bundle id**, and macOS routes events to whichever the OS picks —
   often the automation instance. Symptom observed: `make dump` shows only the Playwright
   profile's windows and never the real Chrome; new tabs open in the wrong instance.

2. **Multiple *profiles* within one user-data-dir.** Chrome's profile picker lets one
   user-data-dir hold `Default`, `Profile 1`, … Chrome's AppleScript dictionary exposes
   **no profile property** on the application or windows (verified in `Sources/Chrome.h`:
   windows have `givenName`, `mode`, `bounds`, … but nothing profile-related). New
   ScriptingBridge windows/tabs land in whatever profile is currently focused. The only
   way to *pin* a profile is the launch flag `--profile-directory=<DIR>` (directory name
   like `Default` / `Profile 1`, **not** the display name).

These are different problems with different fixes. `--profile-directory` solves (2) but
does **nothing** for (1), because the colliding instances have different user-data-dirs.

### Concrete environment (for reference)

Running processes seen during investigation:

| PID   | What            | user-data-dir                          |
|-------|-----------------|----------------------------------------|
| 2854  | Real Chrome     | default (`~/Library/.../Google/Chrome`)|
| 35188 | Playwright/POC  | `--user-data-dir=/tmp/poc-chrome-profile` (`--remote-debugging-port=9222`) |

Profiles on disk:

| Bundle               | Dir         | Display name              |
|----------------------|-------------|---------------------------|
| `com.google.Chrome`  | `Default`   | brian.dupras@airbnb.com   |
| `Chrome Beta`        | `Default`   | Brian @ Home              |
| `Chrome Beta`        | `Profile 1` | brian.dupras@gmail.com    |

Note: regular `com.google.Chrome` has only `Default` on disk — so the user's current pain
is squarely problem (1), instance collision, not (2).

## Goals

- Let Tabzilla reliably target the **intended Chrome instance** even when an automation
  Chrome with a foreign `--user-data-dir` is running.
- Let Tabzilla optionally pin a **profile-directory** when opening URLs (for users who do
  run multiple profiles in one user-data-dir).
- Surface enough diagnostics (`dump`) to see *which* instance/profile is being targeted.
- Keep the common single-instance case zero-config and unchanged.

## Non-goals

- Driving an instance via the Chrome DevTools Protocol / `--remote-debugging-port`
  (out of scope; ScriptingBridge stays the transport).
- Cross-user-data-dir tab reuse for automation instances.

---

## Background: what each API can and can't do

| Capability                          | ScriptingBridge | NSWorkspace | Launch flag |
|-------------------------------------|-----------------|-------------|-------------|
| Pick which process (by PID)         | ✅ `applicationWithProcessIdentifier:` | ❌ | n/a |
| Pick which process (by bundle id)   | ⚠️ ambiguous when >1 | ⚠️ ambiguous | n/a |
| Pin profile-directory               | ❌ | ❌ | ✅ `--profile-directory` |
| Read a process's launch args        | via `KERN_PROCARGS2` | n/a | n/a |

Key insight: **process disambiguation must happen by PID** (ScriptingBridge can target a
PID directly), and **profile pinning must happen via launch flag** (so the very first
open for a profile must go through a process launch, not ScriptingBridge `make new tab`).

---

## Design

Three independent, separately-shippable workstreams. Recommended order: A → B → C.

### Workstream A — Instance disambiguation by user-data-dir (fixes the reported bug) ✅ IMPLEMENTED

`ChromeController` resolves a **PID**, not just a bundle id, choosing the "canonical"
Chrome instance and ignoring foreign `--user-data-dir` instances.

#### A1. Process discovery utility — `Sources/ChromeProcessLocator.{h,m}` (ObjC)

As built:

- `+ instancesForBundleId:` (discovery, impure) enumerates running processes via
  `NSRunningApplication runningApplicationsWithBundleIdentifier:` to get PIDs, then reads
  each PID's argv via `sysctl(KERN_PROCARGS2)` and extracts `--user-data-dir` /
  `--profile-directory` (supporting both `--flag=value` and `--flag value` forms).
- Each result is a `ChromeInstance` value object: `{ pid, userDataDir?, profileDirectory? }`.
  A `nil` `userDataDir` is the signal for "the default / user-facing instance".
- ObjC (not Swift) because `SBApplication` dispatches dynamically; the locator sits next
  to its only caller, `ChromeController`.

#### A2. Selection policy — `+ selectInstanceFrom:preferredUserDataDir:` (pure)

Kept as a separate pure method so it is unit-testable with hand-built inputs. Priority:

1. If `preferredUserDataDir` is non-nil (future: from config, Workstream C), match it.
2. Else prefer the instance whose `--user-data-dir` is absent (the user-facing Chrome).
3. Else, if exactly one instance, use it.
4. Else (ambiguous, none default) → return nil; caller falls back to bundle-id targeting,
   so we never regress to "nothing works".

`+ resolvePIDForBundleId:preferredUserDataDir:` composes discovery + selection and logs
an `os_log_info` on the ambiguous-fallback path.

#### A3. Thread the PID through `ChromeController`

`chromeAppForBundleId:` (`ChromeController.m`) now calls the locator: a resolved PID > 0
returns `SBApplication applicationWithProcessIdentifier:`, otherwise it falls back to
`applicationWithBundleIdentifier:`. All existing methods already funnel through this one
accessor, so it was a single chokepoint change.

> **Deferred:** PID caching. Currently each `chromeAppForBundleId:` call re-runs the
> `sysctl` scan. Cheap enough for current call volume; revisit if profiling shows it
> matters. Would need invalidation when the PID exits.

#### A4. Outcome — verified

`make dump` and all tab/window operations target the real Chrome even while the
Playwright instance is alive (confirmed live 2026-06-12: 20 real windows vs. the POC's 1).
No config required for the default "ignore foreign user-data-dir" behavior.

#### A' — Optional convenience (no longer a fallback)

The spike proved PID targeting works, so the Beta-channel mitigation is **not** needed for
correctness. It remains a reasonable convenience to mention in the README: running
automation against Chrome Beta (`com.google.Chrome.beta`) keeps the two entirely separate
and avoids even the brief ambiguity window. Optional.

### Workstream B — Profile pinning via launch flag (`--profile-directory`)

For users who run multiple profiles inside one user-data-dir.

#### B1. New "open with profile" path

When a resolved route needs a profile and the target window/tab doesn't already exist in
that profile, open via a **process launch** carrying the flag instead of ScriptingBridge
`make new tab`:

```
open -na "Google Chrome" --args --profile-directory="Profile 1" <url>
```

or the `NSWorkspace` equivalent:
`NSWorkspace.open(urls:withApplicationAt:configuration:)` with
`configuration.arguments = ["--profile-directory=Profile 1"]`.

- This becomes a new `ResolvedRoute` case (e.g. `.openInProfile(bundleId, profileDir,
  url, matchedRule)`) in `Sources/RouteResolver.swift`, executed in
  `Sources/Executor.swift` alongside `.openWithWorkspace`.
- Limitation to document: profile-pinned opens cannot do ScriptingBridge tab-reuse on the
  *first* open into that profile; subsequent reuse works once the profile's window exists
  and is the focused instance.

#### B2. Profile name → directory resolution

Users think in display names ("Brian @ Home"); the flag needs the directory (`Default`,
`Profile 1`). Add a resolver that reads
`~/Library/Application Support/Google/<channel>/Local State` →
`profile.info_cache[*].name` to map display name → directory key. Accept either form in
config; if a display name is given, resolve it, else pass through the literal dir.

### Workstream C — Config schema (both defaults + per-rule)

Extend `Sources/Config.swift` mirroring the existing `browser`/`window` pattern.

```yaml
defaults:
  browser: com.google.Chrome
  profile: "Default"            # display name OR directory key (optional)
  userDataDir: ~                # optional; pins instance for Workstream A

rules:
  - name: work
    url: '.*airbnb\.com.*'
    browser: com.google.Chrome
    profile: "brian.dupras@airbnb.com"
    window: Work
```

- Add optional `profile: String?` and `userDataDir: String?` to both
  `Config.Defaults` (`Config.swift:11`) and `Config.Rule` (`Config.swift:21`), with
  matching `init` defaults (keep them last to preserve call sites).
- `RouteAction` / `RuleEngine` (`Sources/RuleEngine.swift`) resolve these like
  `browser`/`windowTarget` today — rule value overrides default.
- Both fields optional everywhere → existing configs keep working untouched.

### Workstream D — Diagnostics (`dump`)

- Extend `BrowserState` (in `Sources/CLI.swift`, ~line 354 `getBrowserState`) to report,
  per Chrome-based browser: the **resolved PID**, its `userDataDir`, `profileDirectory`,
  and a list of *all* detected instances (so a colliding Playwright Chrome is visible at a
  glance).
- This makes the original "make dump only sees the Playwright profile" situation
  self-diagnosing.

---

## Affected files

| File | Change | Status |
|------|--------|--------|
| `Sources/ChromeProcessLocator.{h,m}` (new) | Enumerate PIDs + read `--user-data-dir`/`--profile-directory` via `KERN_PROCARGS2`; pure selection policy (A1, A2). | ✅ done |
| `Sources/ChromeController.m` | `chromeAppForBundleId:` resolves a PID via locator (A3). | ✅ done |
| `Tabzilla.xcodeproj/project.pbxproj`, `Package.swift` | Register locator in Xcode build; exclude from SPM test target. | ✅ done |
| `Sources/ChromeController.h` | Possibly expose instance-list query for diagnostics. | ⬜ (D) |
| `Sources/Config.swift` | Add `profile`, `userDataDir` to `Defaults` + `Rule` (C). | ⬜ |
| `Sources/RuleEngine.swift` | Resolve new fields into the action. | ⬜ (C) |
| `Sources/RouteResolver.swift` | New `.openInProfile` route case (B1). | ⬜ (B) |
| `Sources/Executor.swift` | Execute `.openInProfile` via launch flag (B1). | ⬜ (B) |
| `Sources/ProfileResolver.swift` (new) | Display-name → directory mapping from `Local State` (B2). | ⬜ (B) |
| `Sources/CLI.swift` | `dump` reports resolved PID / instances (D). | ⬜ |
| `Tests/` | Unit tests for `selectInstanceFrom:` policy (A2). | ⬜ — see note |
| `README.md`, `DEVELOPMENT.md` | Document profile/instance config + Beta-channel workflow tip. | ⬜ |

> **Testing note for A2:** the pure selection policy is unit-testable, but the locator is
> ObjC and **excluded from the SPM test target** (SPM can't mix Swift/ObjC, same reason as
> `ChromeController`). Options: (a) add an ObjC/XCTest target in the Xcode project, or
> (b) accept manual/integration verification (done live on 2026-06-12) for now. Decide
> when picking up the remaining workstreams.

## Testing

- Unit: selection policy (A2) — table-driven over candidate lists (no UDD, one foreign
  UDD, two foreign, explicit config match).
- Unit: profile name→dir resolution (B2) with a fixture `Local State` JSON.
- Unit: `RouteResolver` produces `.openInProfile` when profile set and no matching window.
- Integration (manual / scripted): launch a second Chrome with
  `--user-data-dir=/tmp/poc-chrome-profile` and assert `make dump` shows the **real**
  Chrome's windows and reports both instances.
- Regression: existing configs with no `profile`/`userDataDir` behave identically.

## Open questions / risks

1. ~~**Does `applicationWithProcessIdentifier:` truly disambiguate Apple Event delivery for
   same-bundle-id processes?**~~ **Resolved 2026-06-12** — yes, validated by spike and by
   the live `make dump` result. Workstream A shipped.
2. `KERN_PROCARGS2` requires the args be readable for the user's own processes (fine for
   same-user Chrome). No entitlement needed for same-uid. Confirmed working from the
   packaged (hardened-runtime) app — `make dump` read the POC instance's `--user-data-dir`
   successfully.
3. Sandboxing for **Workstream B** specifically: confirm `NSWorkspace.open(arguments:)`
   passes the `--profile-directory` flag through under the current entitlements before
   building B.
4. First-open-into-profile can't reuse tabs (B1 limitation) — acceptable, document it.
5. PID-cache invalidation (deferred under A3) if the `sysctl` scan ever shows up in
   profiling.

## Recommended sequencing

1. ~~**A + D**~~ — **A done.** D (dump reports resolved PID + all instances) still
   outstanding and is the natural next small step, since it makes the new behavior
   observable and aids future debugging.
2. **C** next: config plumbing (cheap, enables both A's explicit `userDataDir` pin —
   currently always passed `nil` — and B).
3. **B** last: profile-directory pinning for the multi-profile-in-one-UDD case (not the
   user's current need, but completes the feature).
4. Optional: add the **Chrome Beta channel** convenience note to README.
