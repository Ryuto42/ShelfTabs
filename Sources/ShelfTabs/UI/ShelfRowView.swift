import AppKit

struct TabInfo {
    let windowID: CGWindowID
    let title: String
    let appName: String
    let icon: NSImage?
    let isActive: Bool
}

class HoverRowView: NSView {
    static let height: CGFloat = 26

    var isActive = false
    var accent: NSColor = .controlAccentColor
    var highContrast = false
    private(set) var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    func hoverChanged() {}

    func applyColors() {
        let fill: NSColor?
        if isActive {
            fill = accent.withAlphaComponent(0.22)
        } else if isHovered {
            fill = NSColor.labelColor.withAlphaComponent(0.08)
        } else {
            fill = nil
        }
        layer?.backgroundColor = fill.map { resolvedCGColor($0) }
        layer?.borderWidth = isActive && highContrast ? 1.5 : 0
        layer?.borderColor = resolvedCGColor(.labelColor)
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        applyColors()
        hoverChanged()
        needsLayout = true
    }
}

final class ShelfAddRowView: HoverRowView {
    var onClick: (() -> Void)?

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "ウィンドウを追加")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "ウィンドウを追加")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        iconView.contentTintColor = .secondaryLabelColor
        addSubview(iconView)

        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .secondaryLabelColor
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        iconView.frame = NSRect(x: 8, y: (h - 16) / 2, width: 16, height: 16)
        let labelHeight = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 30, y: (h - labelHeight) / 2, width: max(bounds.width - 38, 0), height: labelHeight)
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
}

final class ReorderHandleView: NSView {
    var onBegan: (() -> Void)?
    var onMoved: ((NSEvent) -> Void)?
    var onEnded: (() -> Void)?

    private let imageView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "並べ替え")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        imageView.contentTintColor = .secondaryLabelColor
        addSubview(imageView)
        toolTip = "ドラッグで並べ替え"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        imageView.frame = bounds
    }

    override func mouseDown(with event: NSEvent) {
        onBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        onMoved?(event)
    }

    override func mouseUp(with event: NSEvent) {
        onEnded?()
    }
}

final class ShelfRowView: HoverRowView, NSDraggingSource {
    static let pasteboardType = NSPasteboard.PasteboardType("com.ryuto.shelftabs.tab")

    let windowID: CGWindowID
    var onSelect: ((CGWindowID) -> Void)?
    var onHoverSelect: ((CGWindowID) -> Void)?
    var onClose: ((CGWindowID) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: ((CGWindowID, NSPoint, NSDragOperation) -> Void)?
    var onReorderBegan: ((CGWindowID) -> Void)?
    var onReorderMoved: ((CGWindowID, NSEvent) -> Void)?
    var onReorderEnded: ((CGWindowID) -> Void)?
    var isReordering = false {
        didSet { hoverChanged() }
    }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let handle = ReorderHandleView()
    private var info: TabInfo?
    private var mouseDownEvent: NSEvent?
    private var hoverSelectWork: DispatchWorkItem?

    init(windowID: CGWindowID) {
        self.windowID = windowID
        super.init(frame: .zero)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.truncatesLastVisibleLine = true
        addSubview(titleLabel)

        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "タブを分離")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isHidden = true
        addSubview(closeButton)

        handle.isHidden = true
        handle.onBegan = { [weak self] in
            guard let self else { return }
            self.onReorderBegan?(self.windowID)
        }
        handle.onMoved = { [weak self] event in
            guard let self else { return }
            self.onReorderMoved?(self.windowID, event)
        }
        handle.onEnded = { [weak self] in
            guard let self else { return }
            self.onReorderEnded?(self.windowID)
        }
        addSubview(handle)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ info: TabInfo, style: BarStyle, accent: NSColor) {
        self.info = info
        self.accent = accent
        isActive = info.isActive
        highContrast = style == .solid(highContrast: true)

        iconView.image = info.icon
        toolTip = info.title.isEmpty ? info.appName : "\(info.title) — \(info.appName)"
        updateTitle()
        applyColors()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        iconView.frame = NSRect(x: 8, y: (h - 16) / 2, width: 16, height: 16)
        closeButton.frame = NSRect(x: bounds.width - 24, y: (h - 16) / 2, width: 16, height: 16)
        handle.frame = NSRect(x: closeButton.frame.minX - 20, y: (h - 16) / 2, width: 16, height: 16)

        let labelHeight = ceil(titleLabel.intrinsicContentSize.height)
        let right = isHovered || isReordering ? handle.frame.minX - 2 : bounds.width - 8
        titleLabel.frame = NSRect(x: 30, y: (h - labelHeight) / 2, width: max(right - 30, 0), height: labelHeight)
    }

    override func hoverChanged() {
        closeButton.isHidden = !isHovered || isReordering
        handle.isHidden = !(isHovered || isReordering)
        needsLayout = true
        hoverSelectWork?.cancel()
        hoverSelectWork = nil
        guard isHovered, !isActive, !isReordering else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isHovered, !self.isActive else { return }
            self.onHoverSelect?(self.windowID)
        }
        hoverSelectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    override func mouseDown(with event: NSEvent) {
        hoverSelectWork?.cancel()
        hoverSelectWork = nil
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent,
              hypot(event.locationInWindow.x - down.locationInWindow.x,
                    event.locationInWindow.y - down.locationInWindow.y) > 4 else { return }
        mouseDownEvent = nil

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(String(windowID), forType: Self.pasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: snapshot())
        onDragBegan?()
        let session = beginDraggingSession(with: [draggingItem], event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownEvent != nil else { return }
        mouseDownEvent = nil
        onSelect?(windowID)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnded?(windowID, screenPoint, operation)
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    @objc private func closeTapped() {
        onClose?(windowID)
    }

    private func updateTitle() {
        guard let info else { return }
        let text = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 11.5, weight: info.isActive ? .semibold : .regular)

        if info.title.isEmpty {
            text.append(NSAttributedString(string: info.appName, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        } else {
            text.append(NSAttributedString(string: info.title, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            text.append(NSAttributedString(string: " — \(info.appName)", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        titleLabel.attributedStringValue = text
    }

    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }
}
