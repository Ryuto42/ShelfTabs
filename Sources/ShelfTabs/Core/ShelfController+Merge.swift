import AppKit

struct ShelfEdit {
    var change: ShelfChange
    var focus: UUID?
    var frame: CGRect?
}

extension ShelfController {
    // MARK: - Shelf edits

    @discardableResult
    func edit(
        affecting windowIDs: [CGWindowID],
        gone: Set<CGWindowID> = [],
        animated: Bool = false,
        restoreVisible: Bool = true,
        _ operation: () -> ShelfEdit?
    ) -> UUID? {
        let fallbacks = fallbackFrames(forShelvesOf: windowIDs)
        guard let edit = operation() else { return nil }
        for windowID in gone {
            release(windowID)
        }
        for windowID in edit.change.freed where !gone.contains(windowID) {
            free(windowID, fallback: fallbacks[windowID], restore: restoreVisible)
        }
        for id in edit.change.touched {
            let hint = id == edit.focus ? edit.frame : nil
            if store.shelves[id] != nil, let frame = hint ?? shelfFrames[id] {
                applyShelf(id, frame: frame, focus: id == edit.focus, animated: animated)
            } else {
                removeBar(id)
                shelfFrames.removeValue(forKey: id)
                minimizedShelves.remove(id)
            }
        }
        updatePolling()
        return edit.focus
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

    // MARK: - Merge / detach

    func mergeDragged(source: WindowInfo, target: WindowInfo) {
        if source.pid == target.pid, NativeTabs.supports(pid: source.pid),
           store.shelf(containing: source.id) == nil, store.shelf(containing: target.id) == nil,
           let targetElement = AXWindow.element(pid: target.pid, id: target.id) {
            enqueueNativeMerge(pid: target.pid) { [weak self] in
                await self?.mergeAllNatively(pid: target.pid, host: targetElement, keeping: [source.id, target.id]) { merged in
                    if !merged { self?.mergeIntoShelf(source: source, target: target) }
                }
            }
            return
        }
        mergeIntoShelf(source: source, target: target)
    }

    func mergeIntoShelf(source: WindowInfo, target: WindowInfo) {
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
            members[source.id]?.originalFrame = source.bounds
        }

        let frame = AXWindow.frame(of: targetElement) ?? target.bounds
        let id = edit(affecting: [source.id, target.id], animated: true) {
            store.merge(source: source.id, into: target.id).map { ShelfEdit(change: $0.change, focus: $0.id, frame: frame) }
        }
        if let id {
            scheduleNativeConsolidation(id)
        }
    }

    func moveIntoShelf(_ windowID: CGWindowID, shelf id: UUID) {
        edit(affecting: [windowID], animated: true) {
            ShelfEdit(change: store.move(windowID, toShelf: id), focus: id)
        }
        scheduleNativeConsolidation(id)
    }

