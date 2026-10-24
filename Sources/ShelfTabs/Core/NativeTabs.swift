import AppKit
import ApplicationServices

enum NativeTabs {
    private static let bundleIDs: Set<String> = ["com.apple.finder", "com.apple.Preview"]

    private enum Item: Hashable {
        case mergeAll, tabBar

        var menuTitles: Set<String> {
            switch self {
            case .mergeAll: ["ウインドウ", "ウィンドウ", "Window"]
            case .tabBar: ["表示", "View"]
            }
        }

        var identifiers: Set<String> {
            switch self {
            case .mergeAll: ["mergeAllWindows:"]
            case .tabBar: ["toggleTabBar:"]
            }
        }

        var titles: Set<String> {
            switch self {
            case .mergeAll: ["すべてのウインドウを結合", "すべてのウィンドウを結合", "Merge All Windows"]
            case .tabBar: showTabBarTitles.union(hideTabBarTitles)
            }
        }
    }

    private static let showTabBarTitles: Set<String> = ["タブバーを表示", "Show Tab Bar"]
    private static let hideTabBarTitles: Set<String> = ["タブバーを非表示", "Hide Tab Bar"]

    private static var cache: [pid_t: [Item: AXUIElement]] = [:]

    static func supports(pid: pid_t) -> Bool {
        guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return bundleIDs.contains(id)
    }

    static func forget(pid: pid_t) {
        cache.removeValue(forKey: pid)
    }

    static func canMergeAll(pid: pid_t) -> Bool {
        guard let item = menuItem(.mergeAll, pid: pid) else { return false }
        return AXWindow.attribute(item, kAXEnabledAttribute) ?? false
    }

    static func mergeAllWindows(pid: pid_t) -> Bool {
        guard let item = menuItem(.mergeAll, pid: pid) else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    static func showTabBar(pid: pid_t) -> Bool {
        guard let item = menuItem(.tabBar, pid: pid) else { return false }
        let title: String = AXWindow.attribute(item, kAXTitleAttribute) ?? ""
        if hideTabBarTitles.contains(title) { return true }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    private static func menuItem(_ kind: Item, pid: pid_t) -> AXUIElement? {
        if let cached = cache[pid]?[kind], matches(cached, kind) { return cached }
        guard let found = scan(kind, pid: pid) else {
            cache[pid]?.removeValue(forKey: kind)
            return nil
        }
        cache[pid, default: [:]][kind] = found
        return found
    }

    private static func scan(_ kind: Item, pid: pid_t) -> AXUIElement? {
        guard let menuBar: AXUIElement = AXWindow.attribute(AXWindow.application(pid), kAXMenuBarAttribute) else { return nil }
        let barItems: [AXUIElement] = AXWindow.attribute(menuBar, kAXChildrenAttribute) ?? []
        for barItem in barItems {
            let title: String = AXWindow.attribute(barItem, kAXTitleAttribute) ?? ""
            guard kind.menuTitles.contains(title),
                  let menu = (AXWindow.attribute(barItem, kAXChildrenAttribute) as [AXUIElement]?)?.first else { continue }
            let items: [AXUIElement] = AXWindow.attribute(menu, kAXChildrenAttribute) ?? []
            if let item = items.first(where: { matches($0, kind) }) { return item }
        }
        return nil
    }

    private static func matches(_ item: AXUIElement, _ kind: Item) -> Bool {
        if let identifier: String = AXWindow.attribute(item, kAXIdentifierAttribute), kind.identifiers.contains(identifier) {
            return true
        }
        let title: String = AXWindow.attribute(item, kAXTitleAttribute) ?? ""
        return kind.titles.contains(title)
    }
}
