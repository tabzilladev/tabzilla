# Development Guide

## Prerequisites

- macOS 13+
- Xcode 15+ (includes Swift and command-line tools)

## Build System

Tabzilla uses Xcode for all builds because the project contains mixed Swift/Objective-C code (SPM doesn't support this). SPM is only used for running tests.

Run `make help` for all available commands:

```
  make build      Build release app bundle
  make debug      Build debug binary with Xcode
  make test       Run unit tests
  make install    Build, install to /Applications, register
  make uninstall  Remove from /Applications
  make register   Re-register with Launch Services
  make clean      Remove build artifacts

  make run        Start the daemon
  make stop       Stop the daemon
  make kill       Force kill all Tabzilla processes
  make status     Show daemon status
  make reload     Reload configuration

  make test-url URL=<url> [CONFIG=<path>]
                  Test which rule matches (uses debug build)
```

**Note**: Xcode build must use default DerivedData location. Custom SYMROOT breaks SPM dependency resolution.

## Quick Start

```bash
# Clone and build
git clone https://github.com/bdupras/tabzilla.git
cd tabzilla
make install

# Set as default browser in System Settings > Desktop & Dock > Default web browser

# Start the daemon
make run
```

## Testing

```bash
# Run all unit tests (21 tests)
make test

# Test URL routing with your config
make test-url URL=https://example.com

# Test with a specific config file
make test-url URL=https://example.com CONFIG=path/to/config.yaml
```

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
├── Package.swift                    # SPM config (macOS 13+, ArgumentParser, Yams)
├── Tabzilla.xcodeproj/               # Xcode project for app bundle
├── Makefile                        # Build/test/install workflow
├── Sources/
│   ├── TabzillaApp.swift             # App entry, AppDelegate, URL handling
│   ├── CLI.swift                   # test/status/reload/quit/open subcommands
│   ├── Config.swift                # YAML models, ConfigurationManager, FileWatcher, Logger
│   ├── RuleEngine.swift            # RouteRequest → RouteAction matching
│   ├── Executor.swift              # Browser control via Scripting Bridge
│   ├── Chrome.h                    # Generated Scripting Bridge header
│   ├── ChromeController.h/.m       # Chrome automation (Objective-C)
│   ├── Tabzilla-Bridging-Header.h    # Swift/Obj-C bridging
│   └── Resources/
│       ├── Info.plist              # URL schemes, document types
│       ├── Tabzilla.entitlements     # Apple Events permission
│       └── DefaultConfig.yaml
├── Tests/
│   ├── RuleEngineTests.swift       # Rule matching tests
│   └── ConfigTests.swift           # YAML parsing tests
└── test/fixtures/
    └── example.yaml                # Test config
```

## Architecture

### Data Flow

```
URL Click → Apple Event → RouteRequest → RuleEngine → RouteAction → Executor → ChromeController → Browser

Shortcut files (.webloc/.url) → Apple Event → Delegate to default browser (bypass rules)
```

### Key Components

- **RuleEngine**: Pure functions for matching URLs against rules
- **Executor**: Orchestrates browser control
- **ChromeController**: Objective-C Scripting Bridge for Chrome automation
- **ConfigurationManager**: YAML loading with file watching for live reload

### Browser Control (Scripting Bridge)

Chrome automation uses Objective-C Scripting Bridge rather than AppleScript strings for type safety and performance.

Key points:
- Windows are targeted by `givenName` property (persists independently of tab titles)
- Must use `objectWithID:` to get stable references for windows and tabs
- Tab reuse (`useTab`/`focusTab`) uses regex matching against tab URLs

## Troubleshooting

### URLs don't open after reinstall

1. Check **System Settings → Privacy & Security → Automation**
2. Ensure Tabzilla has Google Chrome toggled ON
3. If missing, reset and restart:
   ```bash
   tccutil reset AppleEvents dev.tabzilla.Tabzilla
   make kill && make run
   ```

### Enable logging

Add to your config:
```yaml
logging:
  enabled: true
  path: ~/Library/Logs/Tabzilla/tabz.log
```

View logs:
```bash
tail -f ~/Library/Logs/Tabzilla/tabz.log
```
