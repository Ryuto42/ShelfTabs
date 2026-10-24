import AppKit
import ApplicationServices

final class WindowTracker {
    enum Event {
        case moved, resized, destroyed, titleChanged, focused, stateChanged
    }

    var onEvent: ((Event, CGWindowID) -> Void)?
    var onUnwatchedFocus: ((CGWindowID, AXUIElement) -> Void)?

    private struct Entry {
        let pid: pid_t
        let element: AXUIElement
    }

    private var entries: [CGWindowID: Entry] = [:]
    private var observers: [pid_t: AXObserver] = [:]

    private static let windowNotifications = [
        kAXMovedNotification,
        kAXResizedNotification,
        kAXUIElementDestroyedNotification,
        kAXTitleChangedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
    ]

    func pid(of windowID: CGWindowID) -> pid_t? {
        entries[windowID]?.pid
    }

    func element(of windowID: CGWindowID) -> AXUIElement? {
        entries[windowID]?.element
    }

    func windowIDs(forPID pid: pid_t) -> [CGWindowID] {
        entries.filter { $0.value.pid == pid }.map(\.key)
    }

    @discardableResult
    func watch(windowID: CGWindowID, pid: pid_t) -> Bool {
        if entries[windowID] != nil { return true }
        guard let element = AXWindow.element(pid: pid, id: windowID),
              let observer = observer(for: pid) else { return false }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in Self.windowNotifications {
            AXObserverAddNotification(observer, element, notification as CFString, refcon)
        }
        entries[windowID] = Entry(pid: pid, element: element)
        return true
    }

    func unwatch(windowID: CGWindowID) {
        guard let entry = entries.removeValue(forKey: windowID) else { return }
        if let observer = observers[entry.pid] {
            for notification in Self.windowNotifications {
                AXObserverRemoveNotification(observer, entry.element, notification as CFString)
            }
        }
        if !entries.values.contains(where: { $0.pid == entry.pid }) {
            dropObserver(for: entry.pid)
        }
    }

    func unwatchAll() {
        for windowID in Array(entries.keys) {
            unwatch(windowID: windowID)
        }
    }

    fileprivate func handle(element: AXUIElement, notification: String) {
        let event: Event
        switch notification {
        case kAXMovedNotification: event = .moved
        case kAXResizedNotification: event = .resized
        case kAXUIElementDestroyedNotification: event = .destroyed
        case kAXTitleChangedNotification: event = .titleChanged
        case kAXFocusedWindowChangedNotification: event = .focused
        default: event = .stateChanged
        }

        let windowID = AXWindow.id(of: element)
            ?? entries.first { CFEqual($0.value.element, element) }?.key
        guard let windowID else { return }
        guard entries[windowID] != nil else {
            if event == .focused { onUnwatchedFocus?(windowID, element) }
            return
        }
        onEvent?(event, windowID)
    }

    private func observer(for pid: pid_t) -> AXObserver? {
        if let observer = observers[pid] { return observer }

        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
            tracker.handle(element: element, notification: notification as String)
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return nil }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(
            observer,
            AXUIElementCreateApplication(pid),
            kAXFocusedWindowChangedNotification as CFString,
            refcon
        )
        observers[pid] = observer
        return observer
    }

    private func dropObserver(for pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}
