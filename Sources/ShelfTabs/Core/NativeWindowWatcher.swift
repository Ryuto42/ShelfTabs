import AppKit

// Watches only Finder / Preview for newly created windows.
final class NativeWindowWatcher {
    var onWindowCreated: ((AXUIElement, pid_t, Bool) -> Void)?

    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []

    deinit {
        stop()
    }

    func start() {
        if workspaceTokens.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            workspaceTokens = [
                center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                    self?.watch(app)
                },
                center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                    self?.unwatch(app.processIdentifier)
                },
            ]
        }
        for app in NSWorkspace.shared.runningApplications {
            watch(app)
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.forEach(center.removeObserver)
        workspaceTokens = []
        for pid in Array(observers.keys) {
            unwatch(pid)
        }
    }

    private func unwatch(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        NativeTabs.forget(pid: pid)
    }

    private func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil, NativeTabs.supports(pid: pid) else { return }
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<NativeWindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success else { return }
            watcher.onWindowCreated?(element, pid, NSEvent.pressedMouseButtons != 0)
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(observer, AXUIElementCreateApplication(pid), kAXWindowCreatedNotification as CFString, refcon) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }
}
