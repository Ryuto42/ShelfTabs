import AppKit

final class ShelfController: NSObject {
    private let store = ShelfStore()
    private let tracker = WindowTracker()
    private let highlight = DropHighlightPanel()
    private let snapPreview = DropHighlightPanel()
    private let animator = WindowAnimator()
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private var bars: [UUID: ShelfButtonPanel] = [:]
    private var hiddenBars: Set<UUID> = []
    private var pollHiddenBars: Set<UUID> = []
    private var minimizedShelves: Set<UUID> = []
    private var shelfFrames: [UUID: CGRect] = [:]
    private var originalFrames: [CGWindowID: CGRect] = [:]
    private var titles: [CGWindowID: String] = [:]
    private var lightsOffsets: [CGWindowID: CGRect] = [:]
    private var hidden: Set<CGWindowID> = []
    private var parked: Set<CGWindowID> = []
    private var pendingSync: [UUID: Bool] = [:]
    private var ignoreFocusUntil = Date.distantPast
    private var pollTimer: Timer?

    private var dragSource: WindowInfo?
    private var dragTarget: WindowInfo?
    private var lastDragEvaluation: CFTimeInterval = 0
    private var liveMoveShelf: UUID?

    private struct SnapRecord {
        var restore: CGRect
        var snapped: CGRect
    }

    private var snapRecords: [CGWindowID: SnapRecord] = [:]
    private var dragMoved = false
    private var snapAction: LayoutAction?
    private var snapVisible = CGRect.zero
    private var snapFrame: CGRect?
    private var snapBottomEntry: Int?

    func start() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        tracker.onEvent = { [weak self] event, windowID in self?.handle(event, windowID) }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(applicationTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    func restoreAll() {
        animator.cancelAll()
        for shelf in store.shelves.values {
            for windowID in shelf.windowIDs {
                guard let element = tracker.element(of: windowID),
                      let frame = originalFrames[windowID],
                      Geometry.intersectsAnyScreen(axRect: frame) else { continue }
                AXWindow.setFrame(frame, of: element)
            }
        }
        if SkyLight.shared.isAlphaSupported {
            for info in WindowList.copy(onScreenOnly: false) where info.layer == 0 && info.pid != ownPID {
                SkyLight.shared.setAlpha(1, for: info.id)
            }
        }
        for id in Array(store.shelves.keys) {
            _ = store.dissolve(id)
        }
        for id in Array(bars.keys) {
            removeBar(id)
        }
        tracker.unwatchAll()
        updatePolling()
        shelfFrames.removeAll()
        originalFrames.removeAll()
        titles.removeAll()
        minimizedShelves.removeAll()
        lightsOffsets.removeAll()
        hidden.removeAll()
        parked.removeAll()
        pendingSync.removeAll()
        highlight.hide()
        clearSnap()
        snapRecords.removeAll()
    }

    // MARK: - Input

    func mouseDown(at point: CGPoint) {
        dragTarget = nil
        dragSource = nil
        dragMoved = false
        clearSnap()
        for info in WindowList.copy(onScreenOnly: true) where info.bounds.contains(point) {
            if info.pid == ownPID { return }
            if WindowList.isCandidate(info) {
                dragSource = info
                return
            }
        }
    }

    func mouseDragged(at point: CGPoint, flags: CGEventFlags) {
        guard let source = dragSource else { return }
        followLiveMove(source.id)
        let now = CACurrentMediaTime()
        guard now - lastDragEvaluation >= 1.0 / 30.0 else { return }
        lastDragEvaluation = now
        updateDropTarget(at: point, flags: flags)
    }

    func flagsChanged(_ flags: CGEventFlags) {
        guard dragSource != nil else { return }
        updateDropTarget(at: Geometry.axPoint(fromNS: NSEvent.mouseLocation), flags: flags)
    }

    func mouseUp(flags: CGEventFlags) {
        if let id = liveMoveShelf {
            liveMoveShelf = nil
            activeFrameChanged(id)
            placeBar(id)
        }
        let source = dragSource
        let target = dragTarget
        let snap = snapAction
        let snapVisible = snapVisible
        dragSource = nil
        dragTarget = nil
        dragMoved = false
        highlight.hide()
        clearSnap()

        if let source, let snap {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [self] in
                snapDragged(source: source, action: snap, visible: snapVisible)
            }
        } else if let source, let target {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [self] in
                mergeDragged(source: source, target: target)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            raiseBars()
        }
    }

