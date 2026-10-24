import AppKit
import ApplicationServices
import Darwin

private typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

// Private API resolved at runtime (RTLD_DEFAULT = -2) so a missing symbol degrades instead of failing to launch.
private let axGetWindow: GetWindowFunction? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(symbol, to: GetWindowFunction.self)
}()

enum Geometry {
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func nsRect(fromAX rect: CGRect) -> NSRect {
        NSRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func axPoint(fromNS point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    static func intersectsAnyScreen(axRect rect: CGRect) -> Bool {
        let ns = nsRect(fromAX: rect)
        return NSScreen.screens.contains { $0.frame.intersects(ns) }
    }

    static func axRect(fromNS rect: NSRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // macOS keeps part of a window on screen, so leave a 1px sliver in a corner that no other display touches.
    static func hidingOrigin(for frame: CGRect) -> CGPoint {
        let screens = NSScreen.screens.map { axRect(fromNS: $0.frame) }
        let home = axRect(fromNS: (screen(containingAX: frame) ?? NSScreen.main)?.frame ?? .zero)
        let ordered = [home] + screens.filter { $0 != home }
        let candidates = ordered.flatMap { screen in
            [
                (screen, CGPoint(x: screen.maxX - 1, y: screen.maxY - 1)),
                (screen, CGPoint(x: screen.minX - frame.width + 1, y: screen.maxY - 1)),
            ]
        }
        return candidates.first { screen, origin in
            let rect = CGRect(origin: origin, size: frame.size).insetBy(dx: 1, dy: 1)
            return !screens.contains { $0 != screen && $0.intersects(rect) }
        }?.1 ?? CGPoint(x: home.maxX - 1, y: home.maxY - 1)
    }

    static func clampedIntoVisibleScreen(_ rect: CGRect) -> CGRect {
        let screen = NSScreen.screens.max { a, b in
            area(axRect(fromNS: a.frame).intersection(rect)) < area(axRect(fromNS: b.frame).intersection(rect))
        }
        let chosen = screen.flatMap { area(axRect(fromNS: $0.frame).intersection(rect)) > 0 ? $0 : nil } ?? NSScreen.main ?? screen
        guard let chosen else { return rect }
        let visible = axRect(fromNS: chosen.visibleFrame)
        let size = CGSize(width: min(rect.width, visible.width), height: min(rect.height, visible.height))
        return CGRect(
            x: min(max(rect.minX, visible.minX), visible.maxX - size.width),
            y: min(max(rect.minY, visible.minY), visible.maxY - size.height),
            width: size.width,
            height: size.height
        )
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    static func screen(containingAX rect: CGRect) -> NSScreen? {
        let ns = nsRect(fromAX: rect)
        let center = NSPoint(x: ns.midX, y: ns.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.first { $0.frame.intersects(ns) }
            ?? NSScreen.main
    }
}

enum AXWindow {
    static let readTimeout: Float = 0.3

    static func id(of element: AXUIElement) -> CGWindowID? {
        guard let axGetWindow else { return nil }
        var windowID = CGWindowID(0)
        guard axGetWindow(element, &windowID) == .success, windowID != 0 else { return nil }
        return windowID
    }

    static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, readTimeout)
        return app
    }

    static func element(pid: pid_t, id: CGWindowID) -> AXUIElement? {
        windows(pid: pid).first { Self.id(of: $0) == id }
    }

    static func windows(pid: pid_t) -> [AXUIElement] {
        attribute(application(pid), kAXWindowsAttribute) ?? []
    }

    static func focusedWindowID(pid: pid_t) -> CGWindowID? {
        let app = application(pid)
        guard let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute) else { return nil }
        return id(of: window)
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = attribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func setFrame(_ frame: CGRect, of element: AXUIElement) {
        setSize(frame.size, of: element)
        setPosition(frame.origin, of: element)
        setSize(frame.size, of: element)
    }

    static func setPosition(_ position: CGPoint, of element: AXUIElement) {
        var value = position
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, axValue)
    }

    static func setSize(_ size: CGSize, of element: AXUIElement) {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axValue)
    }

    static func title(of element: AXUIElement) -> String {
        attribute(element, kAXTitleAttribute) ?? ""
    }

    static func isMinimized(_ element: AXUIElement) -> Bool {
        attribute(element, kAXMinimizedAttribute) ?? false
    }

    static func setMinimized(_ minimized: Bool, of element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, minimized as CFBoolean)
    }

    static func isFullScreen(_ element: AXUIElement) -> Bool {
        attribute(element, "AXFullScreen") ?? false
    }

    static func isStandard(_ element: AXUIElement) -> Bool {
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        return subrole == kAXStandardWindowSubrole as String
    }

    static func hasZoomButton(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, "AXFullScreenButton" as CFString, &value) == .success
            || AXUIElementCopyAttributeValue(element, kAXZoomButtonAttribute as CFString, &value) == .success
    }

    static func focus(_ element: AXUIElement, pid: pid_t) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    static func raise(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    static func tabButtons(of window: AXUIElement) -> [AXUIElement]? {
        guard let group = tabGroup(in: window, depth: 2) else { return nil }
        return attribute(group, kAXTabsAttribute)
            ?? (attribute(group, kAXChildrenAttribute) ?? []).filter {
                (attribute($0, kAXRoleAttribute) as String?) == kAXRadioButtonRole as String
            }
    }

    static func isSelectedTab(_ button: AXUIElement) -> Bool {
        (attribute(button, kAXValueAttribute) as NSNumber?)?.intValue == 1
    }

    static func press(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    private static func tabGroup(in element: AXUIElement, depth: Int) -> AXUIElement? {
        let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
        if let group = children.first(where: { (attribute($0, kAXRoleAttribute) as String?) == kAXTabGroupRole as String }) {
            return group
        }
        guard depth > 1 else { return nil }
        for child in children {
            if let group = tabGroup(in: child, depth: depth - 1) { return group }
        }
        return nil
    }

    static func trafficLightsFrame(of window: AXUIElement) -> CGRect? {
        let names = [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute]
        let frames = names.compactMap { name -> CGRect? in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, name as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return frame(of: value as! AXUIElement)
        }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let ownerName: String
    let bounds: CGRect
    let layer: Int
    let alpha: Double
    let isOnScreen: Bool
}

enum WindowList {
    static func copy(onScreenOnly: Bool) -> [WindowInfo] {
        let options: CGWindowListOption = onScreenOnly
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionAll]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap(info(from:))
    }

    private static func info(from entry: [String: Any]) -> WindowInfo? {
        guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
              let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
              let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
        return WindowInfo(
            id: id,
            pid: pid,
            ownerName: entry[kCGWindowOwnerName as String] as? String ?? "",
            bounds: bounds,
            layer: entry[kCGWindowLayer as String] as? Int ?? 0,
            alpha: entry[kCGWindowAlpha as String] as? Double ?? 1,
            isOnScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false
        )
    }

    static func bounds(of id: CGWindowID) -> CGRect? {
        describe([id]).first?.bounds
    }

    static func describe(_ ids: [CGWindowID]) -> [WindowInfo] {
        guard !ids.isEmpty else { return [] }
        var values = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(kCFAllocatorDefault, &values, values.count, nil),
              let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else { return [] }
        return list.compactMap(info(from:))
    }

    static func isCandidate(_ info: WindowInfo) -> Bool {
        info.layer == 0
            && info.alpha > 0
            && info.pid != ProcessInfo.processInfo.processIdentifier
            && info.bounds.width >= 120
            && info.bounds.height >= 60
    }
}