    func detach(_ windowID: CGWindowID) {
        guard store.shelf(containing: windowID) != nil, let pid = tracker.pid(of: windowID) else { return }
        edit(affecting: [windowID]) { ShelfEdit(change: store.detach(windowID)) }

        guard let element = AXWindow.element(pid: pid, id: windowID) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + WindowAnimator.duration + 0.03) {
            AXWindow.focus(element, pid: pid)
        }
    }

    func dissolve(_ id: UUID) {
        guard let shelf = store.shelves[id] else { return }
        edit(affecting: shelf.windowIDs) { ShelfEdit(change: store.dissolve(id)) }
    }

    func removeWindows(_ gone: Set<CGWindowID>, deferTabs: Bool = true) {
        var gone = gone
        for windowID in gone where members[windowID]?.nativeTabs != nil {
            if let next = survivingNativeTab(of: windowID), adoptNativeTab(next, replacing: windowID) {
                gone.remove(windowID)
                refreshNativeTabs(next)
                nativeTabsChanged(next)
            } else if deferTabs {
                // The app selects the next tab slightly after the closed one disappears.
                gone.remove(windowID)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.store.shelf(containing: windowID) != nil,
                          WindowList.describe([windowID]).isEmpty else { return }
                    self.removeWindows([windowID], deferTabs: false)
                }
            }
        }
        guard !gone.isEmpty else { return }
        edit(affecting: Array(gone), gone: gone, restoreVisible: false) { ShelfEdit(change: store.remove(gone)) }
    }

    // MARK: - Native merging

    // Native merge sequences of one app run one at a time; each awaits the previous one.
    func enqueueNativeMerge(pid: pid_t, _ job: @escaping @MainActor () async -> Void) {
        nativeMergeToken += 1
        let token = nativeMergeToken
        let previous = nativeMergeTails[pid]?.task
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await job()
            guard let self, self.nativeMergeTails[pid]?.token == token else { return }
            self.nativeMergeTails.removeValue(forKey: pid)
        }
        nativeMergeTails[pid] = (token, task)
    }

    // "Merge All Windows" takes every visible window of the app, so the rest are minimized meanwhile.
    @MainActor
    func mergeAllNatively(
        pid: pid_t,
        host: AXUIElement,
        keeping: Set<CGWindowID>,
        then: @MainActor (Bool) async -> Void = { _ in }
    ) async {
        let others = AXWindow.windows(pid: pid).compactMap { element -> (CGWindowID, AXUIElement)? in
            guard let id = AXWindow.id(of: element), !keeping.contains(id),
                  AXWindow.isStandard(element), !AXWindow.isMinimized(element) else { return nil }
            return (id, element)
        }
        nativeMergeMinimized.formUnion(others.map(\.0))
        for (_, element) in others {
            AXWindow.setMinimized(true, of: element)
        }
        AXWindow.focus(host, pid: pid)
        await Self.pause(0.12)

        let merged = NativeTabs.mergeAllWindows(pid: pid)
        if merged {
            await Self.pause(0.35)
        }
        for (_, element) in others {
            AXWindow.setMinimized(false, of: element)
        }
        let restored = ContinuousClock.now
        await then(merged)
        if !others.isEmpty {
            await Self.pause(until: restored + .milliseconds(400))
            AXWindow.focus(host, pid: pid)
            await Self.pause(0.2)
            raiseBars()
        }
        await Self.pause(until: restored + .milliseconds(600))
        nativeMergeMinimized.subtract(others.map(\.0))
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func pause(until deadline: ContinuousClock.Instant) async {
        try? await Task.sleep(until: deadline, clock: .continuous)
    }

    // Several documents opened at once arrive as a burst; merge them together once it settles.
    func queueNativeWindow(_ element: AXUIElement, pid: pid_t) {
        pendingNativeWindows[pid, default: []].append(element)
        pendingNativeWork[pid]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let elements = self.pendingNativeWindows.removeValue(forKey: pid) else { return }
            self.pendingNativeWork.removeValue(forKey: pid)
            guard AppSettings.nativeTabsForNewWindows else { return }
            self.enqueueNativeMerge(pid: pid) { [weak self] in
                await self?.mergeNewNativeWindows(elements, pid: pid)
            }
        }
        pendingNativeWork[pid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    @MainActor
    private func mergeNewNativeWindows(_ elements: [AXUIElement], pid: pid_t) async {
        let created = elements.compactMap { element -> (CGWindowID, AXUIElement)? in
            guard let id = AXWindow.id(of: element), store.shelf(containing: id) == nil,
                  AXWindow.isStandard(element), AXWindow.hasZoomButton(element),
                  !AXWindow.isMinimized(element) else { return nil }
            return (id, element)
        }
        let createdIDs = Set(created.map(\.0))
        guard let last = created.last else { return }

        let existing = WindowList.copy(onScreenOnly: true).first { info in
            info.pid == pid && !createdIDs.contains(info.id) && WindowList.isCandidate(info)
                && members[info.id]?.hidden != true
        }
        let host: (CGWindowID, AXUIElement)
        if let existing, let element = AXWindow.element(pid: pid, id: existing.id),
           AXWindow.isStandard(element), AXWindow.hasZoomButton(element) {
            host = (existing.id, element)
        } else if created.count >= 2 {
            host = created[0]
        } else {
            return
        }
        guard NativeTabs.canMergeAll(pid: pid) else { return }

        let title = AXWindow.title(of: last.1)
        await mergeAllNatively(pid: pid, host: host.1, keeping: createdIDs.union([host.0])) { merged in
            guard merged else { return }
            await Self.pause(0.2)
            // Window titles may append page info ("name.pdf – 1 / 3 ページ"), so match the tab by prefix.
            let buttons = AXWindow.tabButtons(of: host.1) ?? []
            guard let button = buttons
                .map({ (button: $0, title: AXWindow.title(of: $0)) })
                .filter({ !$0.title.isEmpty && title.hasPrefix($0.title) })
                .max(by: { $0.title.count < $1.title.count })?.button else { return }
            AXWindow.press(button)
        }
    }

    func scheduleNativeConsolidation(_ id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + WindowAnimator.duration + 0.2) { [weak self] in
            guard let self, let shelf = self.store.shelves[id] else { return }
            let pids = Set(shelf.windowIDs.compactMap { self.tracker.pid(of: $0) }).filter(NativeTabs.supports(pid:))
            for pid in pids {
                self.enqueueNativeMerge(pid: pid) { [weak self] in
                    await self?.consolidateNativeTabs(id, pid: pid)
                }
            }
        }
    }

    // Finder / Preview windows sharing a shelf are combined into one window's native tabs.
    @MainActor
    private func consolidateNativeTabs(_ id: UUID, pid: pid_t) async {
        guard let shelf = store.shelves[id] else { return }
        let nativeMembers = shelf.windowIDs.filter { tracker.pid(of: $0) == pid }
        guard nativeMembers.count > 1 else { return }

        let host = nativeMembers.contains(shelf.activeWindowID) ? shelf.activeWindowID : nativeMembers[0]
        if host != shelf.activeWindowID {
            switchTo(host)
        }
        guard let hostElement = tracker.element(of: host),
              let hostFrame = AXWindow.frame(of: hostElement) ?? shelfFrames[id] else { return }

        // Absorbed windows must be on screen for the merge, and must not stay parked if it fails.
        let absorbed = nativeMembers.filter { $0 != host }
        let restoreInfo = absorbed.compactMap { windowID -> (AXUIElement, CGRect?)? in
            guard let element = tracker.element(of: windowID) else { return nil }
            animator.cancel(windowID)
            AXWindow.setFrame(hostFrame, of: element)
            SkyLight.shared.setAlpha(1, for: windowID)
            members[windowID]?.hidden = false
            members[windowID]?.parked = false
            return (element, members[windowID]?.originalFrame)
        }
        let absorbedSet = Set(absorbed)
        edit(affecting: absorbed, gone: absorbedSet, restoreVisible: false) { ShelfEdit(change: store.remove(absorbedSet)) }

        await mergeAllNatively(pid: pid, host: hostElement, keeping: absorbedSet.union([host])) { [weak self] merged in
            guard let self else { return }
            if !merged {
                for (element, original) in restoreInfo {
                    let target = original.flatMap { Geometry.intersectsAnyScreen(axRect: $0) ? $0 : nil } ?? hostFrame
                    AXWindow.raise(element)
                    AXWindow.setFrame(target, of: element)
                }
            }
            self.refreshNativeTabs(host)
            if let shelfID = self.store.shelf(containing: host)?.id {
                self.refreshBar(shelfID)
                self.placeBar(shelfID)
            }
        }
    }
}
