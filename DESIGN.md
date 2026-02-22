# Tabzilla Design Document

## Overview

Tabzilla is a native macOS application that registers as the system's default browser and routes URLs to specific browsers/windows based on user-defined rules. The key feature is routing URLs to specific **named browser windows** (creating them if needed), enabling project-based and work/personal separation workflows.

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

**Chrome Bundle IDs**:
- Chrome: `com.google.Chrome`
- Chrome Beta: `com.google.Chrome.beta`

### Window Targeting

Chrome windows have two name-related properties:
- `name` - The window title (derived from active tab's page title)
- `givenName` - A user-assignable name that persists independently of tab titles

**Implementation**: Uses Objective-C Scripting Bridge via `ChromeController` class.

## Data Flow

```
URL Click → Apple Event → RouteRequest → RuleEngine → RouteAction → Executor → Browser
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
    let tabAction: TabAction?         // useTab or focusTab details
}
```

## Configuration

### File Locations (searched in order)
1. `~/.config/tabz/config.yaml`
2. `~/Library/Application Support/Tabzilla/config.yaml`
3. `~/.tabz.yaml`

### Example Config
```yaml
version: 1

defaults:
  browser: com.google.Chrome
  window: Default

rules:
  # Slack workspace routing
  - sourceApp: ^com\.tinyspeck\.slackmacgap$
    sourceWindowTitle: (?i)work
    window: Work

  # Domain-based routing
  - url: (?i)corp\.example\.com
    window: Work

  # Tab reuse for Google Docs
  - url: docs\.google\.com/document/d/([^/]+)
    useTab: docs\.google\.com/document/d/\1

  # Catch-all
  - url: .*

logging:
  enabled: true
  path: ~/Library/Logs/Tabzilla/tabz.log
```

### Matching Rules
- All matching uses ICU regex (`NSRegularExpression`)
- Matchers: `url`, `sourceApp` (bundle ID), `sourceWindowTitle`
- All conditions are AND'ed; omitted conditions match anything
- Rules evaluated in order; first match wins

### Tab Actions
- `useTab: <pattern>` - Find matching tab, focus it, navigate to new URL
- `focusTab: <pattern>` - Find matching tab, focus it without navigating
- `followTab: <pattern>` - Find matching tab, open new URL in a new tab in the same window
- Use `\1`, `\2` to reference capture groups from URL pattern

## CLI Commands

| Command | Description |
|---------|-------------|
| `tabz open <url>` | Route URL via rules and open in browser |
| `tabz test <url>` | Show which rule matches (dry run) |
| `tabz status` | Show daemon status and configuration |
| `tabz reload` | Signal daemon to reload config (SIGHUP) |
| `tabz quit` | Stop the daemon (SIGTERM) |

## Permissions Required

1. **Automation**: System Settings → Privacy & Security → Automation → Tabzilla → Google Chrome
2. **Accessibility**: System Settings → Privacy & Security → Accessibility → Tabzilla (required for `sourceWindowTitle` matching)
3. After reinstalling, permissions must be re-granted (macOS tracks by code signature)
4. Reset Automation with: `tccutil reset AppleEvents dev.tabzilla.Tabzilla`

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
