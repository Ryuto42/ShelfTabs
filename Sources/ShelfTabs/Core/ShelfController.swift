import AppKit

final class ShelfController: NSObject {
    private let store = ShelfStore()
    private let tracker = WindowTracker()
    private let highlight = DropHighlightPanel()
    private let animator = WindowAnimator()
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private var bars: [UUID: ShelfButtonPanel] = [:]
    private var hiddenBars: Set<UUID> = []
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

    func start() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        tracker.onEvent = { [weak self] event, windowID in self?.handle(event, windowID) }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(applicationTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
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
        for info in WindowList.copy(onScreenOnly: false) where info.layer == 0 && info.pid != ownPID {
            SkyLight.shared.setAlpha(1, for: info.id)
        }
        for id in Array(store.shelves.keys) {
            _ = store.dissolve(id)
        }
        for id in Array(bars.keys) {
            removeBar(id)
        }
        tracker.unwatchAll()
        shelfFrames.removeAll()
        originalFrames.removeAll()
        titles.removeAll()
        minimizedShelves.removeAll()
        lightsOffsets.removeAll()
        hidden.removeAll()
        parked.removeAll()
        pendingSync.removeAll()
        highlight.hide()
    }

    // MARK: - Input

    func mouseDown(at point: CGPoint) {
        dragTarget = nil
        dragSource = nil
        for info in WindowList.copy(onScreenOnly: true) where info.bounds.contains(point) {
            if info.pid == ownPID { return }
            if WindowList.isCandidate(info) {
                dragSource = info
                return
            }
        }
    }

    func mouseDragged(at point: CGPoint, flags: CGEventFlags) {
        guard dragSource != nil else { return }
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
        let source = dragSource
        let target = dragTarget
        dragSource = nil
        dragTarget = nil
        highlight.hide()

        if let source, let target {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [self] in
                mergeDragged(source: source, target: target)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            raiseBars()
        }
    }

    func handleShortcut(delta: Int) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ownPID,
              let windowID = AXWindow.focusedWindowID(pid: app.processIdentifier),
              let next = store.step(from: windowID, by: delta) else { return false }
        switchTo(next)
        return true
    }

    private func updateDropTarget(at point: CGPoint, flags: CGEventFlags) {
        guard let source = dragSource else { return }
        let list = WindowList.copy(onScreenOnly: true)
        let modifier = flags.contains(AppSettings.mergeModifier.flag)
        let moving = list.first { $0.id == source.id }.map { $0.bounds.origin != source.bounds.origin } ?? false
        let excluded = Set(store.shelf(containing: source.id)?.windowIDs ?? [source.id])
        var target = list.first {
            WindowList.isCandidate($0) && $0.bounds.contains(point) && !excluded.contains($0.id)
        }
        if let candidate = target, !modifier, !(moving && Self.mergeZone(of: candidate.bounds).contains(point)) {
            target = nil
        }
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
            refreshBar(shelf.id)
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
        placeBar(id)
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

    private func poll() {
        guard !store.shelves.isEmpty else { return }
        let all = WindowList.copy(onScreenOnly: false)
        let gone = store.allWindowIDs.subtracting(all.map(\.id))
        if !gone.isEmpty {
            removeWindows(gone)
        }
        let onScreen = Set(all.filter(\.isOnScreen).map(\.id))
        for id in store.shelves.keys {
            updateBarVisibility(id, onScreen: onScreen)
        }
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let gone = Set(tracker.windowIDs(forPID: app.processIdentifier))
        if !gone.isEmpty {
            removeWindows(gone)
        }
    }

    @objc private func applicationActivated() {
        raiseBars()
    }

    @objc private func spaceChanged() {
        poll()
        raiseBars()
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

    private func placeBar(_ id: UUID) {
        guard !hiddenBars.contains(id),
              let shelf = store.shelves[id],
              let bar = bars[id],
              let frame = shelfFrames[id] else { return }
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

    private func raiseBars() {
        for id in bars.keys {
            placeBar(id)
        }
    }

    private func updateBarVisibility(_ id: UUID, onScreen: Set<CGWindowID>? = nil) {
        guard let shelf = store.shelves[id], let element = tracker.element(of: shelf.activeWindowID) else { return }
        let active = shelf.activeWindowID
        let visible = !AXWindow.isMinimized(element)
            && !AXWindow.isFullScreen(element)
            && (onScreen?.contains(active) ?? true)

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

    func shelfDissolve(_ id: UUID) {
        guard let shelf = store.shelves[id] else { return }
        let fallbacks = fallbackFrames(forShelvesOf: shelf.windowIDs)
        let change = store.dissolve(id)
        reconcile(change, fallbacks: fallbacks, hints: [:], focus: [])
    }
}