    func handleShortcut(_ action: ShortcutAction) -> Bool {
        switch action {
        case .previousTab: return stepTab(by: -1)
        case .nextTab: return stepTab(by: 1)
        case .layout(let layout): return perform(layout)
        }
    }

    private func stepTab(by delta: Int) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ownPID,
              let windowID = AXWindow.focusedWindowID(pid: app.processIdentifier),
              let next = store.step(from: windowID, by: delta) else { return false }
        switchTo(next)
        return true
    }

    private func updateDropTarget(at point: CGPoint, flags: CGEventFlags) {
        guard let source = dragSource else { return }
        if !dragMoved, let bounds = WindowList.bounds(of: source.id), bounds.origin != source.bounds.origin {
            dragMoved = true
            restoreSizeIfUnsnapped(source, bounds: bounds, cursor: point)
        }
        if dragMoved, updateSnap(at: point, source: source) { return }

        let modifier = flags.contains(AppSettings.mergeModifier.flag)
        guard modifier || dragMoved else {
            setDropTarget(nil)
            return
        }
        let excluded = Set(store.shelf(containing: source.id)?.windowIDs ?? [source.id])
        var target = WindowList.copy(onScreenOnly: true).first {
            WindowList.isCandidate($0) && $0.bounds.contains(point) && !excluded.contains($0.id)
        }
        if let candidate = target, !modifier, !(dragMoved && Self.mergeZone(of: candidate.bounds).contains(point)) {
            target = nil
        }
        setDropTarget(target)
    }

    private func setDropTarget(_ target: WindowInfo?) {
        guard target?.id != dragTarget?.id else { return }
        dragTarget = target
        if let target {
            highlight.show(axFrame: target.bounds)
        } else {
            highlight.hide()
        }
    }

    // MARK: - Snap

    private func updateSnap(at point: CGPoint, source: WindowInfo) -> Bool {
        guard AppSettings.snapEnabled,
              let (area, screen) = Self.snapArea(at: point),
              let action = snapAction(for: area, at: point, screenFrame: Geometry.axRect(fromNS: screen.frame)),
              case let visible = ExternalDock.usableFrame(for: screen),
              let frame = WindowLayout.frame(for: action, current: source.bounds, visible: visible) else {
            clearSnap()
            return false
        }
        if area != .bottom { snapBottomEntry = nil }
        let appeared = snapAction == nil
        snapAction = action
        snapVisible = visible
        setDropTarget(nil)
        if frame != snapFrame {
            snapFrame = frame
            snapPreview.show(axFrame: frame)
        }
        if appeared, AppSettings.snapHaptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        return true
    }

    private func clearSnap() {
        snapBottomEntry = nil
        guard snapAction != nil else { return }
        snapAction = nil
        snapFrame = nil
        snapPreview.hide()
    }

    private func snapAction(for area: SnapArea, at point: CGPoint, screenFrame: CGRect) -> LayoutAction? {
        let choice = AppSettings.snapChoice(for: area)
        if choice == SnapArea.thirds, area == .bottom {
            let third = min(2, max(0, Int((point.x - screenFrame.minX) / screenFrame.width * 3)))
            let entry = snapBottomEntry ?? third
            snapBottomEntry = entry
            switch (entry, third) {
            case (0, 1): return .firstTwoThirds
            case (2, 1): return .lastTwoThirds
            case (_, 0): return .firstThird
            case (_, 1): return .centerThird
            default: return .lastThird
            }
        }
        return LayoutAction(rawValue: choice).flatMap { $0.isSnappable ? $0 : nil }
    }

    private static func snapArea(at point: CGPoint) -> (SnapArea, NSScreen)? {
        let screens = NSScreen.screens
        let frames = screens.map { Geometry.axRect(fromNS: $0.frame) }
        guard let index = frames.firstIndex(where: { $0.contains(point) })
                ?? frames.firstIndex(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) else { return nil }
        let f = frames[index]
        let others = frames.enumerated().filter { $0.offset != index }.map(\.element)
        func adjacent(_ p: CGPoint) -> Bool { others.contains { $0.contains(p) } }

        let edge: CGFloat = 5
        let corner: CGFloat = 20
        let left = point.x < f.minX + edge && !adjacent(CGPoint(x: f.minX - 1, y: point.y))
        let right = point.x >= f.maxX - edge && !adjacent(CGPoint(x: f.maxX + 1, y: point.y))
        let top = point.y < f.minY + edge && !adjacent(CGPoint(x: point.x, y: f.minY - 1))
        let bottom = point.y >= f.maxY - edge && !adjacent(CGPoint(x: point.x, y: f.maxY + 1))
        let nearLeft = point.x < f.minX + corner
        let nearRight = point.x >= f.maxX - corner
        let nearTop = point.y < f.minY + corner
        let nearBottom = point.y >= f.maxY - corner

        let area: SnapArea
        if (top && nearLeft) || (left && nearTop) {
            area = .topLeftCorner
        } else if (top && nearRight) || (right && nearTop) {
            area = .topRightCorner
        } else if (bottom && nearLeft) || (left && nearBottom) {
            area = .bottomLeftCorner
        } else if (bottom && nearRight) || (right && nearBottom) {
            area = .bottomRightCorner
        } else if top {
            area = .top
        } else if left {
            area = .left
        } else if right {
            area = .right
        } else if bottom {
            area = .bottom
        } else {
            return nil
        }
        return (area, screens[index])
    }

    private func restoreSizeIfUnsnapped(_ source: WindowInfo, bounds: CGRect, cursor: CGPoint) {
        guard AppSettings.snapRestoreSize,
              let record = snapRecords[source.id],
              Self.approximatelyEqual(source.bounds, record.snapped),
              let element = tracker.element(of: source.id) ?? AXWindow.element(pid: source.pid, id: source.id) else { return }
        snapRecords.removeValue(forKey: source.id)
        let size = record.restore.size
        guard size != bounds.size, bounds.width > 0 else { return }
        let relativeX = (cursor.x - bounds.minX) / bounds.width
        animator.cancel(source.id)
        AXWindow.setSize(size, of: element)
        AXWindow.setPosition(CGPoint(x: (cursor.x - relativeX * size.width).rounded(), y: bounds.minY), of: element)
    }

    private static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private func snapDragged(source: WindowInfo, action: LayoutAction, visible: CGRect) {
        guard let element = tracker.element(of: source.id) ?? AXWindow.element(pid: source.pid, id: source.id),
              let current = AXWindow.frame(of: element),
              let frame = WindowLayout.frame(for: action, current: current, visible: visible) else { return }
        applyLayout(windowID: source.id, element: element, frame: frame)
    }

    private func perform(_ action: LayoutAction) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ownPID,
              let focusedID = AXWindow.focusedWindowID(pid: app.processIdentifier),
              let focusedElement = tracker.element(of: focusedID) ?? AXWindow.element(pid: app.processIdentifier, id: focusedID),
              !AXWindow.isFullScreen(focusedElement) else { return false }
        let (windowID, element) = layoutTarget(windowID: focusedID, element: focusedElement)
        guard let current = AXWindow.frame(of: element) else { return false }

        if action == .restore {
            guard let record = snapRecords.removeValue(forKey: windowID) else { return false }
            applyLayout(windowID: windowID, element: element, frame: record.restore, recordSnap: false)
            return true
        }
        guard let frame = action.targetFrame(current: current) else { return false }
        applyLayout(windowID: windowID, element: element, frame: frame)
        return true
    }

    private func layoutTarget(windowID: CGWindowID, element: AXUIElement) -> (CGWindowID, AXUIElement) {
        if let shelf = store.shelf(containing: windowID), shelf.activeWindowID != windowID,
           let activeElement = tracker.element(of: shelf.activeWindowID) {
            return (shelf.activeWindowID, activeElement)
        }
        return (windowID, element)
    }

    private func applyLayout(windowID: CGWindowID, element: AXUIElement, frame: CGRect, recordSnap: Bool = true) {
        let (windowID, element) = layoutTarget(windowID: windowID, element: element)
        let current = AXWindow.frame(of: element)

        if recordSnap, let current {
            let restore = snapRecords[windowID].flatMap { Self.approximatelyEqual(current, $0.snapped) ? $0.restore : nil } ?? current
            snapRecords[windowID] = SnapRecord(restore: restore, snapped: frame)
            pruneSnapRecords()
        }

        let shelfID = store.shelf(containing: windowID)?.id
        let finish = { [weak self] in
            guard let self else { return }
            if let shelfID {
                self.activeFrameChanged(shelfID)
                self.placeBar(shelfID)
            }
            if let actual = AXWindow.frame(of: element), self.snapRecords[windowID] != nil, recordSnap {
                self.snapRecords[windowID]?.snapped = actual
            }
        }

        animator.cancel(windowID)
        if AppSettings.animateWindowMove, let current, current != frame {
            animator.animate(windowID, element: element, from: current, to: frame, completion: finish)
        } else {
            AXWindow.setFrame(frame, of: element)
            finish()
        }
    }

    private func pruneSnapRecords() {
        guard snapRecords.count > 50 else { return }
        let alive = Set(WindowList.describe(Array(snapRecords.keys)).map(\.id))
        snapRecords = snapRecords.filter { alive.contains($0.key) }
    }

    private static func mergeZone(of bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX, y: bounds.minY, width: min(110, bounds.width / 4), height: min(36, bounds.height / 6))
    }

    // MARK: - Merge / detach

    private func mergeDragged(source: WindowInfo, target: WindowInfo) {
        let sourceIsNew = store.shelf(containing: source.id) == nil
        let targetIsNew = store.shelf(containing: target.id) == nil

        guard register(windowID: source.id, pid: source.pid),
              register(windowID: target.id, pid: target.pid),
              let targetElement = tracker.element(of: target.id) else {
            if sourceIsNew { release(source.id) }
            if targetIsNew { release(target.id) }
            return
        }
        if sourceIsNew {
            originalFrames[source.id] = source.bounds
        }

        let frame = AXWindow.frame(of: targetElement) ?? target.bounds
        let fallbacks = fallbackFrames(forShelvesOf: [source.id, target.id])
        guard let result = store.merge(source: source.id, into: target.id) else { return }
        reconcile(result.change, fallbacks: fallbacks, hints: [result.id: frame], focus: [result.id], animated: true)
    }

    private func detach(_ windowID: CGWindowID) {
        guard store.shelf(containing: windowID) != nil, let pid = tracker.pid(of: windowID) else { return }
        let fallbacks = fallbackFrames(forShelvesOf: [windowID])
        let change = store.detach(windowID)
        reconcile(change, fallbacks: fallbacks, hints: [:], focus: [])

        guard let element = AXWindow.element(pid: pid, id: windowID) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + WindowAnimator.duration + 0.03) {
            AXWindow.focus(element, pid: pid)
        }
    }

    private func removeWindows(_ gone: Set<CGWindowID>) {
        let fallbacks = fallbackFrames(forShelvesOf: Array(gone))
        let change = store.remove(gone)
        for windowID in gone {
            release(windowID)
        }
        reconcile(change, fallbacks: fallbacks, hints: [:], focus: [], restoreVisible: false, excluding: gone)
    }

    private func fallbackFrames(forShelvesOf windowIDs: [CGWindowID]) -> [CGWindowID: CGRect] {
        var result: [CGWindowID: CGRect] = [:]
        for windowID in windowIDs {
            guard let shelf = store.shelf(containing: windowID), let frame = shelfFrames[shelf.id] else { continue }
            for member in shelf.windowIDs {
                result[member] = frame
            }
        }
        return result
    }

    private func reconcile(
        _ change: ShelfChange,
        fallbacks: [CGWindowID: CGRect],
        hints: [UUID: CGRect],
        focus: Set<UUID>,
        animated: Bool = false,
        restoreVisible: Bool = true,
        excluding gone: Set<CGWindowID> = []
    ) {
        for windowID in change.freed where !gone.contains(windowID) {
            free(windowID, fallback: fallbacks[windowID], restore: restoreVisible)
        }
        for id in change.touched {
            if store.shelves[id] != nil, let frame = hints[id] ?? shelfFrames[id] {
                applyShelf(id, frame: frame, focus: focus.contains(id), animated: animated)
            } else {
                removeBar(id)
                shelfFrames.removeValue(forKey: id)
                minimizedShelves.remove(id)
            }
        }
        updatePolling()
    }

    // MARK: - Window state

    private func register(windowID: CGWindowID, pid: pid_t) -> Bool {
        guard tracker.watch(windowID: windowID, pid: pid),
              let element = tracker.element(of: windowID) else { return false }
        guard AXWindow.isStandard(element) else {
            tracker.unwatch(windowID: windowID)
            return false
        }
        if originalFrames[windowID] == nil, let frame = AXWindow.frame(of: element) {
            originalFrames[windowID] = frame
        }
        titles[windowID] = AXWindow.title(of: element)
        return true
    }

    private func release(_ windowID: CGWindowID) {
        tracker.unwatch(windowID: windowID)
        originalFrames.removeValue(forKey: windowID)
        titles.removeValue(forKey: windowID)
        lightsOffsets.removeValue(forKey: windowID)
        hidden.remove(windowID)
        parked.remove(windowID)
    }

    private func free(_ windowID: CGWindowID, fallback: CGRect?, restore: Bool) {
        animator.cancel(windowID)
        if let element = tracker.element(of: windowID) {
            let wasHidden = hidden.contains(windowID)
            var target = originalFrames[windowID]
            if let candidate = target, !Geometry.intersectsAnyScreen(axRect: candidate) {
                target = nil
            }
            if restore || wasHidden, let target = target ?? fallback {
                let current = parked.contains(windowID) ? fallback : AXWindow.frame(of: element)
                let from = current ?? target
                if wasHidden {
                    SkyLight.shared.setAlpha(0, for: windowID)
                    AXWindow.setFrame(from, of: element)
                }
                AXWindow.raise(element)
                animator.animate(windowID, element: element, from: from, to: target, alphaFrom: wasHidden ? 0 : 1, alphaTo: 1)
            } else {
                SkyLight.shared.setAlpha(1, for: windowID)
            }
        }
        release(windowID)
    }

    private func hide(_ windowID: CGWindowID, frame: CGRect, animated: Bool) {
        guard let element = tracker.element(of: windowID) else { return }
        animator.cancel(windowID)
        let wasVisible = !hidden.contains(windowID)
        hidden.insert(windowID)
        if animated, wasVisible, let current = AXWindow.frame(of: element) {
            animator.animate(windowID, element: element, from: current, to: nil, alphaFrom: 1, alphaTo: 0) { [weak self] in
                guard let self, self.hidden.contains(windowID) else { return }
                self.park(windowID, element: element, frame: frame)
            }
            return
        }
        park(windowID, element: element, frame: frame)
    }

    private func park(_ windowID: CGWindowID, element: AXUIElement, frame: CGRect) {
        if SkyLight.shared.setAlpha(0, for: windowID) {
            parked.remove(windowID)
            AXWindow.setFrame(frame, of: element)
        } else {
            let size = AXWindow.frame(of: element)?.size ?? frame.size
            AXWindow.setPosition(Geometry.hidingOrigin(for: CGRect(origin: frame.origin, size: size)), of: element)
            parked.insert(windowID)
        }
    }

    @discardableResult
    private func show(_ windowID: CGWindowID, frame: CGRect, animated: Bool, completion: (() -> Void)? = nil) -> Bool {
        guard let element = tracker.element(of: windowID) else { return false }
        animator.cancel(windowID)
        if AXWindow.isMinimized(element) {
            AXWindow.setMinimized(false, of: element)
        }
        let wasHidden = hidden.contains(windowID)
        hidden.remove(windowID)
        parked.remove(windowID)

        if animated, !wasHidden, let current = AXWindow.frame(of: element), current != frame {
            SkyLight.shared.setAlpha(1, for: windowID)
            AXWindow.raise(element)
            animator.animate(windowID, element: element, from: current, to: frame, completion: completion)
            return true
        }
        AXWindow.setFrame(frame, of: element)
        SkyLight.shared.setAlpha(1, for: windowID)
        AXWindow.raise(element)
        return false
    }

    private func focusWindow(_ windowID: CGWindowID) {
        guard let element = tracker.element(of: windowID), let pid = tracker.pid(of: windowID) else { return }
        AXWindow.focus(element, pid: pid)
    }

    private func applyShelf(_ id: UUID, frame: CGRect, focus: Bool, animated: Bool) {
        guard let shelf = store.shelves[id] else { return }
        let active = shelf.activeWindowID

        let animating = show(active, frame: frame, animated: animated) { [weak self] in
            self?.activeFrameChanged(id)
            if focus, self?.store.shelves[id]?.activeWindowID == active {
                self?.ignoreFocusUntil = Date().addingTimeInterval(0.4)
                self?.focusWindow(active)
            }
        }
        for windowID in shelf.windowIDs where windowID != active {
            hide(windowID, frame: frame, animated: animated)
        }
        if animating {
            shelfFrames[id] = frame
        } else if let element = tracker.element(of: active), let actual = AXWindow.frame(of: element) {
            shelfFrames[id] = actual
            if actual != frame {
                scheduleSync(id, sizeChanged: true)
            }
        } else {
            shelfFrames[id] = frame
        }

        ignoreFocusUntil = Date().addingTimeInterval(0.4)
        refreshBar(id)
        hiddenBars.remove(id)
        updateBarVisibility(id)
        if focus, !animating {
            focusWindow(active)
        }
    }

    private func switchTo(_ windowID: CGWindowID) {
        guard let shelf = store.shelf(containing: windowID) else { return }
        guard shelf.activeWindowID != windowID else {
            focusWindow(windowID)
            return
        }

        let old = shelf.activeWindowID
        let oldFrame = tracker.element(of: old).flatMap { AXWindow.frame(of: $0) } ?? shelfFrames[shelf.id]
        guard let frame = oldFrame else { return }

        store.setActive(windowID)
        ignoreFocusUntil = Date().addingTimeInterval(0.4)
        show(windowID, frame: frame, animated: false)
        hide(old, frame: frame, animated: false)

        if let element = tracker.element(of: windowID), let actual = AXWindow.frame(of: element) {
            shelfFrames[shelf.id] = actual
            if actual != frame {
                scheduleSync(shelf.id, sizeChanged: true)
            }
        } else {
            shelfFrames[shelf.id] = frame
        }
        refreshBar(shelf.id)
        placeBar(shelf.id)
        focusWindow(windowID)
    }

    // MARK: - Event handling

    private func handle(_ event: WindowTracker.Event, _ windowID: CGWindowID) {
        guard let shelf = store.shelf(containing: windowID) else { return }
        switch event {
        case .moved, .resized:
            guard windowID == shelf.activeWindowID, !animator.isAnimating(windowID) else { return }
            activeFrameChanged(shelf.id)
        case .destroyed:
            removeWindows([windowID])
        case .titleChanged:
            if let element = tracker.element(of: windowID) {
                titles[windowID] = AXWindow.title(of: element)
            }
            if bars[shelf.id]?.isPopupOpen == true {
                refreshBar(shelf.id)
            }
        case .focused:
            if windowID != shelf.activeWindowID, Date() > ignoreFocusUntil {
                switchTo(windowID)
            } else {
                raiseBars()
            }
        case .stateChanged:
            minimizationChanged(shelf.id, windowID)
            updateBarVisibility(shelf.id)
        }
    }

    private func minimizationChanged(_ id: UUID, _ windowID: CGWindowID) {
        guard let shelf = store.shelves[id], let element = tracker.element(of: windowID) else { return }
        let minimized = AXWindow.isMinimized(element)

        if minimized, !minimizedShelves.contains(id) {
            minimizedShelves.insert(id)
            for member in shelf.windowIDs where member != windowID {
                guard let memberElement = tracker.element(of: member) else { continue }
                animator.cancel(member)
                if parked.contains(member), let frame = shelfFrames[id] {
                    AXWindow.setFrame(frame, of: memberElement)
                    parked.remove(member)
                }
                SkyLight.shared.setAlpha(1, for: member)
                AXWindow.setMinimized(true, of: memberElement)
            }
        } else if !minimized, minimizedShelves.contains(id) {
            minimizedShelves.remove(id)
            store.setActive(windowID)
            for member in shelf.windowIDs where member != windowID {
                guard let memberElement = tracker.element(of: member) else { continue }
                SkyLight.shared.setAlpha(0, for: member)
                hidden.insert(member)
                AXWindow.setMinimized(false, of: memberElement)
            }
            let frame = AXWindow.frame(of: element) ?? shelfFrames[id]
            if let frame {
                applyShelf(id, frame: frame, focus: true, animated: false)
            }
        }
    }

    private func activeFrameChanged(_ id: UUID) {
        guard let shelf = store.shelves[id],
              let element = tracker.element(of: shelf.activeWindowID),
              let frame = AXWindow.frame(of: element) else { return }
        let previous = shelfFrames[id]
        guard frame != previous else { return }
        shelfFrames[id] = frame
        if liveMoveShelf != id {
            placeBar(id)
        }
        scheduleSync(id, sizeChanged: previous?.size != frame.size)
    }

    private func scheduleSync(_ id: UUID, sizeChanged: Bool) {
        let isFirst = pendingSync.isEmpty
        pendingSync[id] = (pendingSync[id] ?? false) || sizeChanged
        guard isFirst else { return }
        DispatchQueue.main.async { [self] in
            let pending = pendingSync
            pendingSync.removeAll()
            for (id, sizeChanged) in pending {
                syncSiblings(id, sizeChanged: sizeChanged)
            }
        }
    }

    private func syncSiblings(_ id: UUID, sizeChanged: Bool) {
        guard let shelf = store.shelves[id], let frame = shelfFrames[id] else { return }
        for windowID in shelf.windowIDs where windowID != shelf.activeWindowID && !parked.contains(windowID) {
            guard let element = tracker.element(of: windowID) else { continue }
            if sizeChanged {
                AXWindow.setFrame(frame, of: element)
            } else {
                AXWindow.setPosition(frame.origin, of: element)
            }
        }
    }

    // A backstop for missed AX notifications; only runs while shelves exist.
    private func updatePolling() {
        if store.shelves.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        } else if pollTimer == nil {
            let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refreshVisibility(full: false) }
            timer.tolerance = 1.5
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }
    }

    private func refreshVisibility(full: Bool) {
        guard !store.shelves.isEmpty else { return }
        let infos = WindowList.describe(Array(store.allWindowIDs))
        let gone = store.allWindowIDs.subtracting(infos.map(\.id))
        if !gone.isEmpty {
            removeWindows(gone)
        }
        let onScreen = Set(infos.filter(\.isOnScreen).map(\.id))
        for (id, shelf) in store.shelves {
            if full {
                updateBarVisibility(id, onScreen: onScreen)
            } else if !onScreen.contains(shelf.activeWindowID) {
                if !hiddenBars.contains(id) {
                    hiddenBars.insert(id)
                    pollHiddenBars.insert(id)
                    bars[id]?.hide()
                }
            } else if pollHiddenBars.remove(id) != nil {
                hiddenBars.remove(id)
                placeBar(id)
            }
        }
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let gone = Set(tracker.windowIDs(forPID: app.processIdentifier))
        if !gone.isEmpty {
            removeWindows(gone)
        }
    }

    @objc private func applicationActivated(_ notification: Notification) {
        raiseBars()
    }

    @objc private func spaceChanged() {
        refreshVisibility(full: true)
    }

    // MARK: - Bars

    private func ensureBar(_ id: UUID) -> ShelfButtonPanel {
        if let bar = bars[id] { return bar }
        let bar = ShelfButtonPanel(shelfID: id)
        bar.shelfDelegate = self
        bars[id] = bar
        return bar
    }

    private func removeBar(_ id: UUID) {
        guard let bar = bars.removeValue(forKey: id) else { return }
        hiddenBars.remove(id)
        pollHiddenBars.remove(id)
        bar.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { _ = bar }
    }

    private func refreshBar(_ id: UUID) {
        guard let shelf = store.shelves[id] else { return }
        let bar = ensureBar(id)
        let tabs = shelf.windowIDs.map { windowID -> TabInfo in
            let app = tracker.pid(of: windowID).flatMap { NSRunningApplication(processIdentifier: $0) }
            return TabInfo(
                windowID: windowID,
                title: titles[windowID] ?? "",
                appName: app?.localizedName ?? "",
                icon: app?.icon,
                isActive: windowID == shelf.activeWindowID
            )
        }
        bar.update(name: shelf.name, accent: shelf.accent.color, tabs: tabs)
    }

    // Follows the window server's bounds during a user drag; AX move notifications arrive too late.
    private func followLiveMove(_ windowID: CGWindowID) {
        guard let shelf = store.shelf(containing: windowID), shelf.activeWindowID == windowID,
              let bounds = WindowList.bounds(of: windowID) else { return }
        if liveMoveShelf == nil {
            guard bounds != shelfFrames[shelf.id] else { return }
            liveMoveShelf = shelf.id
        }
        placeBar(shelf.id, frame: bounds)
    }

    private func raiseBars() {
        for id in bars.keys {
            placeBar(id)
        }
    }

    private func placeBar(_ id: UUID, frame override: CGRect? = nil) {
        guard !hiddenBars.contains(id),
              let shelf = store.shelves[id],
              let bar = bars[id],
              let frame = override ?? shelfFrames[id] else { return }
        let active = shelf.activeWindowID
        if lightsOffsets[active] == nil,
           let element = tracker.element(of: active),
           let lights = AXWindow.trafficLightsFrame(of: element),
           let windowFrame = AXWindow.frame(of: element) {
            lightsOffsets[active] = lights.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
        }
        let lights = lightsOffsets[active]?.offsetBy(dx: frame.minX, dy: frame.minY)
        bar.place(windowAXFrame: frame, trafficLights: lights, above: active)
    }

    private func updateBarVisibility(_ id: UUID, onScreen: Set<CGWindowID>? = nil) {
        guard let shelf = store.shelves[id], let element = tracker.element(of: shelf.activeWindowID) else { return }
        let active = shelf.activeWindowID
        let visible = !AXWindow.isMinimized(element)
            && !AXWindow.isFullScreen(element)
            && (onScreen?.contains(active) ?? true)

        pollHiddenBars.remove(id)
        if visible {
            hiddenBars.remove(id)
            placeBar(id)
        } else if !hiddenBars.contains(id) {
            hiddenBars.insert(id)
            bars[id]?.hide()
        }
    }
}

