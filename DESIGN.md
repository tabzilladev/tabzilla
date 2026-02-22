# Tabzilla Design Document

## Overview

This document covers technical design, architecture decisions, and rationale. See [README.md](README.md) for user-facing documentation.

## Prior Art

| App | Approach | Config Method | Strengths | Limitations |
|-----|----------|---------------|-----------|-------------|
| **Finicky** | JS rule engine | `~/.finicky.js` | Most powerful, regex, URL rewriting | Requires JS knowledge |
| **Browserosaurus** | Manual picker | UI popup | Simple, no config | No automation, archived |
| **BrowserRouter** | Focus-based | UI prefs | Automatic, follows focus | No rule-based routing |
| **Objektiv** | Hotkey switcher | Status bar | Lightweight | No URL-based rules |
| **chrome-cli** | CLI tool | Command args | Window/tab management, Scripting Bridge | No window naming |

**Design choice**: Take inspiration from Finicky's rule engine but use YAML config (simpler, no JS required).

## Technical Architecture

### Default Browser Registration
- **Info.plist**: Declares `CFBundleURLTypes` with `http`, `https`, and `file` schemes
- **URL Handling**: `NSAppleEventManager` handler for `kAEGetURL` events
- **Document Types**: `CFBundleDocumentTypes` for:
  - `public.html`/`public.xhtml` (required to appear in default browser picker)
  - `com.apple.internet-location` (`.webloc` files)
  - `com.microsoft.internet-shortcut` (`.url` files)
- **Shortcut Files**: `.webloc` and `.url` files are delegated directly to the default browser (bypass rule matching)
- **Background Agent**: `LSUIElement = true` (no dock icon)

### Browser Control

| Feature | Method | Status |
|---------|--------|--------|
| Open URL in specific browser | `NSWorkspace.open()` | Works |
| Open in named window | Scripting Bridge `givenName` + `objectWithID:` | Works |
| Tab reuse (useTab) | Find tab by URL regex, navigate to new URL | Works |
| Tab focus (focusTab) | Find tab by URL regex, focus without navigating | Works |
| Tab follow (followTab) | Find tab by URL regex, open new tab in same window | Works |
| Query window's profile | Not exposed in Scripting Bridge | Not possible |
| Open in tab group | Chrome Extension API only | Not in MVP |

### Window Targeting

Chrome windows have two name-related properties:
- `name` - The window title (derived from active tab's page title)
- `givenName` - A user-assignable name that persists independently of tab titles

**Implementation**: Uses Objective-C Scripting Bridge via `ChromeController` class.

## Data Flow

```
URL Click → Apple Event → RouteRequest → RuleEngine → RouteAction → Executor → [Scripting Bridge] → Browser
          ╰─── macOS ──╯╰─────────────────────────── Tabzilla ───────────────────────────────────╯

Shortcut files (.webloc/.url) → Apple Event → Delegate to default browser (bypass rules)
          ╰──────────── macOS ─────────────╯╰──────────────── Tabzilla ──────────────────╯
```

### RouteRequest (Input)
```swift
struct RouteRequest {
    let url: URL                      // The URL to open
    let sourceApp: String?            // Bundle ID of app that sent the URL
    let sourceWindowTitle: String?    // Frontmost window title of source app
    let timestamp: Date               // When the request was received
}
```

### RouteAction (Output)
```swift
struct RouteAction {
    let matchedRule: String?          // Name of rule that matched (nil if default)
    let rewrittenURL: URL             // URL after rewrite rules applied
    let browser: String               // Bundle ID (e.g., "com.google.Chrome")
    let windowTarget: WindowTarget?   // Window targeting details
    let tabActions: [TabAction]       // focusTab/useTab/followTab actions, in priority order
}
```

## Configuration Design

See [README.md](README.md) for config file locations, syntax, and examples.

### Why YAML (not JavaScript)
- Simpler than Finicky's JavaScript config; no runtime or JS knowledge required
- Sufficient for regex-based rule matching
- Human-readable and versionable in dotfiles

### Search Path Design
Three locations are checked in order, covering XDG convention (`~/.config/tabz/`), macOS convention (`~/Library/Application Support/Tabzilla/`), and a simple dotfile fallback (`~/.tabz.yaml`). First found wins, so users can pick whichever convention fits their workflow.

### FileWatcher Design
`ConfigurationManager` uses `DispatchSource.makeFileSystemObjectSource` to watch the config file for writes. Atomic saves (write-to-temp + rename) are handled by also watching the parent directory for `.rename` events, then re-establishing the file watch.

### First-Match-Wins Rationale
Rules are evaluated in order and the first matching rule wins. This mirrors `iptables`/`nginx` conventions and makes precedence predictable: specific rules go first, catch-all last.

### ICU Regex Choice
All matching uses `NSRegularExpression` (ICU regex). ICU is already available on-platform, supports full Unicode, and provides capture groups (`\1`, `\2`) that enable dynamic patterns in `useTab`/`focusTab`/`followTab`.

## CLI Design

See [README.md](README.md) for the full command reference.

CLI subcommands are implemented with [ArgumentParser](https://github.com/apple/swift-argument-parser). `reload` sends `SIGHUP` to the daemon process; `quit` sends `SIGTERM`. The `open` subcommand routes a URL through the rule engine and opens it in the target browser, identical to a live URL click. The `dump` subcommand serializes full daemon state as JSON for use by tools and agents.

## Key Implementation Decisions

### 1. Scripting Bridge (not AppleScript)
- Type-safe Objective-C API generated from Chrome's scripting dictionary
- Faster than subprocess invocation
- More debuggable than string-based AppleScript
- Requires Objective-C, but Xcode build handles this

### 2. `objectWithID:` for Stable References
- **Critical**: Iterating `chrome.windows` or `window.tabs` gives proxy objects that don't work reliably
- Setting properties like `index` on iterated proxies silently fails
- **Solution**: Find window/tab ID by iterating, then use `objectWithID:` for a stable reference:
  - `[[chrome windows] objectWithID:windowId]` for windows
  - `[[window tabs] objectWithID:tabId]` for tabs
- This applies to all Scripting Bridge operations (window focus, tab navigation, etc.)
- Discovered through extensive debugging - the Scripting Bridge documentation doesn't mention this limitation

### 3. Window Matching by givenName
- Uses case-insensitive exact match (not prefix match)
- Creates new window with specified `givenName` if no match found
- `givenName` persists independently of tab titles

### 4. YAML Config (not JavaScript)
- Simpler than Finicky's JavaScript config
- No runtime required
- Sufficient for regex-based matching

### 5. Dual Build System
- **Xcode**: Required for proper app bundle with URL scheme registration and Obj-C support
- **SPM**: Used for fast test iteration (but doesn't include Obj-C files)
- App is copied from DerivedData during install

### 6. Headless Daemon
- Runs as `LSUIElement` with no UI
- Config changes detected via file watching
- CLI provides control interface

## Future Enhancements (v1.1+)

- URL rewriters (force HTTPS, strip tracking params)
- Menu bar icon (optional)
- Chrome profile support (via `--profile-directory`)
- Tab group support (requires Chrome extension)
- iCloud config sync
