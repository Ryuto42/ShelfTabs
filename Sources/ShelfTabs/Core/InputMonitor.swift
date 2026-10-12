import AppKit

enum ShortcutAction {
    case previousTab
    case nextTab
    case layout(LayoutAction)
}

private struct ShortcutKey: Hashable {
    let keyCode: Int
    let modifiers: UInt
}

final class InputMonitor {
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint, CGEventFlags) -> Void)?
    var onMouseUp: ((CGEventFlags) -> Void)?
    var onFlagsChanged: ((CGEventFlags) -> Void)?
    var onShortcut: ((ShortcutAction) -> Bool)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var shortcuts: [ShortcutKey: ShortcutAction] = [:]
    private var defaultsObserver: NSObjectProtocol?

    init() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildShortcuts() }
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        rebuildShortcuts()

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

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            onMouseDown?(event.location)
        case .leftMouseDragged:
            onMouseDragged?(event.location, event.flags)
        case .leftMouseUp:
            onMouseUp?(event.flags)
        case .flagsChanged:
            onFlagsChanged?(event.flags)
        case .keyDown:
            let key = ShortcutKey(
                keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                modifiers: UInt(event.flags.rawValue) & Shortcut.relevantModifiers
            )
            if let action = shortcuts[key], onShortcut?(action) == true { return nil }
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
        shortcuts = result
    }
}
