import AppKit

private final class AccentDotView: NSView {
    var color: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

final class ShelfPopupView: NSView {
    static let width: CGFloat = 264
    private static let padding: CGFloat = 6
    private static let headerHeight: CGFloat = 22
    private static let addGap: CGFloat = 4

    let shelfID: UUID
    weak var delegate: ShelfButtonDelegate?
    var onDismissRequest: (() -> Void)?
    var onStateChange: (() -> Void)?
    var isHovered = false

    private(set) var isBusy = false {
        didSet { if isBusy != oldValue { onStateChange?() } }
    }

    private let background: AdaptiveBackground
    private let dot = AccentDotView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let addRow = ShelfAddRowView()
    private var rows: [CGWindowID: ShelfRowView] = [:]
    private var reorderingID: CGWindowID?
    private var tabs: [TabInfo] = []
    private var name = ""
    private var accent: NSColor = .controlAccentColor
    private var trackingArea: NSTrackingArea?
    private var defaultsObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?

    init(shelfID: UUID) {
        self.shelfID = shelfID
        self.background = AdaptiveBackground(style: BarStyle.resolve(), accent: .controlAccentColor)
        super.init(frame: .zero)

        addSubview(background)

        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.lineBreakMode = .byTruncatingTail
        background.content.addSubview(dot)
        background.content.addSubview(headerLabel)

        addRow.onClick = { [weak self] in self?.showAddMenu() }
        background.content.addSubview(addRow)

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshStyle() }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshStyle() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var preferredHeight: CGFloat {
        let header = name.isEmpty ? 0 : Self.headerHeight
        return Self.padding * 2 + header + CGFloat(tabs.count) * HoverRowView.height + Self.addGap + HoverRowView.height
    }

    func update(name: String, accent: NSColor, tabs: [TabInfo]) {
        self.name = name
        self.accent = accent
        self.tabs = tabs
        background.accent = accent
        dot.color = accent
        headerLabel.stringValue = name
        dot.isHidden = name.isEmpty
        headerLabel.isHidden = name.isEmpty

        let currentIDs = Set(tabs.map(\.windowID))
        for (windowID, row) in rows where !currentIDs.contains(windowID) {
            row.removeFromSuperview()
            rows.removeValue(forKey: windowID)
        }
        for tab in tabs where rows[tab.windowID] == nil {
            let row = ShelfRowView(windowID: tab.windowID)
            row.onSelect = { [weak self] windowID in
                guard let self else { return }
                self.delegate?.shelf(self.shelfID, selectWindow: windowID)
                self.onDismissRequest?()
            }
            row.onHoverSelect = { [weak self] windowID in
                guard let self, self.reorderingID == nil else { return }
                self.delegate?.shelf(self.shelfID, selectWindow: windowID)
            }
            row.onClose = { [weak self] windowID in
                guard let self else { return }
                DispatchQueue.main.async { self.delegate?.shelf(self.shelfID, detachWindow: windowID) }
            }
            row.onReorderBegan = { [weak self] windowID in self?.beginReorder(windowID) }
            row.onReorderMoved = { [weak self] windowID, event in self?.moveReorder(windowID, event: event) }
            row.onReorderEnded = { [weak self] windowID in self?.endReorder(windowID) }
            row.onDragBegan = { [weak self] in self?.isBusy = true }
            row.onDragEnded = { [weak self] windowID, point, operation in
                self?.handleDragEnded(windowID: windowID, point: point, operation: operation)
            }
            background.content.addSubview(row)
            rows[tab.windowID] = row
        }
        reconfigureRows()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        background.layoutSubtreeIfNeeded()

        let pad = Self.padding
        let inner = bounds.width - pad * 2
        var y = bounds.height - pad

        if !name.isEmpty {
            y -= Self.headerHeight
            dot.frame = NSRect(x: pad + 8, y: y + (Self.headerHeight - 8) / 2, width: 8, height: 8)
            let labelHeight = ceil(headerLabel.intrinsicContentSize.height)
            let labelX = dot.frame.maxX + 6
            headerLabel.frame = NSRect(
                x: labelX,
                y: y + (Self.headerHeight - labelHeight) / 2,
                width: max(bounds.width - pad - 8 - labelX, 0),
                height: labelHeight
            )
        }
        for tab in tabs {
            y -= HoverRowView.height
            guard tab.windowID != reorderingID else { continue }
            rows[tab.windowID]?.frame = NSRect(x: pad, y: y, width: inner, height: HoverRowView.height)
        }
        y -= Self.addGap + HoverRowView.height
        addRow.frame = NSRect(x: pad, y: y, width: inner, height: HoverRowView.height)
    }

