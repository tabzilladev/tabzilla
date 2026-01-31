# Tabzilla

A native macOS application that registers as the system's default browser and routes URLs to specific browsers (Chrome, Chrome Beta, etc.) based on user-defined rules.

**Key feature**: Routes URLs to specific named browser windows (creating them if needed), enabling project-based and work/personal separation workflows.

## Features

- **Rule-based URL routing** - Route URLs based on regex patterns matching URL, source app, or source window title
- **Named window targeting** - Open URLs in specific Chrome windows by `givenName`, creating them if needed
- **Tab reuse** - Focus existing tabs matching a pattern instead of opening duplicates
- **Multiple browser support** - Route to Chrome, Chrome Beta, or any browser by bundle ID
- **YAML configuration** - Simple, versionable config file with live reload
- **Headless daemon** - Runs as background agent with no dock icon or menu bar
- **CLI interface** - Test rules, check status, reload config, and control the daemon

## Installation

### Build from source

```bash
# Clone the repository
git clone https://github.com/bdupras/tabzilla.git
cd tabzilla

# Build with Swift Package Manager
swift build -c release

# Build the app bundle with Xcode
xcodebuild -project Tabzilla.xcodeproj -scheme Tabzilla -configuration Release

# The app will be in build/Release/Tabzilla.app
```

### Set as default browser

1. Open **System Settings** > **Desktop & Dock** > **Default web browser**
2. Select **Tabzilla** from the dropdown

## Configuration

Tabzilla searches for configuration in these locations (first found wins):

1. `~/.config/tabz/config.yaml`
2. `~/Library/Application Support/Tabzilla/config.yaml`
3. `~/.tabz.yaml`

### Example Configuration

```yaml
version: 1

defaults:
  browser: com.google.Chrome
  window: Default

rules:
  # Route work Slack links to Chrome Beta
  - name: work-slack
    sourceApp: ^com\.tinyspeck\.slackmacgap$
    sourceWindowTitle: (?i)work
    browser: com.google.Chrome.beta
    window: Work

  # Route work domains
  - name: work-domains
    url: (?i)corp\.example\.com|jira\.example\.com
    browser: com.google.Chrome.beta
    window: Work

  # GitHub PRs in dedicated window
  - name: github-prs
    url: github\.com/.+/pull/\d+
    window: Code Review

  # Tab reuse for Google Docs
  - name: google-docs
    url: docs\.google\.com/document/d/([^/]+)
    useTab: docs\.google\.com/document/d/\1

  # Catch-all (uses defaults)
  - url: .*

logging:
  enabled: false
```

### Rule Matching

All matching uses ICU regex (NSRegularExpression). Rules are evaluated in order; first match wins.

**Match conditions** (all must match if specified):
- `url` - Regex against the full URL
- `sourceApp` - Regex against bundle ID of the app that opened the link
- `sourceWindowTitle` - Regex against the frontmost window title of the source app

**Actions**:
- `browser` - Bundle ID of target browser (default: `com.google.Chrome`)
- `window` - Name for window targeting via `givenName` (default: `Default`)
- `useTab` - Regex pattern to find existing tab; focus and navigate
- `focusTab` - Regex pattern to find existing tab; focus only (don't navigate)

**Regex features**:
- `(?i)` - Case-insensitive matching
- `\1`, `\2` - Capture group references in `useTab`/`focusTab` patterns
- Full ICU regex support (lookahead, lookbehind, etc.)

## CLI Usage

The app binary can be invoked directly for CLI commands:

```bash
# Create an alias for convenience
alias tabz='/Applications/Tabzilla.app/Contents/MacOS/Tabzilla'

# Test which rule matches a URL
tabz test "https://github.com/user/repo/pull/123"
tabz test "https://example.com" --source-app "com.tinyspeck.slackmacgap"

# Check daemon status and config
tabz status

# Reload configuration
tabz reload

# Stop the daemon
tabz quit
```

## How It Works

1. **URL Reception**: Tabzilla registers for `http` and `https` URL schemes. When the user clicks a link, macOS sends an Apple Event to Tabzilla.

2. **Source Detection**: Tabzilla captures the source app's bundle ID and attempts to read the frontmost window title (for Slack workspace detection, etc.).

3. **Rule Matching**: The URL and source info are matched against rules in order. First match wins.

4. **Window Targeting**: Chrome windows are identified by their `givenName` property (distinct from the window title). If no matching window exists, one is created.

5. **Tab Reuse**: If `useTab` or `focusTab` is specified, existing tabs are searched before opening a new one.

## Browser Support

Currently supports Chrome-based browsers via AppleScript:
- `com.google.Chrome` - Google Chrome
- `com.google.Chrome.beta` - Google Chrome Beta

Other browsers can be targeted but won't support window naming or tab reuse.

## Permissions

Tabzilla requires **Automation** permission to control browsers. On first use, macOS will prompt you to allow Tabzilla to control Google Chrome (or other browsers).

## Troubleshooting

**Enable logging** for debugging:

```yaml
logging:
  enabled: true
  path: ~/Library/Logs/Tabzilla/tabz.log
```

**View logs**:
```bash
tail -f ~/Library/Logs/Tabzilla/tabz.log
```

**Check if daemon is running**:
```bash
tabz status
```

## Development

```bash
# Run tests
swift test

# Build for debugging
swift build

# Build app bundle
xcodebuild -project Tabzilla.xcodeproj -scheme Tabzilla build
```

## License

MIT
