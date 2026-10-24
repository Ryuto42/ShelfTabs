import AppKit

struct NativeTab {
    let title: String
    let selected: Bool
}

struct MemberState {
    var originalFrame: CGRect?
    var title = ""
    var lightsOffset: CGRect?
    var hidden = false
    var parked = false
    var tabBarEnsured = false
    var tabBarAttempts = 0
    var nativeTabs: [NativeTab]?
}

enum BarHiddenReason {
    case state, poll
}

struct SnapRecord {
    var restore: CGRect
    var snapped: CGRect
}

final class ShelfController: NSObject {
    let store = ShelfStore()
    let tracker = WindowTracker()
    let highlight = DropHighlightPanel(color: .systemBlue)
    let snapPreview = DropHighlightPanel(color: .systemGray)
    let animator = WindowAnimator()
    let nativeWatcher = NativeWindowWatcher()
    let nativeHover = NativeTabHover()
    let journal = ParkedJournal()
    let ownPID = ProcessInfo.processInfo.processIdentifier

    var onShelfPIDsChanged: ((Set<pid_t>) -> Void)?

    var members: [CGWindowID: MemberState] = [:] {
        didSet { scheduleStateCheck() }
    }
    var shelfFrames: [UUID: CGRect] = [:]
    var bars: [UUID: ShelfButtonPanel] = [:]
    var barHidden: [UUID: BarHiddenReason] = [:]
    var minimizedShelves: Set<UUID> = []
    var syntheticTabs: [CGWindowID: (member: CGWindowID, index: Int)] = [:]
    var pendingSync: [UUID: Bool] = [:]
    var ignoreFocusUntil = Date.distantPast
    var pollTimer: Timer?

    var nativeMergeMinimized: Set<CGWindowID> = []
    var pendingNativeWindows: [pid_t: [AXUIElement]] = [:]
    var pendingNativeWork: [pid_t: DispatchWorkItem] = [:]
    var nativeMergeTails: [pid_t: (token: Int, task: Task<Void, Never>)] = [:]
    var nativeMergeToken = 0

    var dragSource: WindowInfo?
    var dragTarget: WindowInfo?
    var dragMoved = false
    var lastDragEvaluation: CFTimeInterval = 0
    var liveMoveShelf: UUID?
    var snapRecords: [CGWindowID: SnapRecord] = [:]
    var snapAction: LayoutAction?
    var snapVisible = CGRect.zero
    var snapFrame: CGRect?
    var snapBottomEntry: Int?

    private var stateCheckScheduled = false
    private var publishedPIDs: Set<pid_t> = []
    private var journaledIDs: Set<CGWindowID> = []

