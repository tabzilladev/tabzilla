import Foundation

// MARK: - Browser Snapshot Types

struct BrowserSnapshot: Encodable {
    let windows: [WindowSnapshot]
}

struct WindowSnapshot: Encodable {
    let id: String
    let name: String          // Chrome's givenName
    let tabCount: Int
    let tabs: [TabSnapshot]

    // Encode "name" as "givenName" for backwards compatibility with the dump JSON format
    enum CodingKeys: String, CodingKey {
        case id
        case name = "givenName"
        case tabCount
        case tabs
    }
}

struct TabSnapshot: Encodable {
    let id: String
    let index: Int            // 1-based (matches Chrome's activeTabIndex)
    let url: String
    let title: String
    let active: Bool
}

// MARK: - Factory

extension BrowserSnapshot {
    /// Convert raw `getAllWindows(forBundleId:)` dictionary output into a BrowserSnapshot.
    static func from(_ rawWindows: [NSDictionary]) -> BrowserSnapshot {
        let windows: [WindowSnapshot] = rawWindows.compactMap { w in
            guard let id = w["id"] as? String,
                  let givenName = w["givenName"] as? String,
                  let tabCount = w["tabCount"] as? Int,
                  let rawTabs = w["tabs"] as? [[String: Any]] else { return nil }
            let tabs: [TabSnapshot] = rawTabs.compactMap { t in
                guard let tabId = t["id"] as? String,
                      let index = t["index"] as? Int,
                      let url = t["url"] as? String,
                      let title = t["title"] as? String,
                      let active = t["active"] as? Bool else { return nil }
                return TabSnapshot(id: tabId, index: index, url: url, title: title, active: active)
            }
            return WindowSnapshot(id: id, name: givenName, tabCount: tabCount, tabs: tabs)
        }
        return BrowserSnapshot(windows: windows)
    }
}

// MARK: - Flat Tab View

extension BrowserSnapshot {
    struct FlatTab {
        let windowId: String
        let windowName: String
        let tabId: String
        let tabIndex: Int
        let url: String
    }

    func flatTabs() -> [FlatTab] {
        windows.flatMap { window in
            window.tabs.map { tab in
                FlatTab(
                    windowId: window.id,
                    windowName: window.name,
                    tabId: tab.id,
                    tabIndex: tab.index,
                    url: tab.url
                )
            }
        }
    }
}
