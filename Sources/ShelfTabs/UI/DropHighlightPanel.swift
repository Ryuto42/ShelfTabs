import AppKit

private final class HighlightView: NSView {
    let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 3
        applyColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        layer?.borderColor = resolvedCGColor(color)
        layer?.backgroundColor = resolvedCGColor(color.withAlphaComponent(0.15))
    }
}

final class DropHighlightPanel: NSPanel {
    init(color: NSColor = .controlAccentColor) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = HighlightView(color: color)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(axFrame: CGRect) {
        let theme = AppSettings.themeMode.appearance
        if appearance?.name != theme?.name {
            appearance = theme
        }
        setFrame(Geometry.nsRect(fromAX: axFrame), display: true)
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}