extension ShelfController: ShelfButtonDelegate {
    func shelf(_ id: UUID, selectWindow windowID: CGWindowID) {
        switchTo(windowID)
    }

    func shelf(_ id: UUID, detachWindow windowID: CGWindowID) {
        detach(windowID)
    }

    func shelf(_ id: UUID, dropWindow windowID: CGWindowID) {
        guard store.shelves[id] != nil,
              let source = store.shelf(containing: windowID), source.id != id else { return }
        let fallbacks = fallbackFrames(forShelvesOf: [windowID])
        let change = store.move(windowID, toShelf: id)
        reconcile(change, fallbacks: fallbacks, hints: [:], focus: [id], animated: true)
    }

    func shelfCandidateWindows(_ id: UUID) -> [CandidateWindow] {
        let inShelves = store.allWindowIDs
        return WindowList.copy(onScreenOnly: true).compactMap { info in
            guard WindowList.isCandidate(info), !inShelves.contains(info.id),
                  let element = AXWindow.element(pid: info.pid, id: info.id),
                  AXWindow.isStandard(element) else { return nil }
            let app = NSRunningApplication(processIdentifier: info.pid)
            return CandidateWindow(
                windowID: info.id,
                title: AXWindow.title(of: element),
                appName: app?.localizedName ?? info.ownerName,
                icon: app?.icon
            )
        }
    }

