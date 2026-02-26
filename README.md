<img src="assets/tabzilla-banner.svg" height="80" align="right" />

# Tabzilla

[![CI](https://github.com/tabzilladev/tabzilla/actions/workflows/ci.yml/badge.svg)](https://github.com/tabzilladev/tabzilla/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/tabzilladev/tabzilla)](https://github.com/tabzilladev/tabzilla/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A native macOS app that registers as your default browser and routes URLs to specific browser windows based on rules you define.

## Features

- **Rule-based URL routing** - Route URLs based on regex patterns matching URL, source app, or source window title
- **Target named windows** - Open URLs in specific Chrome windows by name, creating them if needed
- **Reuse tabs** - Navigate existing tabs matching a pattern instead of opening duplicates
- **Focus tabs** - Focus existing tabs matching a pattern instead of opening duplicates
- **Follow tab** - Open tabs in the same window as other tabs matching a pattern
- **CLI interface** - Test rules, check status, etc. Useful for agents to develop & troubelshoot rules.

## Installation

### Homebrew (recommended)

```bash
brew install --cask tabzilladev/tap/tabzilla
```

### Set as default browser

After installing, set Tabzilla as your default browser:

1. Open **System Settings** > **Desktop & Dock** > **Default web browser**
2. Select **Tabzilla** from the dropdown

### Permissions

Tabzilla requires two macOS permissions:

- **Automation** - Required to control Chrome (window/tab management). macOS prompts on first use.
- **Accessibility** - Required for `sourceWindowTitle` matching. Grant in **System Settings → Privacy & Security → Accessibility**.

## Configuration

### Example

```yaml
version: 1

defaults:
  browser: com.google.Chrome
  # Open unmatched URLs in a window named "Default"
  # Chrome windows are identified by their *given name* (Menu Bar → Window → Name Window)
  window: Default

rules:
  # PRs opened from personal Slack: focus exact tab or open in the same window as tabs of the same PR, in Beta
  - name: personal-slack-pr
    sourceApp: ^com\.tinyspeck\.slackmacgap$
    sourceWindowTitle: Personal Slack
    url: github\.com/([^/]+/[^/]+)/pull/(\d+)(.*)
    browser: com.google.Chrome.beta
    focusTab: github\.com/\1/pull/\2\3$
    followTab: github\.com/\1/pull/\2

  # Other personal Slack links go to default window name, in Beta
  - name: slack-personal
    sourceApp: ^com\.tinyspeck\.slackmacgap$
    browser: com.google.Chrome.beta

  # PRs: focus exact tab or open in the same window as tabs of the same PR
  - name: github-pr
    url: github\.com/([^/]+/[^/]+)/pull/(\d+)(.*)
    focusTab: github\.com/\1/pull/\2\3$
    followTab: github\.com/\1/pull/\2

  # Google Docs/Sheets/Slides: navigate existing tab for the same document
  - name: google-workspace
    url: docs\.google\.com/(document|spreadsheets|presentation)/d/([^/]+)
    useTab: docs\.google\.com/\1/d/\2

  # Catch-all (uses defaults)
  - name: catch-all
    url: .*
```

Tabzilla searches for config in these locations (first found wins):

1. `~/.config/tabz/config.yaml`
2. `~/Library/Application Support/Tabzilla/config.yaml`
3. `~/.tabz.yaml`

### Rule Matching

Rules are evaluated in order; first match wins.

**Match conditions** (all must match if specified):
- `url` - Regex against the full URL
- `sourceApp` - Regex against bundle ID of the app that opened the link
- `sourceWindowTitle` - Regex against the frontmost window title of the source app

**Routing options**:
- `browser` - Bundle ID of target browser (default: `com.google.Chrome`)
- `window` - Name of target browser window (optional; omit to let browser decide)
- `useTab` - Find existing tab matching regex; focus it and navigate to the new URL
- `focusTab` - Find existing tab matching regex; focus it only (ignore incoming URL)
- `followTab` - Find existing tab matching regex; open new URL in a new tab in the same window

**Regex features**:
 
- `(?i)` - Case-insensitive matching
- `\1`, `\2` - Capture group references in `useTab`/`focusTab`/`followTab` patterns
- All matching uses ICU regex (NSRegularExpression) - lookahead, lookbehind, etc.

## How It Works

1. **URL Reception**: Tabzilla registers for `http`, `https`, `file`, `chrome`, and `chrome-extension` URL schemes. When the user clicks a link, macOS sends an Apple Event to Tabzilla. It also handles `.webloc` and `.url` shortcut files (delegated directly to the default browser).

2. **Source Detection**: Tabzilla captures the source app's bundle ID and attempts to read the frontmost window title (for Slack workspace detection, etc.).

3. **Rule Matching**: The URL and source info are matched against rules in order. First match wins.

4. **Window Targeting**: Chrome windows are identified by their **given name** (Menu Bar → Window → Name Window), which is distinct from the window title (derived from the active tab's page title; changes constantly). If no matching window exists, one is created.

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

## CLI Usage and Troubleshooting

The app binary can be invoked directly for CLI commands:

```bash
# Create an alias for convenience
alias tabz='/Applications/Tabzilla.app/Contents/MacOS/Tabzilla'

# Route a URL via rules and open in browser
tabz open "https://example.com"

# Test which rule matches a URL (dry run)
tabz test "https://github.com/org/repo/pull/123"
tabz test "https://github.com/org/repo/pull/123" \
  --source-app "com.tinyspeck.slackmacgap" \
  --source-window-title "Acme Corp"

# Check daemon status and config
tabz status

# Dump full daemon state as JSON (for tools/agents)
tabz dump

# Reload configuration
tabz reload

# Stop the daemon
tabz stop
```

**View logs**:

```bash
# Stream all Tabzilla logs (--info required; debug/info are suppressed by default)
log stream --predicate 'subsystem == "dev.tabzilla.Tabzilla"' --info
# Filter by component
log stream --predicate 'subsystem == "dev.tabzilla.Tabzilla" AND category == "executor"' --info
# Search recent history
log show --predicate 'subsystem == "dev.tabzilla.Tabzilla"' --info --last 1h
```

**URLs don't open after reinstall** (Automation permission stale):

1. Open **System Settings → Privacy & Security → Automation**
2. Ensure Tabzilla has Google Chrome toggled ON
3. If missing, reset, restart and re-grant the permission when prompted:
   ```bash
   tccutil reset AppleEvents dev.tabzilla.Tabzilla
   tabz stop
   tabz open "https://example.com"
   ```

**`sourceWindowTitle` shows "unknown"** (Accessibility permission stale):

1. Open **System Settings → Privacy & Security → Accessibility**
2. Ensure Tabzilla is listed and toggled ON
3. If reinstalled, remove Tabzilla from the list and re-add it (permissions can become stale after reinstall)

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for building from source, project structure, and architecture details.

## License

MIT
