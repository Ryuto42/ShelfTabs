import AppKit

class OverlayPanel: NSPanel {
    private var fadingOut = false

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
        let appearing = !isVisible || fadingOut
        if !isVisible {
            alphaValue = 0
        }
        fadingOut = false
        order()
        if appearing {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                animator().alphaValue = 1
            }
        }
    }

    func dismiss(duration: TimeInterval = 0.15, completion: (() -> Void)? = nil) {
        guard isVisible, !fadingOut else { return }
        fadingOut = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.fadingOut else { return }
            self.fadingOut = false
            self.orderOut(nil)
            completion?()
        })
    }
}