    private var rowsTop: CGFloat {
        bounds.height - Self.padding - (name.isEmpty ? 0 : Self.headerHeight)
    }

    private func beginReorder(_ windowID: CGWindowID) {
        guard let row = rows[windowID] else { return }
        reorderingID = windowID
        isBusy = true
        row.isReordering = true
        background.content.addSubview(row, positioned: .above, relativeTo: nil)
    }

    private func moveReorder(_ windowID: CGWindowID, event: NSEvent) {
        guard reorderingID == windowID, let row = rows[windowID],
              let from = tabs.firstIndex(where: { $0.windowID == windowID }) else { return }
        let point = background.content.convert(event.locationInWindow, from: nil)
        let height = HoverRowView.height
        let minY = rowsTop - height * CGFloat(tabs.count)
        row.frame.origin.y = min(max(point.y - height / 2, minY), rowsTop - height)

        let to = min(max(Int((rowsTop - point.y) / height), 0), tabs.count - 1)
        guard to != from else { return }
        tabs.insert(tabs.remove(at: from), at: to)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            layoutSubtreeIfNeeded()
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    private func endReorder(_ windowID: CGWindowID) {
        guard reorderingID == windowID else { return }
        reorderingID = nil
        rows[windowID]?.isReordering = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        isBusy = false
        delegate?.shelf(shelfID, reorder: tabs.map(\.windowID))
    }

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
        isHovered = true
        onStateChange?()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onStateChange?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshStyle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.appearance = AppSettings.themeMode.appearance
    }

    func refreshStyle() {
        window?.appearance = AppSettings.themeMode.appearance
        let style = BarStyle.resolve()
        guard style != background.style else { return }
        background.setStyle(style)
        reconfigureRows()
        needsLayout = true
    }

    private func reconfigureRows() {
        for tab in tabs {
            rows[tab.windowID]?.configure(tab, style: background.style, accent: accent)
        }
    }

    private func handleDragEnded(windowID: CGWindowID, point: NSPoint, operation: NSDragOperation) {
        isBusy = false
        guard operation.isEmpty, let frame = window?.frame, !frame.contains(point) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.delegate?.shelf(self.shelfID, detachWindow: windowID)
            self.onDismissRequest?()
        }
    }

    private func showAddMenu() {
        let menu = NSMenu()
        let candidates = delegate?.shelfCandidateWindows(shelfID) ?? []
        if candidates.isEmpty {
            let empty = NSMenuItem(title: "追加できるウィンドウがありません", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for candidate in candidates {
            let title = candidate.title.isEmpty ? candidate.appName : "\(candidate.title) — \(candidate.appName)"
            let item = NSMenuItem(title: title, action: #selector(addMenuItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate.windowID
            if let icon = candidate.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
        }
        isBusy = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: addRow)
        isBusy = false
    }

    @objc private func addMenuItemChosen(_ sender: NSMenuItem) {
        guard let windowID = sender.representedObject as? CGWindowID else { return }
        delegate?.shelf(shelfID, addWindow: windowID)
        onDismissRequest?()
    }
}

final class ShelfPopupPanel: OverlayPanel {
    let popupView: ShelfPopupView

    init(shelfID: UUID) {
        popupView = ShelfPopupView(shelfID: shelfID)
        super.init(size: NSSize(width: ShelfPopupView.width, height: 100), level: .floating)
        hasShadow = true
        contentView = popupView
        popupView.wantsLayer = true
    }

    func popIn() {
        guard let layer = popupView.layer else { return }
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = collapsedTransform(scale: 0.86, lift: 8)
        spring.toValue = CATransform3DIdentity
        spring.mass = 1
        spring.stiffness = 320
        spring.damping = 24
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        layer.transform = CATransform3DIdentity
        layer.add(spring, forKey: "pop")
        DispatchQueue.main.asyncAfter(deadline: .now() + spring.settlingDuration) { [weak self] in
            self?.invalidateShadow()
        }
    }

    func popOut() {
        guard let layer = popupView.layer else { return }
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = CATransform3DIdentity
        shrink.toValue = collapsedTransform(scale: 0.94, lift: 4)
        shrink.duration = 0.12
        shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false
        layer.add(shrink, forKey: "pop")
    }

    private func collapsedTransform(scale: CGFloat, lift: CGFloat) -> CATransform3D {
        let height = popupView.bounds.height
        return CATransform3DConcat(
            CATransform3DMakeScale(scale, scale, 1),
            CATransform3DMakeTranslation(0, height * (1 - scale) + lift, 0)
        )
    }
}
