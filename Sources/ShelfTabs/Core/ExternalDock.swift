import AppKit

enum ExternalDock {
    enum Status: Equatable {
        case notConfigured
        case notRunning
        case none
        case hidden(edge: ExternalDockEdge, margin: CGFloat)
        case shown(edge: ExternalDockEdge, thickness: CGFloat)
    }

    private static let cacheLifetime: TimeInterval = 0.5
    private static let rescanInterval: TimeInterval = 3
    private static let minimumSize: CGFloat = 16

    private static var cache: [String: (time: TimeInterval, status: Status)] = [:]
    private static var windowIDs: [CGWindowID] = []
    private static var windowPID: pid_t?
    private static var lastScan: TimeInterval = -.infinity
    private static var published: [String: (edge: ExternalDockEdge, inset: CGFloat, autoHide: Bool)]?
    private static var publishedBundleID: String?
    private static var publishedObserver: NSObjectProtocol?
    private static var rememberedEdges: [String: String] = UserDefaults.standard.dictionary(forKey: AppSettings.Key.externalDockEdges) as? [String: String] ?? [:]

    static func usableFrame(for screen: NSScreen) -> CGRect {
        let base = Geometry.axRect(fromNS: screen.visibleFrame)
        let full = Geometry.axRect(fromNS: screen.frame)
        let edge: ExternalDockEdge
        let reserve: CGFloat
        switch status(for: screen) {
        case .notConfigured, .notRunning, .none:
            return base
        case .shown(let shownEdge, let thickness):
            edge = shownEdge
            reserve = thickness + AppSettings.externalDockShownMargin
        case .hidden(let hiddenEdge, let margin):
            edge = hiddenEdge
            reserve = margin
        }

        let area: CGRect
        switch edge {
        case .bottom: area = CGRect(x: full.minX, y: full.minY, width: full.width, height: full.height - reserve)
        case .top: area = CGRect(x: full.minX, y: full.minY + reserve, width: full.width, height: full.height - reserve)
        case .left: area = CGRect(x: full.minX + reserve, y: full.minY, width: full.width - reserve, height: full.height)
        case .right: area = CGRect(x: full.minX, y: full.minY, width: full.width - reserve, height: full.height)
        }
        let result = area.intersection(base)
        return result.isNull || result.width <= 0 || result.height <= 0 ? base : result
    }

    static var usesPublishedData: Bool { publishedAreas() != nil }

    static func status(for screen: NSScreen, fresh: Bool = false) -> Status {
        let bundleID = AppSettings.externalDockBundleID
        if !bundleID.isEmpty, NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { return .notRunning }
        if let areas = publishedAreas() {
            guard let area = areas[screenID(for: screen)] else { return .none }
            return area.autoHide
                ? .hidden(edge: area.edge, margin: AppSettings.externalDockHiddenMargin)
                : .shown(edge: area.edge, thickness: area.inset)
        }
        let now = ProcessInfo.processInfo.systemUptime
        let key = displayKey(for: screen)
        if !fresh, let cached = cache[key], now - cached.time < cacheLifetime { return cached.status }
        let status = detect(on: screen, key: key, now: now, fresh: fresh)
        cache[key] = (now, status)
        return status
    }

    static func resetRememberedEdges() {
        rememberedEdges = [:]
        cache = [:]
        UserDefaults.standard.removeObject(forKey: AppSettings.Key.externalDockEdges)
    }

    private static func screenID(for screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { "\($0)" } ?? screen.localizedName
    }

    private static func publishedAreas() -> [String: (edge: ExternalDockEdge, inset: CGFloat, autoHide: Bool)]? {
        let bundleID = AppSettings.externalDockBundleID
        guard !bundleID.isEmpty else { return nil }
        if publishedObserver == nil {
            publishedObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.ryuto.GlassDock.reservedAreasChanged"), object: nil, queue: .main
            ) { _ in
                publishedBundleID = nil
                cache = [:]
            }
        }
        if publishedBundleID == bundleID { return published }

        CFPreferencesAppSynchronize(bundleID as CFString)
        var parsed: [String: (edge: ExternalDockEdge, inset: CGFloat, autoHide: Bool)]?
        if let raw = CFPreferencesCopyAppValue("reservedAreas" as CFString, bundleID as CFString) as? [String: [String: Any]] {
            var areas: [String: (edge: ExternalDockEdge, inset: CGFloat, autoHide: Bool)] = [:]
            for (id, entry) in raw {
                guard let edge = (entry["edge"] as? String).flatMap(ExternalDockEdge.init(rawValue:)) else { continue }
                areas[id] = (edge, CGFloat((entry["inset"] as? NSNumber)?.doubleValue ?? 0), (entry["autoHide"] as? NSNumber)?.boolValue ?? false)
            }
            parsed = areas
        }
        published = parsed
        publishedBundleID = bundleID
        cache = [:]
        return parsed
    }

    private static func displayKey(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) as String? else { return screen.localizedName }
        return string
    }

    private static func detect(on screen: NSScreen, key: String, now: TimeInterval, fresh: Bool) -> Status {
        let bundleID = AppSettings.externalDockBundleID
        guard !bundleID.isEmpty else { return .notConfigured }
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier else {
            return .notRunning
        }

        let full = Geometry.axRect(fromNS: screen.frame)
        var dock = CGRect.null
        for window in dockWindows(pid: pid, now: now, fresh: fresh) {
            guard window.isOnScreen, window.alpha > 0, window.bounds.intersects(full),
                  window.bounds.width >= minimumSize, window.bounds.height >= minimumSize else { continue }
            dock = dock.union(window.bounds.intersection(full))
        }

        if !dock.isNull {
            let distances: [(ExternalDockEdge, CGFloat)] = [
                (.bottom, full.maxY - dock.maxY),
                (.top, dock.minY - full.minY),
                (.left, dock.minX - full.minX),
                (.right, full.maxX - dock.maxX),
            ]
            let edge = distances.min { $0.1 < $1.1 }?.0 ?? .bottom
            let thickness: CGFloat
            switch edge {
            case .bottom: thickness = full.maxY - dock.minY
            case .top: thickness = dock.maxY - full.minY
            case .left: thickness = dock.maxX - full.minX
            case .right: thickness = full.maxX - dock.minX
            }
            if rememberedEdges[key] != edge.rawValue {
                rememberedEdges[key] = edge.rawValue
                UserDefaults.standard.set(rememberedEdges, forKey: AppSettings.Key.externalDockEdges)
            }
            return .shown(edge: edge, thickness: max(thickness, 0))
        }

        guard let edge = rememberedEdges[key].flatMap(ExternalDockEdge.init(rawValue:)) else { return .none }
        return .hidden(edge: edge, margin: AppSettings.externalDockHiddenMargin)
    }

    private static func dockWindows(pid: pid_t, now: TimeInterval, fresh: Bool) -> [WindowInfo] {
        if pid != windowPID {
            windowPID = pid
            windowIDs = []
        }
        let known = WindowList.describe(windowIDs)
        let needsScan = windowIDs.isEmpty || !known.contains { $0.isOnScreen }
        guard needsScan, fresh || now - lastScan >= rescanInterval else { return known }

        lastScan = now
        let scanned = WindowList.copy(onScreenOnly: false).filter { $0.pid == pid }
        windowIDs = scanned.map(\.id)
        return scanned
    }
}
