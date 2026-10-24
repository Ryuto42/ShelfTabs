import AppKit
import os

enum ShortcutAction {
    case previousTab
    case nextTab
    case layout(LayoutAction)

    var isTabSwitch: Bool {
        if case .layout = self { return false }
        return true
    }
}

private struct ShortcutKey: Hashable {
    let keyCode: Int
    let modifiers: UInt
}

// The tap runs on its own thread and never waits on AX or the main thread, so input is never delayed.
final class InputMonitor {
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint, CGEventFlags) -> Void)?
    var onMouseUp: ((CGEventFlags) -> Void)?
    var onFlagsChanged: ((CGEventFlags) -> Void)?
    var onShortcut: ((ShortcutAction) -> Void)?

    private struct Snapshot {
        var shortcuts: [ShortcutKey: ShortcutAction] = [:]
        var shelfPIDs: Set<pid_t> = []
        var frontmostPID: pid_t = 0
        var tap: CFMachPort?
        var runLoop: CFRunLoop?
    }

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let state = OSAllocatedUnfairLock(uncheckedState: Snapshot())
    private var tap: CFMachPort?
    private var defaultsObserver: NSObjectProtocol?

    init() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildShortcuts() }
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        stop()
    }

    var isRunning: Bool { tap != nil }

    func update(shelfPIDs: Set<pid_t>) {
        state.withLock { $0.shelfPIDs = shelfPIDs }
    }

    func update(frontmostPID: pid_t) {
        state.withLock { $0.frontmostPID = frontmostPID }
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        rebuildShortcuts()
        update(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)

        let types: [CGEventType] = [.keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<InputMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }

        state.withLock { $0.tap = tap }
        self.tap = tap
        let thread = Thread { [state] in
            let runLoop = CFRunLoopGetCurrent()
            state.withLock { $0.runLoop = runLoop }
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "ShelfTabs.InputMonitor"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    func stop() {
        let runLoop = state.withLock { snapshot in
            snapshot.tap = nil
            defer { snapshot.runLoop = nil }
            return snapshot.runLoop
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        tap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = state.withLock({ $0.tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            let location = event.location
            DispatchQueue.main.async { self.onMouseDown?(location) }
        case .leftMouseDragged:
            let location = event.location
            let flags = event.flags
            DispatchQueue.main.async { self.onMouseDragged?(location, flags) }
        case .leftMouseUp:
            let flags = event.flags
            DispatchQueue.main.async { self.onMouseUp?(flags) }
        case .flagsChanged:
            let flags = event.flags
            DispatchQueue.main.async { self.onFlagsChanged?(flags) }
        case .keyDown:
            let key = ShortcutKey(
                keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                modifiers: UInt(event.flags.rawValue) & Shortcut.relevantModifiers
            )
            let action: ShortcutAction? = state.withLock { snapshot in
                guard let action = snapshot.shortcuts[key], snapshot.frontmostPID != ownPID else { return nil }
                if action.isTabSwitch, !snapshot.shelfPIDs.contains(snapshot.frontmostPID) { return nil }
                return action
            }
            if let action {
                DispatchQueue.main.async { self.onShortcut?(action) }
                return nil
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func rebuildShortcuts() {
        var result: [ShortcutKey: ShortcutAction] = [:]
        func register(_ shortcut: Shortcut, _ action: ShortcutAction) {
            guard shortcut.isAssigned else { return }
            result[ShortcutKey(keyCode: shortcut.keyCode, modifiers: UInt(bitPattern: shortcut.modifiers) & Shortcut.relevantModifiers)] = action
        }
        for layout in LayoutAction.allCases {
            register(AppSettings.shortcut(for: layout), .layout(layout))
        }
        register(AppSettings.previousTab, .previousTab)
        register(AppSettings.nextTab, .nextTab)
        let shortcuts = result
        state.withLock { $0.shortcuts = shortcuts }
    }
}
