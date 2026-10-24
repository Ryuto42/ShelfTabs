import AppKit

class OverlayPanel: NSPanel {
    private(set) var isFadingOut = false

    init(size: NSSize, level: NSWindow.Level) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        worksWhenModal = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(duration: TimeInterval = 0.2, order: () -> Void) {
        let appearing = !isVisible || isFadingOut
        if !isVisible {
            alphaValue = 0
        }
        isFadingOut = false
        order()
        if appearing {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                animator().alphaValue = 1
            }
        }
    }

    func dismiss(duration: TimeInterval = 0.15, completion: (() -> Void)? = nil) {
        guard isVisible, !isFadingOut else { return }
        isFadingOut = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            animator().alphaValue = 0
        }, completionHandler: { [self] in
            // Holding self keeps a panel that was just discarded alive until it is ordered out.
            guard self.isFadingOut else { return }
            self.isFadingOut = false
            self.orderOut(nil)
            completion?()
        })
    }
}