    func start() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        tracker.onEvent = { [weak self] event, windowID in self?.handle(event, windowID) }
        tracker.onUnwatchedFocus = { [weak self] windowID, element in self?.unwatchedWindowFocused(windowID, element: element) }
        nativeWatcher.onWindowCreated = { [weak self] element, pid, mousePressed in
            // A window made while dragging is a tab the user pulled out on purpose.
            guard !mousePressed else { return }
            self?.queueNativeWindow(element, pid: pid)
        }
        accessibilityGranted()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(applicationTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationHidden(_:)), name: NSWorkspace.didHideApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationUnhidden(_:)), name: NSWorkspace.didUnhideApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    func accessibilityGranted() {
        guard AXIsProcessTrusted() else { return }
        nativeWatcher.start()
        nativeHover.update(frontmost: NSWorkspace.shared.frontmostApplication)
        journal.recover()
    }

    func restoreAll() {
        animator.cancelAll()
        for shelf in store.shelves.values {
            let shelfFrame = shelfFrames[shelf.id]
            for windowID in shelf.windowIDs {
                guard let element = tracker.element(of: windowID) else { continue }
                let original = members[windowID]?.originalFrame.flatMap { Geometry.intersectsAnyScreen(axRect: $0) ? $0 : nil }
                let target = original ?? shelfFrame ?? AXWindow.frame(of: element).map(Geometry.clampedIntoVisibleScreen)
                if let target {
                    AXWindow.setFrame(target, of: element)
                }
            }
        }
        SkyLight.shared.resetAllAlpha()
        for id in Array(store.shelves.keys) {
            _ = store.dissolve(id)
        }
        for id in Array(bars.keys) {
            removeBar(id)
        }
        tracker.unwatchAll()
        updatePolling()
        shelfFrames.removeAll()
        members.removeAll()
        minimizedShelves.removeAll()
        syntheticTabs.removeAll()
        pendingSync.removeAll()
        highlight.hide()
        clearSnap()
        snapRecords.removeAll()
        journal.recover()
        checkState()
        journal.flush()
    }

    // MARK: - Shared state

    private func scheduleStateCheck() {
        guard !stateCheckScheduled else { return }
        stateCheckScheduled = true
        DispatchQueue.main.async { [weak self] in self?.checkState() }
    }

    private func checkState() {
        stateCheckScheduled = false
        let pids = Set(store.allWindowIDs.compactMap { tracker.pid(of: $0) })
        if pids != publishedPIDs {
            publishedPIDs = pids
            onShelfPIDsChanged?(pids)
        }

        let hiddenIDs = Set(members.filter(\.value.hidden).map(\.key))
        guard hiddenIDs != journaledIDs else { return }
        journaledIDs = hiddenIDs
        journal.update(hiddenIDs.sorted().compactMap { windowID in
            guard let pid = tracker.pid(of: windowID),
                  let frame = store.shelf(containing: windowID).flatMap({ shelfFrames[$0.id] }) ?? members[windowID]?.originalFrame
            else { return nil }
            return ParkedJournal.Entry(
                pid: pid,
                windowID: windowID,
                bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                restoreFrame: frame
            )
        })
    }

    // MARK: - Window state

    func register(windowID: CGWindowID, pid: pid_t) -> Bool {
        guard tracker.watch(windowID: windowID, pid: pid),
              let element = tracker.element(of: windowID) else { return false }
        guard AXWindow.isStandard(element) else {
            tracker.unwatch(windowID: windowID)
            return false
        }
        var state = members[windowID] ?? MemberState()
        if state.originalFrame == nil {
            state.originalFrame = AXWindow.frame(of: element)
        }
        state.title = AXWindow.title(of: element)
        members[windowID] = state
        return true
    }

    func release(_ windowID: CGWindowID) {
        tracker.unwatch(windowID: windowID)
        members.removeValue(forKey: windowID)
    }

    func free(_ windowID: CGWindowID, fallback: CGRect?, restore: Bool) {
        animator.cancel(windowID)
        if let element = tracker.element(of: windowID), let state = members[windowID] {
            let wasHidden = state.hidden
            let original = state.originalFrame.flatMap { Geometry.intersectsAnyScreen(axRect: $0) ? $0 : nil }
            let parkedFallback = wasHidden ? AXWindow.frame(of: element).map(Geometry.clampedIntoVisibleScreen) : nil
            if restore || wasHidden, let target = original ?? fallback ?? parkedFallback {
                let current = state.parked ? fallback : AXWindow.frame(of: element)
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

    func hide(_ windowID: CGWindowID, frame: CGRect, animated: Bool) {
        guard let element = tracker.element(of: windowID), let state = members[windowID] else { return }
        animator.cancel(windowID)
        members[windowID]?.hidden = true
        if animated, !state.hidden, SkyLight.shared.isAlphaSupported, let current = AXWindow.frame(of: element) {
            animator.animate(windowID, element: element, from: current, to: nil, alphaFrom: 1, alphaTo: 0) { [weak self] in
                guard let self, self.members[windowID]?.hidden == true else { return }
                self.park(windowID, element: element, frame: frame)
            }
            return
        }
        park(windowID, element: element, frame: frame)
    }

    func park(_ windowID: CGWindowID, element: AXUIElement, frame: CGRect) {
        // A minimized member stays in the Dock; show() brings it back when it is selected.
        if AXWindow.isMinimized(element) {
            members[windowID]?.parked = false
            return
        }
        if SkyLight.shared.setAlpha(0, for: windowID) {
            members[windowID]?.parked = false
            AXWindow.setFrame(frame, of: element)
        } else {
            let size = AXWindow.frame(of: element)?.size ?? frame.size
            AXWindow.setPosition(Geometry.hidingOrigin(for: CGRect(origin: frame.origin, size: size)), of: element)
            members[windowID]?.parked = true
        }
    }

    func reparkHidden(pid: pid_t? = nil) {
        for shelf in store.shelves.values {
            guard let frame = shelfFrames[shelf.id] else { continue }
            for windowID in shelf.windowIDs where windowID != shelf.activeWindowID && members[windowID]?.hidden == true {
                guard pid == nil || tracker.pid(of: windowID) == pid, let element = tracker.element(of: windowID) else { continue }
                animator.cancel(windowID)
                park(windowID, element: element, frame: frame)
            }
        }
    }

    @discardableResult
    func show(_ windowID: CGWindowID, frame: CGRect, animated: Bool, completion: (() -> Void)? = nil) -> Bool {
        guard let element = tracker.element(of: windowID) else { return false }
        animator.cancel(windowID)
        if AXWindow.isMinimized(element) {
            AXWindow.setMinimized(false, of: element)
        }
        let wasHidden = members[windowID]?.hidden ?? false
        members[windowID]?.hidden = false
        members[windowID]?.parked = false

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

    func applyShelf(_ id: UUID, frame: CGRect, focus: Bool, animated: Bool) {
        guard let shelf = store.shelves[id] else { return }
        let active = shelf.activeWindowID
        display(id, active: active, frame: frame, hiding: shelf.windowIDs.filter { $0 != active }, animated: animated, focus: focus)
    }

    func switchTo(_ windowID: CGWindowID) {
        guard let shelf = store.shelf(containing: windowID) else { return }
        guard shelf.activeWindowID != windowID else {
            focusWindow(windowID)
            return
        }
        let old = shelf.activeWindowID
        guard let frame = tracker.element(of: old).flatMap({ AXWindow.frame(of: $0) }) ?? shelfFrames[shelf.id] else { return }
        store.setActive(windowID)
        display(shelf.id, active: windowID, frame: frame, hiding: [old], animated: false, focus: true)
    }

    private func display(_ id: UUID, active: CGWindowID, frame: CGRect, hiding: [CGWindowID], animated: Bool, focus: Bool) {
        let animating = show(active, frame: frame, animated: animated) { [weak self] in
            self?.activeFrameChanged(id)
            if focus, self?.store.shelves[id]?.activeWindowID == active {
                self?.ignoreFocusUntil = Date().addingTimeInterval(0.4)
                self?.focusWindow(active)
            }
        }
        for windowID in hiding {
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
        updateBarVisibility(id)
        if focus, !animating {
            focusWindow(active)
        }
    }

    func focusWindow(_ windowID: CGWindowID) {
        guard let element = tracker.element(of: windowID), let pid = tracker.pid(of: windowID) else { return }
        AXWindow.focus(element, pid: pid)
        // The app raises its window asynchronously after activation, which can cover the button.
        guard let shelf = store.shelf(containing: windowID) else { return }
        let id = shelf.id
        ensureTabBar(windowID, pid: pid, shelf: shelf)
        for delay in [0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.placeBar(id) }
        }
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
                members[windowID]?.title = AXWindow.title(of: element)
            }
            if bars[shelf.id]?.isPopupOpen == true {
                refreshBar(shelf.id)
            }
        case .focused:
            refreshNativeTabs(windowID)
            if windowID != shelf.activeWindowID, Date() > ignoreFocusUntil,
               let pid = tracker.pid(of: windowID), AXWindow.focusedWindowID(pid: pid) == windowID {
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
        guard !nativeMergeMinimized.contains(windowID), let shelf = store.shelves[id], let element = tracker.element(of: windowID) else { return }
        let minimized = AXWindow.isMinimized(element)

        if minimized, !minimizedShelves.contains(id) {
            minimizedShelves.insert(id)
            for member in shelf.windowIDs where member != windowID {
                guard let memberElement = tracker.element(of: member) else { continue }
                animator.cancel(member)
                if members[member]?.parked == true, let frame = shelfFrames[id] {
                    AXWindow.setFrame(frame, of: memberElement)
                    members[member]?.parked = false
                }
                SkyLight.shared.setAlpha(1, for: member)
                AXWindow.setMinimized(true, of: memberElement)
            }
        } else if !minimized, minimizedShelves.contains(id) {
            // Siblings stay minimized until switched to, so they can never cover the restored tab.
            minimizedShelves.remove(id)
            store.setActive(windowID)
            for member in shelf.windowIDs where member != windowID {
                members[member]?.hidden = true
                members[member]?.parked = false
            }
            if let frame = AXWindow.frame(of: element) ?? shelfFrames[id] {
                applyShelf(id, frame: frame, focus: true, animated: false)
            }
        } else if !minimized, windowID != shelf.activeWindowID, members[windowID]?.hidden == true {
            switchTo(windowID)
        }
    }

    func activeFrameChanged(_ id: UUID) {
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

    func scheduleSync(_ id: UUID, sizeChanged: Bool) {
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
        for windowID in shelf.windowIDs where windowID != shelf.activeWindowID && members[windowID]?.parked != true {
            guard let element = tracker.element(of: windowID) else { continue }
            if sizeChanged {
                AXWindow.setFrame(frame, of: element)
            } else {
                AXWindow.setPosition(frame.origin, of: element)
            }
        }
    }

    // A backstop for missed AX notifications; only runs while shelves exist.
    func updatePolling() {
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
        let memberIDs = store.allWindowIDs
        let infos = WindowList.describe(Array(memberIDs))
        let gone = memberIDs.subtracting(infos.map(\.id))
        if !gone.isEmpty {
            removeWindows(gone)
        }
        let screen = OnScreenWindows(memberIDs: Set(infos.filter(\.isOnScreen).map(\.id)))
        for (id, shelf) in store.shelves {
            if full {
                updateBarVisibility(id, screen: screen)
            } else if !isShown(shelf.activeWindowID, in: screen) {
                if barHidden[id] == nil {
                    barHidden[id] = .poll
                    bars[id]?.hide()
                }
            } else if barHidden[id] == .poll {
                barHidden[id] = nil
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
        nativeHover.update(frontmost: notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        raiseBars()
    }

    @objc private func applicationHidden(_ notification: Notification) {
        refreshVisibility(full: true)
    }

    @objc private func applicationUnhidden(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        reparkHidden(pid: app.processIdentifier)
        refreshVisibility(full: true)
    }

    @objc private func spaceChanged() {
        refreshVisibility(full: true)
    }

    @objc private func screensChanged() {
        reparkHidden()
        refreshVisibility(full: true)
    }

    static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

// On-screen window ids of shelf members, plus a lazily fetched full on-screen list.
final class OnScreenWindows {
    let memberIDs: Set<CGWindowID>
    private(set) lazy var all = WindowList.copy(onScreenOnly: true)

    init(memberIDs: Set<CGWindowID>) {
        self.memberIDs = memberIDs
    }
}
