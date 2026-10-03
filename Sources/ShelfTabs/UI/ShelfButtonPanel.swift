import AppKit

struct CandidateWindow {
    let windowID: CGWindowID
    let title: String
    let appName: String
    let icon: NSImage?
}

protocol ShelfButtonDelegate: AnyObject {
    func shelf(_ id: UUID, selectWindow windowID: CGWindowID)
    func shelf(_ id: UUID, detachWindow windowID: CGWindowID)
    func shelf(_ id: UUID, dropWindow windowID: CGWindowID)
    func shelfCandidateWindows(_ id: UUID) -> [CandidateWindow]
    func shelf(_ id: UUID, addWindow windowID: CGWindowID)
    func shelf(_ id: UUID, reorder windowIDs: [CGWindowID])
    func shelf(_ id: UUID, renameTo name: String)
    func shelf(_ id: UUID, setAccent accent: ShelfAccent)
    func shelfDissolve(_ id: UUID)
}

final class ShelfButtonView: NSView {
    let shelfID: UUID
    weak var delegate: ShelfButtonDelegate?
    var onHoverChanged: ((Bool) -> Void)?
    var onContextMenu: (() -> Void)?

    private var pill: NSView?
    private var style = BarStyle.resolve()
    private var tabIDs: Set<CGWindowID> = []
    private var name = ""
    private var accent: NSColor = .controlAccentColor
    private var trackingArea: NSTrackingArea?
    private var defaultsObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?

