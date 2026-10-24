import AppKit

// AppKit tabs are separate windows sharing one frame. Only the selected tab's window is exposed
// through AX, so tabs are read from the tab bar and a shelf member follows the selected tab.
extension ShelfController {
    func refreshNativeTabs(_ member: CGWindowID) {
        guard let pid = tracker.pid(of: member), NativeTabs.supports(pid: pid),
              let element = tracker.element(of: member) else { return }
        var tabs: [NativeTab] = []
        if let buttons = AXWindow.tabButtons(of: element), buttons.count >= 2 {
            tabs = buttons.map { NativeTab(title: AXWindow.title(of: $0), selected: AXWindow.isSelectedTab($0)) }
        }
        members[member]?.nativeTabs = tabs.isEmpty ? nil : tabs
    }

    func syntheticTabID(member: CGWindowID, index: Int) -> CGWindowID {
        0x8000_0000 | ((member & 0x00FF_FFFF) << 6) | CGWindowID(index & 0x3F)
    }

    func memberID(for windowID: CGWindowID) -> CGWindowID? {
        if store.shelf(containing: windowID) != nil { return windowID }
        return syntheticTabs[windowID]?.member
    }

    // A native-tab member counts as shown while any window of its app sits exactly on the shelf frame.
    func isShown(_ member: CGWindowID, in screen: OnScreenWindows) -> Bool {
        if screen.memberIDs.contains(member) { return true }
        guard members[member]?.nativeTabs != nil, let pid = tracker.pid(of: member),
              let frame = store.shelf(containing: member).flatMap({ shelfFrames[$0.id] }) else { return false }
        return screen.all.contains { $0.pid == pid && $0.layer == 0 && Self.approximatelyEqual($0.bounds, frame) }
    }

    func survivingNativeTab(of member: CGWindowID) -> CGWindowID? {
        guard let pid = tracker.pid(of: member), let shelf = store.shelf(containing: member),
              let frame = shelfFrames[shelf.id],
              let focused = AXWindow.focusedWindowID(pid: pid), focused != member,
              store.shelf(containing: focused) == nil,
              let element = AXWindow.element(pid: pid, id: focused),
              let focusedFrame = AXWindow.frame(of: element),
              Self.approximatelyEqual(frame, focusedFrame) else { return nil }
        return focused
    }

    func unwatchedWindowFocused(_ windowID: CGWindowID, element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, NativeTabs.supports(pid: pid) else { return }
        if !nativeTabFocused(windowID, element: element, pid: pid) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.nativeTabFocused(windowID, element: element, pid: pid)
            }
        }
    }

    @discardableResult
    private func nativeTabFocused(_ windowID: CGWindowID, element: AXUIElement, pid: pid_t) -> Bool {
        guard store.shelf(containing: windowID) == nil,
              AXWindow.focusedWindowID(pid: pid) == windowID,
              let frame = AXWindow.frame(of: element),
              (AXWindow.tabButtons(of: element)?.count ?? 0) >= 2 else { return false }
        let candidates = store.shelves.values.compactMap { shelf -> CGWindowID? in
            let active = shelf.activeWindowID
            guard tracker.pid(of: active) == pid,
                  let shelfFrame = shelfFrames[shelf.id], Self.approximatelyEqual(shelfFrame, frame),
                  WindowList.describe([active]).first?.isOnScreen != true else { return nil }
            return active
        }
        guard candidates.count == 1, let old = candidates.first, adoptNativeTab(windowID, replacing: old) else { return false }
        refreshNativeTabs(windowID)
        nativeTabsChanged(windowID)
        return true
    }

    func selectNativeTab(member: CGWindowID, index: Int) {
        guard let pid = tracker.pid(of: member), let element = tracker.element(of: member),
              let shelfID = store.shelf(containing: member)?.id,
              let buttons = AXWindow.tabButtons(of: element), buttons.indices.contains(index) else { return }
        AXWindow.press(buttons[index])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.adoptShownNativeTab(pid: pid, shelfID: shelfID)
        }
    }

    // After a tab press the newly selected tab's window takes the shelf frame; focus may lag behind.
    private func adoptShownNativeTab(pid: pid_t, shelfID: UUID) {
        guard let shelf = store.shelves[shelfID], let frame = shelfFrames[shelfID] else { return }
        let onScreen = WindowList.copy(onScreenOnly: true)
        let onScreenIDs = Set(onScreen.map(\.id))
        guard let shown = onScreen.first(where: {
                  $0.pid == pid && $0.layer == 0 && store.shelf(containing: $0.id) == nil
                      && Self.approximatelyEqual($0.bounds, frame)
              }),
              let old = shelf.windowIDs.first(where: {
                  tracker.pid(of: $0) == pid && members[$0]?.nativeTabs != nil && !onScreenIDs.contains($0)
              }),
              adoptNativeTab(shown.id, replacing: old) else { return }
        refreshNativeTabs(shown.id)
        nativeTabsChanged(shown.id)
    }

    func adoptNativeTab(_ new: CGWindowID, replacing old: CGWindowID) -> Bool {
        guard store.shelf(containing: new) == nil, store.shelf(containing: old) != nil,
              let pid = tracker.pid(of: old), tracker.watch(windowID: new, pid: pid),
              let element = tracker.element(of: new) else { return false }
        store.replace(old, with: new)
        animator.cancel(old)
        var state = members.removeValue(forKey: old) ?? MemberState()
        if state.hidden {
            SkyLight.shared.setAlpha(1, for: old)
        }
        state.hidden = false
        state.parked = false
        state.title = AXWindow.title(of: element)
        members[new] = state
        snapRecords[new] = snapRecords.removeValue(forKey: old)
        tracker.unwatch(windowID: old)
        return true
    }

    func nativeTabsChanged(_ member: CGWindowID) {
        guard let shelf = store.shelf(containing: member) else { return }
        refreshBar(shelf.id)
        guard shelf.activeWindowID == member else { return }
        activeFrameChanged(shelf.id)
        updateBarVisibility(shelf.id)
    }

    func ensureTabBar(_ windowID: CGWindowID, pid: pid_t, shelf: Shelf) {
        guard let state = members[windowID], !state.tabBarEnsured, state.tabBarAttempts < 2,
              NativeTabs.supports(pid: pid) else { return }
        let pids = Set(shelf.windowIDs.compactMap { tracker.pid(of: $0) })
        guard pids.count > 1 else { return }
        members[windowID]?.tabBarAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.store.shelf(containing: windowID) != nil,
                  self.members[windowID]?.tabBarEnsured == false else { return }
            self.members[windowID]?.tabBarEnsured = NativeTabs.showTabBar(pid: pid)
        }
    }
}
