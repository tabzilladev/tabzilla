# Development Guide

## Building from Source

Requires macOS 13+ and Xcode 16+.

```bash
git clone https://github.com/tabzilladev/tabzilla.git
cd tabzilla
make install
```

This builds the app and installs it to `/Applications/Tabzilla.app`.

After installing:
1. Set as default browser: **System Settings** > **Desktop & Dock** > **Default web browser** > **Tabzilla**
2. Start the daemon: `make run`

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

## CI/CD

### Continuous Integration

CI runs on GitHub Actions (`macos-14` runner). Currently manual-trigger only:

```bash
gh workflow run ci.yml                # Run CI on main
gh workflow run ci.yml --ref branch   # Run CI on a branch
```

Or trigger from the GitHub Actions tab: select "CI" workflow → "Run workflow".

CI runs `make test` (unit tests via SPM) and `make build` (full Xcode build verification).

### Releasing

#### Version Management

Version is derived from git tags (`v1.0.0`). The `set-version` script patches all three locations where the version is tracked:

- `Sources/CLI.swift` — CLI `--version` output
- `Tabzilla.xcodeproj/project.pbxproj` — `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`
- `Sources/Resources/Info.plist` — inherits from Xcode build settings (no manual edit needed)

```bash
make version                 # Show current version
make set-version V=1.1.0     # Set version everywhere
```

Releases are triggered by pushing a version tag:

```bash
git tag v1.1.0
git push origin v1.1.0
```

The release workflow automatically:
1. Patches version numbers from the tag
2. Runs tests
3. Builds the release app bundle
4. Packages `Tabzilla.app` into a zip with SHA256 checksum
5. Creates a GitHub Release with the zip attached
6. Updates the Homebrew Cask in `tabzilladev/homebrew-tap`

## Development Workflow

After making changes:

```bash
make install                              # Rebuild and install
make stop && make run                     # Restart daemon
open https://example.com                  # Test via default browser
tail -f ~/Library/Logs/Tabzilla/tabz.log  # Watch logs
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
│   ├── CLI.swift                   # test/status/reload/quit/open subcommands
│   ├── Config.swift                # YAML models, ConfigurationManager, ConfigFingerprint, Logger
│   ├── RuleEngine.swift            # RouteRequest → RouteAction matching
│   ├── Executor.swift              # Browser control via Scripting Bridge
│   ├── Chrome.h                    # Generated Scripting Bridge header
│   ├── ChromeController.h/.m       # Chrome automation (Objective-C)
│   ├── Tabzilla-Bridging-Header.h  # Swift/Obj-C bridging
│   └── Resources/
│       ├── Info.plist              # URL schemes, document types
│       ├── Tabzilla.entitlements   # Apple Events permission
│       └── DefaultConfig.yaml
├── Tests/
│   ├── RuleEngineTests.swift       # Rule matching tests
│   └── ConfigTests.swift           # YAML parsing tests
└── test/fixtures/
    ├── example.yaml                # Test config
    └── test-features.yaml          # Feature-specific test config
```

## Design

### Data Flow

```
URL Click → Apple Event → RouteRequest → RuleEngine → RouteAction → Executor → [Scripting Bridge] → Browser
╰─────── macOS ────────╯ ╰────────────────────────── Tabzilla ──────────────╯
```

### Key Design Decisions

#### 1. Why Objective-C (and why there are two build systems)

Scripting Bridge requires Objective-C: the `.sdef`-generated header (`Chrome.h`) uses Obj-C object types, and the Scripting Bridge runtime is an Obj-C API. This forces the project to be mixed Swift/Obj-C.

SPM doesn't support mixed Swift/Obj-C targets. This forces the app build to use Xcode, which does support mixed-language targets.

SPM is retained for tests because it provides fast `make test` iteration without a full Xcode build. The test target only includes pure Swift files (see decision #12).

The causal chain: Scripting Bridge → Obj-C → mixed-language → Xcode for app build → dual build system.

#### 2. Cross-language bridging (@objc Logger)

`Logger` is declared `@objc class Logger: NSObject` in `Config.swift`. This causes Xcode to include it in the auto-generated `Tabzilla-Swift.h` header, which is imported at the top of `ChromeController.m`:

```objc
#import "Tabzilla-Swift.h"
```

This allows `ChromeController.m` to call `[[Logger shared] log:...]` directly. `Tabzilla-Swift.h` is generated by Xcode at build time and is not checked in to the repository — it's expected to be absent from a fresh clone.

#### 3. Pure/impure separation (RuleEngine vs Executor)

`RuleEngine` is a pure value type (`struct`): given a `Config` and a `RouteRequest`, it produces a `RouteAction` with no side effects. It doesn't touch the filesystem, network, or any browser.

`Executor` is the side-effect boundary. It receives a `RouteAction` and performs all impure operations: querying Chrome's window/tab state via Scripting Bridge, opening URLs, and activating windows.

This split makes the rule-matching logic fully testable without any browser installed or running, and keeps the test suite fast (no mocking of browser state). If you're changing routing behavior, it lives in `RuleEngine.swift`. If you're changing how browsers are controlled, it lives in `Executor.swift` and `ChromeController.m`.

#### 4. Batch IPC and tab caching

Each property access on a Scripting Bridge element array (`[array valueForKey:@"id"]`) triggers one Apple Event IPC call to Chrome and fetches that property for all elements at once. This is far cheaper than accessing the property on each element individually, which would be one IPC call per element.

`getAllTabsForBundleId:` uses this pattern: two `valueForKey:` calls fetch all window IDs and all window names in two IPC calls total, then two more fetch all tab IDs and URLs per window.

When a `RouteAction` has multiple tab actions (e.g., `focusTab` + `followTab`), `Executor.executeChromeAction` fetches the tab cache once and passes it to all `findTab` calls. Without caching, each tab action would independently enumerate all Chrome windows and tabs via IPC.

#### 5. Stat-before-route config freshness

Config is reloaded lazily at URL-routing time rather than eagerly via a file watcher. `ConfigFingerprint` (in `Config.swift`) captures the config file's mtime and inode via `stat()`. Both are tracked because atomic saves (write-to-temp + rename) change the inode while mtime can have 1-second granularity.

Before each `routeURL` call, `routeURL` compares the current fingerprint against the stored one. A mismatch triggers `reloadConfiguration()`. This approach has zero idle overhead, handles atomic saves transparently, and guarantees the config is fresh at routing time without any race with debounce timing.

---