    init(shelfID: UUID) {
        self.shelfID = shelfID
        super.init(frame: .zero)
        rebuildPill()
        registerForDraggedTypes([ShelfRowView.pasteboardType])

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

    func update(name: String, accent: NSColor, tabIDs: [CGWindowID]) {
        self.name = name
        self.accent = accent
        self.tabIDs = Set(tabIDs)
        toolTip = name.isEmpty ? nil : name
        applyColors()
    }

    override func layout() {
        super.layout()
        let size = ShelfButtonPanel.pillSize
        pill?.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func refreshStyle() {
        let newStyle = BarStyle.resolve()
        guard newStyle != style else { return }
        style = newStyle
        rebuildPill()
    }

    private func rebuildPill() {
        pill?.removeFromSuperview()
        let radius = ShelfButtonPanel.pillSize.height / 2
        let newPill: NSView
        switch style {
        case .glass:
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.style = .clear
            if #available(macOS 27, *) {
                glass.effectIsInteractive = true
            }
            newPill = glass
        case .solid:
            newPill = NSView()
            newPill.wantsLayer = true
            newPill.layer?.cornerRadius = radius
        }
        addSubview(newPill)
        pill = newPill
        applyColors()
        needsLayout = true
    }

    private func applyColors() {
        if !(pill is NSGlassEffectView), let layer = pill?.layer {
            layer.backgroundColor = resolvedCGColor(.tertiaryLabelColor)
            if case .solid(let highContrast) = style, highContrast {
                layer.borderWidth = 1
                layer.borderColor = resolvedCGColor(.labelColor)
            } else {
                layer.borderWidth = 0
            }
        }
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
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?()
        NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: self)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()

        let rename = NSMenuItem(title: "名前を変更…", action: #selector(renameChosen), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)

        let accentItem = NSMenuItem(title: "アクセントカラー", action: nil, keyEquivalent: "")
        let accentMenu = NSMenu()
        let currentAccent = ShelfAccent.allCases.first { $0.color == accent }
        for preset in ShelfAccent.allCases {
            let item = NSMenuItem(title: preset.label, action: #selector(accentChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = preset.rawValue
            item.image = Self.swatch(preset.color)
            item.state = preset == currentAccent ? .on : .off
            accentMenu.addItem(item)
        }
        accentItem.submenu = accentMenu
        menu.addItem(accentItem)

        menu.addItem(.separator())

        let dissolve = NSMenuItem(title: "棚を解散", action: #selector(dissolveChosen), keyEquivalent: "")
        dissolve.target = self
        menu.addItem(dissolve)
        return menu
    }

    @objc private func renameChosen() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = name
        field.placeholderString = "棚の名前"

        let alert = NSAlert()
        alert.messageText = "棚の名前を変更"
        alert.informativeText = "空にすると名前なしになります。"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = field

        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        delegate?.shelf(shelfID, renameTo: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc private func accentChosen(_ sender: NSMenuItem) {
        guard let preset = ShelfAccent(rawValue: sender.tag) else { return }
        delegate?.shelf(shelfID, setAccent: preset)
    }

    @objc private func dissolveChosen() {
        delegate?.shelfDissolve(shelfID)
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    private func draggedWindowID(_ sender: NSDraggingInfo) -> CGWindowID? {
        sender.draggingPasteboard.string(forType: ShelfRowView.pasteboardType).flatMap { CGWindowID($0) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let windowID = draggedWindowID(sender), !tabIDs.contains(windowID) else { return [] }
        return .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let windowID = draggedWindowID(sender), !tabIDs.contains(windowID) else { return false }
        DispatchQueue.main.async { self.delegate?.shelf(self.shelfID, dropWindow: windowID) }
        return true
    }
}

final class ShelfButtonPanel: OverlayPanel {
    static let pillSize = NSSize(width: 72, height: 6)
    static let padding: CGFloat = 3
    private static let topInset: CGFloat = 3
    private static let trafficLightCenterX: CGFloat = 40
    private static let popupGap: CGFloat = 2
    private static let closeDelay: TimeInterval = 0.25

    private static var panelSize: NSSize {
        NSSize(width: pillSize.width + padding * 2, height: pillSize.height + padding * 2)
    }

    let shelfID: UUID
    weak var shelfDelegate: ShelfButtonDelegate? {
        didSet {
            buttonView.delegate = shelfDelegate
            popup.popupView.delegate = shelfDelegate
        }
    }

    private let buttonView: ShelfButtonView
    private let popup: ShelfPopupPanel
    private var buttonHovered = false
    private var closeWork: DispatchWorkItem?

    init(shelfID: UUID) {
        self.shelfID = shelfID
        buttonView = ShelfButtonView(shelfID: shelfID)
        popup = ShelfPopupPanel(shelfID: shelfID)
        super.init(size: Self.panelSize, level: .normal)
        contentView = buttonView

        buttonView.onHoverChanged = { [weak self] hovered in
            self?.buttonHovered = hovered
            self?.evaluatePopup()
        }
        buttonView.onContextMenu = { [weak self] in self?.closePopup() }
        popup.popupView.onStateChange = { [weak self] in self?.evaluatePopup() }
        popup.popupView.onDismissRequest = { [weak self] in self?.closePopup() }
    }

    func update(name: String, accent: NSColor, tabs: [TabInfo]) {
        buttonView.update(name: name, accent: accent, tabIDs: tabs.map(\.windowID))
        popup.popupView.update(name: name, accent: accent, tabs: tabs)
        if popup.isVisible {
            positionPopup()
        }
    }

    func place(windowAXFrame frame: CGRect, trafficLights: CGRect?, above windowID: CGWindowID) {
        let size = Self.panelSize
        let pill = Self.pillSize
        let centerX = trafficLights?.midX ?? frame.minX + Self.trafficLightCenterX
        var centerY = frame.minY + Self.topInset + pill.height / 2
        if let trafficLights {
            let gap = trafficLights.minY - frame.minY
            if gap >= pill.height + Self.topInset * 2 {
                centerY = frame.minY + gap / 2
            }
        }
        let axRect = CGRect(x: centerX - size.width / 2, y: centerY - size.height / 2, width: size.width, height: size.height)
        let target = Geometry.nsRect(fromAX: axRect)
        if self.frame != target {
            setFrame(target, display: true)
        }
        present { order(.above, relativeTo: Int(windowID)) }
        if popup.isVisible {
            positionPopup()
        }
    }

    func hide() {
        buttonHovered = false
        closePopup()
        dismiss()
    }

    private func evaluatePopup() {
        closeWork?.cancel()
        closeWork = nil
        let view = popup.popupView
        if buttonHovered {
            showPopup()
        } else if view.isHovered || view.isBusy {
            return
        } else if popup.isVisible {
            let work = DispatchWorkItem { [weak self] in self?.closePopup() }
            closeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDelay, execute: work)
        }
    }

    private func showPopup() {
        guard isVisible else { return }
        let appearing = !popup.isVisible
        positionPopup()
        popup.present(duration: 0.14) { popup.orderFrontRegardless() }
        if appearing {
            popup.popIn()
        }
    }

    private func closePopup() {
        closeWork?.cancel()
        closeWork = nil
        popup.popupView.isHovered = false
        popup.popOut()
        popup.dismiss(duration: 0.12)
    }

    private func positionPopup() {
        let anchor = frame.insetBy(dx: Self.padding, dy: Self.padding)
        let size = NSSize(width: ShelfPopupView.width, height: popup.popupView.preferredHeight)
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - Self.popupGap - size.height)
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = max(origin.y, visible.minY)
        }
        let target = NSRect(origin: origin, size: size)
        if popup.frame != target {
            popup.setFrame(target, display: true)
        }
    }
}
