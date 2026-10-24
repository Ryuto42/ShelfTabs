import AppKit

// Selects a Finder / Preview window tab when the pointer rests on it.
// The mouse monitor exists only while one of those apps is frontmost; hit tests run off the main thread.
final class NativeTabHover {
    private static let delay: TimeInterval = 0.1
    private static let interval: TimeInterval = 0.05

    private let queue = DispatchQueue(label: "ShelfTabs.NativeTabHover", qos: .userInteractive)
    private var monitor: Any?
    private var pid: pid_t = 0
    private var checking = false
    private var checkScheduled = false
    private var dirty = false
    private var candidate: AXUIElement?
    private var pending: DispatchWorkItem?

    deinit {
        stop()
    }

    func update(frontmost app: NSRunningApplication?) {
        let pid = app?.processIdentifier ?? 0
        guard AppSettings.hoverNativeTabs, AXIsProcessTrusted(), NativeTabs.supports(pid: pid) else {
            stop()
            return
        }
        if self.pid != pid { reset() }
        self.pid = pid
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.mouseMoved()
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pid = 0
        reset()
    }

    private func reset() {
        pending?.cancel()
        pending = nil
        candidate = nil
    }

    private func mouseMoved() {
        dirty = true
        guard !checking, !checkScheduled else { return }
        checkScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.interval) { [weak self] in
            self?.checkScheduled = false
            self?.check()
        }
    }

    private func check() {
        guard dirty, !checking, pid != 0 else { return }
        dirty = false
        guard NSEvent.pressedMouseButtons == 0 else {
            reset()
            return
        }
        checking = true
        let pid = pid
        let point = Geometry.axPoint(fromNS: NSEvent.mouseLocation)
        queue.async { [weak self] in
            let tab = Self.unselectedTab(pid: pid, at: point)
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                if self.pid == pid { self.found(tab) }
                if self.dirty { self.mouseMoved() }
            }
        }
    }

    private func found(_ tab: AXUIElement?) {
        guard let tab else {
            reset()
            return
        }
        if let candidate, CFEqual(candidate, tab) { return }
        reset()
        candidate = tab
        let pid = pid
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pid == pid, NSEvent.pressedMouseButtons == 0 else { return }
            let point = Geometry.axPoint(fromNS: NSEvent.mouseLocation)
            self.queue.async {
                guard let current = Self.unselectedTab(pid: pid, at: point), CFEqual(current, tab) else { return }
                AXWindow.press(tab)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    // Only radio buttons of a window's own tab bar count, so inspector tabs and segmented controls are ignored.
    private static func unselectedTab(pid: pid_t, at point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(element, &hitPID) == .success, hitPID == pid else { return nil }
        for _ in 0..<2 where role(of: element) != kAXRadioButtonRole {
            guard let parent: AXUIElement = AXWindow.attribute(element, kAXParentAttribute) else { return nil }
            element = parent
        }
        guard role(of: element) == kAXRadioButtonRole, !AXWindow.isSelectedTab(element),
              let group: AXUIElement = AXWindow.attribute(element, kAXParentAttribute),
              role(of: group) == kAXTabGroupRole,
              let window: AXUIElement = AXWindow.attribute(group, kAXWindowAttribute),
              let parent: AXUIElement = AXWindow.attribute(group, kAXParentAttribute),
              CFEqual(parent, window) || (AXWindow.attribute(parent, kAXParentAttribute) as AXUIElement?).map({ CFEqual($0, window) }) == true
        else { return nil }
        return element
    }

    private static func role(of element: AXUIElement) -> String? {
        AXWindow.attribute(element, kAXRoleAttribute)
    }
}
