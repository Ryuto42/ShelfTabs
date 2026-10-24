import AppKit

extension ShelfController {
    func mouseDown(at point: CGPoint) {
        // A missed mouseUp would otherwise keep the bar following a finished move.
        endLiveMove()
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
        endLiveMove()
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

    func handleShortcut(_ action: ShortcutAction) {
        switch action {
        case .previousTab: stepTab(by: -1)
        case .nextTab: stepTab(by: 1)
        case .layout(let layout): perform(layout)
        }
    }

    private func endLiveMove() {
        guard let id = liveMoveShelf else { return }
        liveMoveShelf = nil
        activeFrameChanged(id)
        placeBar(id)
    }

    private func stepTab(by delta: Int) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ownPID,
              let focusedID = AXWindow.focusedWindowID(pid: app.processIdentifier),
              let windowID = memberID(for: focusedID),
              let next = store.step(from: windowID, by: delta) else { return }
        switchTo(next)
    }

    private func updateDropTarget(at point: CGPoint, flags: CGEventFlags) {
        guard let source = dragSource else { return }
        if !dragMoved, let bounds = WindowList.bounds(of: source.id), bounds.origin != source.bounds.origin {
            dragMoved = true
            restoreSizeIfUnsnapped(source, bounds: bounds, cursor: point)
        }
        if dragMoved, updateSnap(at: point, source: source) { return }

        guard dragMoved else {
            setDropTarget(nil)
            return
        }
        let pressed = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        let modifier = pressed == AppSettings.mergeModifier.flag
        let excluded = Set(store.shelf(containing: source.id)?.windowIDs ?? [source.id])
        var target = WindowList.copy(onScreenOnly: true).first {
            WindowList.isCandidate($0) && $0.bounds.contains(point) && !excluded.contains($0.id)
        }
        if let candidate = target, !modifier, !Self.mergeZone(of: candidate.bounds).contains(point) {
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

    private static func mergeZone(of bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX, y: bounds.minY, width: min(110, bounds.width / 4), height: min(36, bounds.height / 6))
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

    func clearSnap() {
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

    private func snapDragged(source: WindowInfo, action: LayoutAction, visible: CGRect) {
        guard let element = tracker.element(of: source.id) ?? AXWindow.element(pid: source.pid, id: source.id),
              let current = AXWindow.frame(of: element),
              let frame = WindowLayout.frame(for: action, current: current, visible: visible) else { return }
        applyLayout(windowID: source.id, element: element, frame: frame)
    }

    private func perform(_ action: LayoutAction) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ownPID,
              let focusedID = AXWindow.focusedWindowID(pid: app.processIdentifier),
              let focusedElement = tracker.element(of: focusedID) ?? AXWindow.element(pid: app.processIdentifier, id: focusedID),
              !AXWindow.isFullScreen(focusedElement) else { return }
        let (windowID, element) = layoutTarget(windowID: focusedID, element: focusedElement)
        guard let current = AXWindow.frame(of: element) else { return }

        if action == .restore {
            guard let record = snapRecords.removeValue(forKey: windowID) else { return }
            applyLayout(windowID: windowID, element: element, frame: record.restore, recordSnap: false)
            return
        }
        guard let frame = action.targetFrame(current: current) else { return }
        applyLayout(windowID: windowID, element: element, frame: frame)
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
}