    func shelf(_ id: UUID, addWindow windowID: CGWindowID) {
        guard store.shelves[id] != nil,
              let info = WindowList.copy(onScreenOnly: false).first(where: { $0.id == windowID }),
              register(windowID: windowID, pid: info.pid) else { return }
        let fallbacks = fallbackFrames(forShelvesOf: [windowID])
        let change = store.move(windowID, toShelf: id)
        reconcile(change, fallbacks: fallbacks, hints: [:], focus: [id], animated: true)
    }

    func shelf(_ id: UUID, renameTo name: String) {
        store.rename(id, to: name)
        refreshBar(id)
        if let active = store.shelves[id]?.activeWindowID {
            focusWindow(active)
        }
    }

    func shelf(_ id: UUID, setAccent accent: ShelfAccent) {
        store.setAccent(id, to: accent)
        refreshBar(id)
    }

    func shelf(_ id: UUID, reorder windowIDs: [CGWindowID]) {
        store.reorder(id, to: windowIDs)
        refreshBar(id)
    }

    func shelfPopupWillOpen(_ id: UUID) {
        refreshBar(id)
    }

    func shelfDissolve(_ id: UUID) {
        guard let shelf = store.shelves[id] else { return }
        let fallbacks = fallbackFrames(forShelvesOf: shelf.windowIDs)
        let change = store.dissolve(id)
        reconcile(change, fallbacks: fallbacks, hints: [:], focus: [])
    }
}
