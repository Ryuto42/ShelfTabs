import AppKit

extension ShelfController {
    func ensureBar(_ id: UUID) -> ShelfButtonPanel {
        if let bar = bars[id] { return bar }
        let bar = ShelfButtonPanel(shelfID: id)
        bar.shelfDelegate = self
        bars[id] = bar
        return bar
    }

    func removeBar(_ id: UUID) {
        barHidden.removeValue(forKey: id)
        bars.removeValue(forKey: id)?.hide()
    }

    func refreshBar(_ id: UUID) {
        guard let shelf = store.shelves[id] else { return }
        let bar = ensureBar(id)
        let memberSet = Set(shelf.windowIDs)
        syntheticTabs = syntheticTabs.filter { !memberSet.contains($0.value.member) }
        let tabs = shelf.windowIDs.flatMap { member -> [TabInfo] in
            let app = tracker.pid(of: member).flatMap { NSRunningApplication(processIdentifier: $0) }
            let isActiveMember = member == shelf.activeWindowID
            guard let group = members[member]?.nativeTabs, group.contains(where: \.selected) else {
                return [TabInfo(
                    windowID: member,
                    memberID: member,
                    title: members[member]?.title ?? "",
                    appName: app?.localizedName ?? "",
                    icon: app?.icon,
                    isActive: isActiveMember
                )]
            }
            return group.enumerated().map { index, tab in
                let id = tab.selected ? member : syntheticTabID(member: member, index: index)
                if !tab.selected {
                    syntheticTabs[id] = (member, index)
                }
                return TabInfo(
                    windowID: id,
                    memberID: member,
                    title: tab.title,
                    appName: app?.localizedName ?? "",
                    icon: app?.icon,
                    isActive: tab.selected && isActiveMember
                )
            }
        }
        bar.update(name: shelf.name, accent: shelf.accent.color, tabs: tabs)
    }

    // Follows the window server's bounds during a user drag; AX move notifications arrive too late.
    func followLiveMove(_ windowID: CGWindowID) {
        guard let shelf = store.shelf(containing: windowID), shelf.activeWindowID == windowID,
              let bounds = WindowList.bounds(of: windowID) else { return }
        if liveMoveShelf == nil {
            guard bounds != shelfFrames[shelf.id] else { return }
            liveMoveShelf = shelf.id
        }
        placeBar(shelf.id, frame: bounds)
    }

    func raiseBars() {
        for id in bars.keys {
            placeBar(id)
        }
    }

    func placeBar(_ id: UUID, frame override: CGRect? = nil) {
        guard barHidden[id] == nil,
              let shelf = store.shelves[id],
              let bar = bars[id],
              let frame = override ?? shelfFrames[id] else { return }
        let active = shelf.activeWindowID
        if members[active]?.lightsOffset == nil,
           let element = tracker.element(of: active),
           let lights = AXWindow.trafficLightsFrame(of: element),
           let windowFrame = AXWindow.frame(of: element) {
            members[active]?.lightsOffset = lights.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
        }
        let lights = members[active]?.lightsOffset?.offsetBy(dx: frame.minX, dy: frame.minY)
        bar.place(windowAXFrame: frame, trafficLights: lights, above: active)
    }

    func updateBarVisibility(_ id: UUID, screen: OnScreenWindows? = nil) {
        guard let shelf = store.shelves[id], let element = tracker.element(of: shelf.activeWindowID) else { return }
        let active = shelf.activeWindowID
        let visible = !AXWindow.isMinimized(element)
            && !AXWindow.isFullScreen(element)
            && (screen.map { isShown(active, in: $0) } ?? true)

        if visible {
            barHidden.removeValue(forKey: id)
            placeBar(id)
        } else if barHidden[id] == nil {
            barHidden[id] = .state
            bars[id]?.hide()
        } else {
            barHidden[id] = .state
        }
    }
}

extension ShelfController: ShelfButtonDelegate {
    func shelf(_ id: UUID, selectWindow windowID: CGWindowID) {
        guard let (member, index) = syntheticTabs[windowID] else {
            switchTo(windowID)
            return
        }
        guard let shelf = store.shelf(containing: member) else { return }
        if shelf.activeWindowID != member {
            switchTo(member)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.selectNativeTab(member: member, index: index)
            }
        } else {
            selectNativeTab(member: member, index: index)
        }
    }

    func shelf(_ id: UUID, detachWindow windowID: CGWindowID) {
        guard syntheticTabs[windowID] == nil, store.shelf(containing: windowID) != nil else { return }
        detach(windowID)
    }

    func shelf(_ id: UUID, dropWindow windowID: CGWindowID) {
        guard store.shelves[id] != nil, let windowID = memberID(for: windowID),
              let source = store.shelf(containing: windowID), source.id != id else { return }
        moveIntoShelf(windowID, shelf: id)
    }

    func shelfCandidateWindows(_ id: UUID) -> [CandidateWindow] {
        let inShelves = store.allWindowIDs
        var elements: [pid_t: [CGWindowID: AXUIElement]] = [:]
        return WindowList.copy(onScreenOnly: true).compactMap { info in
            guard WindowList.isCandidate(info), !inShelves.contains(info.id) else { return nil }
            if elements[info.pid] == nil {
                let pairs = AXWindow.windows(pid: info.pid).compactMap { element in AXWindow.id(of: element).map { ($0, element) } }
                elements[info.pid] = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
            }
            guard let element = elements[info.pid]?[info.id], AXWindow.isStandard(element) else { return nil }
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
              let info = WindowList.describe([windowID]).first,
              register(windowID: windowID, pid: info.pid) else { return }
        moveIntoShelf(windowID, shelf: id)
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
        for member in store.shelves[id]?.windowIDs ?? [] {
            refreshNativeTabs(member)
        }
        refreshBar(id)
    }

    func shelfDissolve(_ id: UUID) {
        dissolve(id)
    }
}
