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

### Version Management

Version is derived from git tags (`v1.0.0`). The `set-version` script patches all three locations where the version is tracked:

- `Sources/CLI.swift` — CLI `--version` output
- `Tabzilla.xcodeproj/project.pbxproj` — `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`
- `Sources/Resources/Info.plist` — inherits from Xcode build settings (no manual edit needed)

```bash
make version                  # Show current version
make set-version V=1.2.0     # Set version everywhere
```

### Continuous Integration

CI runs on GitHub Actions (`macos-14` runner). Currently manual-trigger only:

```bash
gh workflow run ci.yml                # Run CI on main
gh workflow run ci.yml --ref branch   # Run CI on a branch
```

Or trigger from the GitHub Actions tab: select "CI" workflow → "Run workflow".

CI runs `make test` (unit tests via SPM) and `make build` (full Xcode build verification).

### Releasing

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
make install                           # Rebuild and install
make kill && make run                  # Restart daemon
open https://example.com               # Test via default browser
tail -f ~/Library/Logs/Tabzilla/tabz.log  # Watch logs
```

## Project Structure

```
tabzilla/
├── Package.swift                   # SPM config (macOS 13+, ArgumentParser, Yams)
├── Tabzilla.xcodeproj/             # Xcode project for app bundle
├── Makefile                        # Build/test/install workflow
├── scripts/
│   └── set-version.sh             # Version sync script
├── .github/workflows/
│   ├── ci.yml                     # CI workflow (manual trigger)
│   └── release.yml                # Release workflow (tag trigger)
├── Sources/
│   ├── TabzillaApp.swift           # App entry, AppDelegate, URL handling
│   ├── CLI.swift                   # test/status/reload/quit/open subcommands
│   ├── Config.swift                # YAML models, ConfigurationManager, FileWatcher, Logger
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
    └── example.yaml                # Test config
```

## Architecture

See [DESIGN.md](DESIGN.md) for architecture, data flow, and key implementation decisions.

## Troubleshooting

See [README.md](README.md) for troubleshooting steps.
