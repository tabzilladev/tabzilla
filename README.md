<img src="assets/tabzilla-banner.svg" width="120" align="right" />

# Tabzilla

[![CI](https://github.com/tabzilladev/tabzilla/actions/workflows/ci.yml/badge.svg)](https://github.com/tabzilladev/tabzilla/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/tabzilladev/tabzilla)](https://github.com/tabzilladev/tabzilla/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

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

### Homebrew (recommended)

```bash
brew install --cask tabzilladev/tap/tabzilla
```

### Build from source

See [DEVELOPMENT.md](DEVELOPMENT.md) for building from source.

### Set as default browser

After installing, set Tabzilla as your default browser:

1. Open **System Settings** > **Desktop & Dock** > **Default web browser**
2. Select **Tabzilla** from the dropdown

## Configuration

Tabzilla searches for configuration in these locations (first found wins):

1. `~/.config/tabz/config.yaml`
2. `~/Library/Application Support/Tabzilla/config.yaml`
3. `~/.tabz.yaml`

### Quick Start

```yaml
version: 1

defaults:
  browser: com.google.Chrome

rules:
  # Work links open in a dedicated "Work" window
  - name: work
    url: (?i)corp\.example\.com|jira\.example\.com
    window: Work

  # Everything else uses browser's default behavior
  - url: .*
```

Chrome windows are identified by their **given name** (set via Menu Bar → Window → Name Window), which is distinct from the window title. If no window with the specified name exists, Tabzilla creates one.

### Full Example

```yaml
version: 1

defaults:
  browser: com.google.Chrome
  # window: Default  # Optional: omit to let the browser decide

rules:
  # Route work Slack links to Work window
  - name: work-slack
    sourceApp: ^com\.tinyspeck\.slackmacgap$
    sourceWindowTitle: (?i)work
    window: Work

  # Route work domains
  - name: work-domains
    url: (?i)corp\.example\.com|jira\.example\.com
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
- `window` - Name of target browser window (optional; omit to let browser decide)
- `useTab` - Find existing tab matching regex; focus it and navigate to the new URL
- `focusTab` - Find existing tab matching regex; focus it only (ignore incoming URL)
- `followTab` - Find existing tab matching regex; open new URL in a new tab in the same window

**Regex features**:
- `(?i)` - Case-insensitive matching
- `\1`, `\2` - Capture group references in `useTab`/`focusTab`/`followTab` patterns
- Full ICU regex support (lookahead, lookbehind, etc.)

## CLI Usage

The app binary can be invoked directly for CLI commands:

```bash
# Create an alias for convenience
alias tabz='/Applications/Tabzilla.app/Contents/MacOS/Tabzilla'

# Route a URL via rules and open in browser
tabz open "https://example.com"

# Test which rule matches a URL (dry run)
tabz test "https://github.com/user/repo/pull/123"
tabz test "https://example.com" --source-app "com.tinyspeck.slackmacgap"

# Check daemon status and config
tabz status

# Dump full daemon state as JSON (for tools/agents)
tabz dump

# Reload configuration
tabz reload

# Stop the daemon
tabz quit
```

## How It Works

1. **URL Reception**: Tabzilla registers for `http`, `https`, `file`, `chrome`, and `chrome-extension` URL schemes. When the user clicks a link, macOS sends an Apple Event to Tabzilla. It also handles `.webloc` and `.url` shortcut files (delegated directly to the default browser).

2. **Source Detection**: Tabzilla captures the source app's bundle ID and attempts to read the frontmost window title (for Slack workspace detection, etc.).

3. **Rule Matching**: The URL and source info are matched against rules in order. First match wins.

4. **Window Targeting**: Chrome windows are identified by their **given name** (Menu Bar → Window → Name Window), which is distinct from the window title. If no matching window exists, one is created.

5. **Tab Handling**: If `useTab`, `focusTab`, or `followTab` is specified, existing tabs are searched. Depending on the action, Tabzilla will focus the tab, navigate it, or open a new tab in the same window.

## Browser Support

**Full support** (window naming, tab reuse):
- `com.google.Chrome` - Google Chrome
- `com.google.Chrome.beta` - Google Chrome Beta

**Basic support** (URL opening only):
- `com.apple.Safari` - Safari
- `org.mozilla.firefox` - Firefox
- `company.thebrowser.Browser` - Arc
- `com.brave.Browser` - Brave
- `com.microsoft.edgemac` - Microsoft Edge

## Permissions

Tabzilla requires the following macOS permissions:

- **Automation** - Required to control Chrome (window/tab management). macOS prompts on first use.
- **Accessibility** - Required for `sourceWindowTitle` matching. Grant in System Settings → Privacy & Security → Accessibility.

See [Troubleshooting](#troubleshooting) below for step-by-step instructions to reset stale permissions.

## Troubleshooting

These commands use the `tabz` alias defined in [CLI Usage](#cli-usage) above.

**Check daemon status and config validity**:
```bash
tabz status
```

This shows whether the daemon is running, which config file is loaded, and any configuration errors.

**Test rule matching** without opening a browser:
```bash
tabz test "https://example.com"
tabz test "https://example.com" --source-app "com.tinyspeck.slackmacgap"
```

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

**URLs don't open after reinstall** (Automation permission stale):

1. Open **System Settings → Privacy & Security → Automation**
2. Ensure Tabzilla has Google Chrome toggled ON
3. If missing, reset and restart:
   ```bash
   tccutil reset AppleEvents dev.tabzilla.Tabzilla
   ```
   Then relaunch Tabzilla and re-grant the permission when prompted.

**`sourceWindowTitle` shows "unknown"** (Accessibility permission stale):

1. Open **System Settings → Privacy & Security → Accessibility**
2. Ensure Tabzilla is listed and toggled ON
3. If reinstalled, remove Tabzilla from the list and re-add it (permissions can become stale after reinstall)

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for building from source, project structure, and architecture details.

## License

MIT
