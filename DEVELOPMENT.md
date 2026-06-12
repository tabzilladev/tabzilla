# Development Guide

## Building from Source

### Prerequisites
Requires macOS 13+ and Xcode 16.2+.

```bash
brew install swiftlint swiftformat
```


```bash
git clone https://github.com/tabzilladev/tabzilla.git
cd tabzilla
make install
```

This builds the app and installs it to `/Applications/Tabzilla.app`.

After installing, launch it once and run the guided setup to grant permissions
and set Tabzilla as your default browser:

```bash
tabz setup     # or: /Applications/Tabzilla.app/Contents/MacOS/Tabzilla setup
```

Check the status of every requirement anytime with `tabz doctor`.

### Uninstall / fresh-install reset

`make uninstall` removes the app **and** clears the macOS state that lives
outside the bundle (the default-browser binding plus Accessibility and
Automation grants) — the same state the cask's `brew uninstall --zap` clears for
end users. Use it to reproduce a true fresh-install state:

```bash
make uninstall
```

(`make install` removes the old bundle itself, so the fast reinstall loop
doesn't need this — reach for it only when you want a clean-slate reset.)

## Build System

Tabzilla uses Xcode for all builds because the project contains mixed Swift/Objective-C code (SPM doesn't support this). SPM is only used for running tests.

Run `make help` for all available commands.

**Note**: Xcode build must use default DerivedData location. Custom SYMROOT breaks SPM dependency resolution.

## Testing

```bash
# Run all unit tests
make test

# Test URL routing with your config
make test-url URL=https://example.com

# Test with a specific config file
make test-url URL=https://example.com CONFIG=path/to/config.yaml
```

## Landing Changes

Work lands on `main` via pull requests so that CI gates each change and the
release changelog (auto-generated from merged PR titles) stays meaningful.

```bash
git switch -c bdupras-short-summary   # branch naming: <user>-three-to-five-word-summary
# ... make changes, commit ...
git push -u origin bdupras-short-summary
gh pr create --fill                   # CI runs automatically on the PR
gh pr merge --squash                  # squash so the PR title is the changelog line
```

Notes:
- The **PR title** becomes the changelog entry — write it as the user-facing summary.
- Squash-merge keeps `main` linear; individual commit messages are not surfaced in
  release notes (GitHub auto-notes are PR-level only).
- Branch protection is not enforced (private repo on the free plan), so the PR flow is
  convention. Avoid pushing feature work directly to `main`.
- The release version-bump commit (made by `make release`) is the one expected exception
  — it lands directly on `main`.

## CI/CD

### Continuous Integration

CI runs on GitHub Actions (`macos-14` runner). It runs automatically on every
pull request targeting `main`, and can also be triggered manually:

```bash
make ci-trigger                       # Trigger CI manually and watch
make ci-trigger NOWATCH=1             # Trigger without watching
gh workflow run ci.yml --ref branch   # Trigger CI on a specific branch
make ci-watch                         # Watch the run for the current HEAD commit
make ci-watch RUN=<id>                # Watch a specific run (e.g. after re-attaching)
```

Or trigger from the GitHub Actions tab: select "CI" workflow → "Run workflow".

CI runs `make test` (unit tests via SPM), `make build` (full Xcode build verification), `make lint`, and `make format-check`.

### Releasing

#### Version Management

Version is tracked in two files (plus Info.plist which inherits from Xcode build settings):
- `Sources/CLI.swift` — CLI `--version` output
- `Tabzilla.xcodeproj/project.pbxproj` — `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`

```bash
make show-version            # Show current version
make set-version V=1.1.0     # Set version everywhere (without committing)
```

#### Creating a Release

```bash
make release V=1.1.0 DRY_RUN=1   # Preview what will happen
make release V=1.1.0             # Execute the release, watch CI
make release V=1.1.0 FORCE=1     # Re-release (delete and recreate tag)
make release V=1.1.0 NOWATCH=1   # Release without waiting for CI
```

Preconditions (checked before any changes are made):
- On the `main` branch
- Local `main` is up to date with `origin/main` (fetched and compared; errors if behind or diverged)
- Working tree is clean (no uncommitted or untracked files)
- Version is valid semver (X.Y.Z) and differs from current
- Tag does not already exist (unless `FORCE=1`)

This validates preconditions, verifies the build and tests pass locally
(`make build test`) before tagging, patches version numbers, commits the bump,
creates git tag `v1.1.0`, pushes it to origin, and watches CI until completion.
The local verification guards against tagging a broken commit (which would
otherwise fail the release workflow and require a `FORCE=1` re-release).
The tag push triggers the release workflow which:
1. Runs tests
2. Builds the release app bundle (universal binary: arm64 + x86_64)
3. Packages `Tabzilla.app` into `Tabzilla-1.1.0-macos.zip` with SHA256
4. Creates a GitHub Release with the zip attached
5. Updates the Homebrew Cask in `tabzilladev/homebrew-tap` (requires `HOMEBREW_TAP_TOKEN` Actions secret)

#### Release Data Flow

```
make release V=X.Y.Z
   └─ preconditions (incl. fetch guard)
   └─ bump + commit + push main
   └─ push tag vX.Y.Z ───────────────┐
                                     ▼
                         release.yml fires on tag
   make ci-watch ◄──────── (watches THIS run by SHA)
                                     │
                         test → build → package → GitHub Release
                                     │
                         update-homebrew → cask bump
```

## Development Workflow

After making changes:

```bash
make install               # Rebuild and install
make stop && make start    # Restart daemon
make logs-follow           # Watch logs
open https://example.com   # Test via default browser
```

## Project Structure

```
tabzilla/
├── Package.swift                   # SPM config (macOS 13+, ArgumentParser, Yams)
├── Tabzilla.xcodeproj/             # Xcode project for app bundle
├── Makefile                        # Build/test/install workflow
├── scripts/
│   ├── release.sh                 # Release packaging script
│   └── set-version.sh             # Version sync script
├── .github/workflows/
│   ├── ci.yml                     # CI workflow (manual trigger)
│   └── release.yml                # Release workflow (tag trigger)
├── Sources/
│   ├── TabzillaApp.swift           # App entry, AppDelegate, URL handling
│   ├── CLI.swift                   # test/status/reload/stop/open subcommands
│   ├── Config.swift                # YAML models, ConfigurationManager, ConfigFingerprint
│   ├── RuleEngine.swift            # RouteRequest → RouteAction matching
│   ├── RouteResolver.swift         # RouteAction + BrowserSnapshot → ResolvedRoute (pure)
│   ├── Executor.swift              # Browser control via Scripting Bridge
│   ├── Chrome.h                    # Generated Scripting Bridge header
│   ├── ChromeController.h/.m       # Chrome automation (Objective-C)
│   ├── Tabzilla-Bridging-Header.h  # Swift/Obj-C bridging
│   └── Resources/
│       ├── Info.plist              # URL schemes, document types
│       ├── Tabzilla.entitlements   # Apple Events permission
│       └── DefaultConfig.yaml
└── Tests/
    ├── RuleEngineTests.swift       # Rule matching tests
    └── ConfigTests.swift           # YAML parsing tests
```

## Design

### Data Flow

```
URL Click → Apple Event → RouteRequest → RuleEngine → RouteAction → RouteResolver → ResolvedRoute → Executor → [Scripting Bridge] → Browser
╰─────── macOS ────────╯ ╰──────────────────────────────────────── Tabzilla ────────────────────────────────╯
```

### Key Design Decisions

#### 1. Why Objective-C (and why there are two build systems)

Scripting Bridge requires Objective-C: the `.sdef`-generated header (`Chrome.h`) uses Obj-C object types, and the Scripting Bridge runtime is an Obj-C API. This forces the project to be mixed Swift/Obj-C.

SPM doesn't support mixed Swift/Obj-C targets. This forces the app build to use Xcode, which does support mixed-language targets.

SPM is retained for tests because it provides fast `make test` iteration without a full Xcode build. The test target only includes pure Swift files.

#### 2. Logging

Tabzilla uses Apple's unified logging (`os.Logger` in Swift, `os_log` in Objective-C) with subsystem `"dev.tabzilla.Tabzilla"`. Each source file declares a file-level logger with a component category:

| File | Category |
|------|----------|
| `TabzillaApp.swift` | `"app"` |
| `CLI.swift` | `"cli"` |
| `Executor.swift` | `"executor"` |
| `RuleEngine.swift` | `"rules"` |
| `ChromeController.m` | `"chrome"` |

`ChromeController.m` uses `os_log_create()` / `os_log_error()` directly via `<os/log.h>`. No Swift bridging header is needed for logging.

#### 3. Pure/impure separation (RuleEngine → RouteResolver → Executor)

Routing is split into three stages:

`RuleEngine` is a pure value type (`struct`): given a `Config` and a `RouteRequest`, it produces a `RouteAction` with no side effects.

`RouteResolver` is also a pure `struct`. It takes a `RouteAction` and a `BrowserSnapshot` (the already-fetched browser state) and produces a concrete `ResolvedRoute` — one of: focus a tab, navigate a tab, open in an existing window, create a new window, or fall back to `NSWorkspace`.

`Executor` is the side-effect boundary. It fetches the `BrowserSnapshot` from Chrome via Scripting Bridge, calls `RouteResolver.resolve()`, then executes the resulting `ResolvedRoute` by calling `ChromeController` or `NSWorkspace`.

This split makes both rule-matching and routing-decision logic fully testable without any browser installed or running. If you're changing URL-to-action matching, it lives in `RuleEngine.swift`. If you're changing how a `RouteAction` is translated into a concrete browser operation, it lives in `RouteResolver.swift`. If you're changing how browsers are actually controlled, it lives in `Executor.swift` and `ChromeController.m`.

#### 4. Batch IPC and tab caching

Each property access on a Scripting Bridge element array (`[array valueForKey:@"id"]`) triggers one Apple Event IPC call to Chrome and fetches that property for all elements at once. This is far cheaper than accessing the property on each element individually, which would be one IPC call per element.

`getAllTabsForBundleId:` uses this pattern: two `valueForKey:` calls fetch all window IDs and all window names in two IPC calls total, then two more fetch all tab IDs and URLs per window.

When a `RouteAction` has multiple tab actions (e.g., `focusTab` + `followTab`), `Executor.executeChromeAction` fetches the tab cache once and passes it to all `findTab` calls. Without caching, each tab action would independently enumerate all Chrome windows and tabs via IPC.

#### 5. Stat-before-route config freshness

Config is reloaded lazily at URL-routing time rather than eagerly via a file watcher. `ConfigFingerprint` (in `Config.swift`) captures the config file's mtime and inode via `stat()`. Both are tracked because atomic saves (write-to-temp + rename) change the inode while mtime can have 1-second granularity.

Before each `routeURL` call, `routeURL` compares the current fingerprint against the stored one. A mismatch triggers `reloadConfiguration()`. This approach has zero idle overhead, handles atomic saves transparently, and guarantees the config is fresh at routing time without any race with debounce timing.

---
