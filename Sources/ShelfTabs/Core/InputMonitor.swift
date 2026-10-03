import AppKit

final class InputMonitor {
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint, CGEventFlags) -> Void)?
    var onMouseUp: ((CGEventFlags) -> Void)?
    var onFlagsChanged: ((CGEventFlags) -> Void)?
    var onShortcut: ((Int) -> Bool)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

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
            if AppSettings.previousTab.matches(event), onShortcut?(-1) == true { return nil }
            if AppSettings.nextTab.matches(event), onShortcut?(1) == true { return nil }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}
