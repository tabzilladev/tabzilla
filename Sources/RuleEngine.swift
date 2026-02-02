import Foundation

// MARK: - Data Structures

/// Input to the rule engine
struct RouteRequest {
    let url: URL
    let sourceApp: String?
    let sourceWindowTitle: String?
    let timestamp: Date
}

/// Output from the rule engine
struct RouteAction {
    let matchedRule: String?
    let rewrittenURL: URL
    let browser: String
    let windowTarget: WindowTarget?
    let tabActions: [TabAction]
}

struct WindowTarget {
    let name: String
}

/// Kind of tab action to perform
enum TabActionKind {
    case focus   // focusTab: focus existing tab, don't navigate
    case use     // useTab: focus and navigate existing tab
    case follow  // followTab: open new tab in same window as matched tab
}

struct TabAction {
    let pattern: String
    let kind: TabActionKind
}

// MARK: - Rule Engine

class RuleEngine {
    private let config: Config

    init(config: Config) {
        self.config = config
    }

    /// Route a request to an action
    func route(request: RouteRequest) -> RouteAction {
        // Find matching rule
        for rule in config.rules {
            if let action = tryMatch(rule: rule, request: request) {
                return action
            }
        }

        // No rule matched - use defaults
        return RouteAction(
            matchedRule: nil,
            rewrittenURL: request.url,
            browser: config.defaults.browser,
            windowTarget: config.defaults.window.map { WindowTarget(name: $0) },
            tabActions: []
        )
    }

    private func tryMatch(rule: Config.Rule, request: RouteRequest) -> RouteAction? {
        var captureGroups: [String] = []

        // Check URL pattern
        if let urlPattern = rule.url {
            guard let (matches, groups) = matchesRegex(urlPattern, against: request.url.absoluteString) else {
                return nil
            }
            if !matches { return nil }
            captureGroups = groups
        }

        // Check source app pattern
        if let sourceAppPattern = rule.sourceApp {
            guard let sourceApp = request.sourceApp else { return nil }
            guard let (matches, _) = matchesRegex(sourceAppPattern, against: sourceApp) else {
                return nil
            }
            if !matches { return nil }
        }

        // Check source window title pattern
        if let sourceWindowTitlePattern = rule.sourceWindowTitle {
            guard let sourceWindowTitle = request.sourceWindowTitle else { return nil }
            guard let (matches, _) = matchesRegex(sourceWindowTitlePattern, against: sourceWindowTitle) else {
                return nil
            }
            if !matches { return nil }
        }

        // All conditions matched - build action
        let browser = rule.browser ?? config.defaults.browser
        let windowTarget = (rule.window ?? config.defaults.window).map { WindowTarget(name: $0) }

        // Build tab actions in priority order: focusTab → useTab → followTab
        var tabActions: [TabAction] = []
        if let focusTabPattern = rule.focusTab {
            let substitutedPattern = substituteCaptures(focusTabPattern, with: captureGroups)
            tabActions.append(TabAction(pattern: substitutedPattern, kind: .focus))
        }
        if let useTabPattern = rule.useTab {
            let substitutedPattern = substituteCaptures(useTabPattern, with: captureGroups)
            tabActions.append(TabAction(pattern: substitutedPattern, kind: .use))
        }
        if let followTabPattern = rule.followTab {
            let substitutedPattern = substituteCaptures(followTabPattern, with: captureGroups)
            tabActions.append(TabAction(pattern: substitutedPattern, kind: .follow))
        }

        return RouteAction(
            matchedRule: rule.name ?? rule.url ?? "unnamed",
            rewrittenURL: request.url,
            browser: browser,
            windowTarget: windowTarget,
            tabActions: tabActions
        )
    }

    /// Match a regex pattern against a string
    /// Returns (matched, captureGroups) or nil if regex is invalid
    private func matchesRegex(_ pattern: String, against string: String) -> (Bool, [String])? {
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            let range = NSRange(string.startIndex..., in: string)
            guard let match = regex.firstMatch(in: string, options: [], range: range) else {
                return (false, [])
            }

            // Extract capture groups
            var groups: [String] = []
            for i in 0..<match.numberOfRanges {
                if let range = Range(match.range(at: i), in: string) {
                    groups.append(String(string[range]))
                } else {
                    groups.append("")
                }
            }

            return (true, groups)
        } catch {
            Logger.shared.log("Invalid regex pattern: \(pattern) - \(error)")
            return nil
        }
    }

    /// Substitute capture group references (\1, \2, etc.) with actual values
    /// Captured values are regex-escaped so they match literally in tab patterns
    private func substituteCaptures(_ pattern: String, with groups: [String]) -> String {
        var result = pattern

        // Replace \1, \2, etc. with regex-escaped captured groups
        for i in 1..<min(groups.count, 10) {
            let escapedGroup = NSRegularExpression.escapedPattern(for: groups[i])
            result = result.replacingOccurrences(of: "\\\(i)", with: escapedGroup)
        }

        return result
    }
}

// MARK: - Testing Support

extension RuleEngine {
    /// Test which rule matches a URL (for CLI test command)
    func testMatch(url: URL, sourceApp: String? = nil, sourceWindowTitle: String? = nil) -> RouteAction {
        let request = RouteRequest(
            url: url,
            sourceApp: sourceApp,
            sourceWindowTitle: sourceWindowTitle,
            timestamp: Date()
        )
        return route(request: request)
    }
}
