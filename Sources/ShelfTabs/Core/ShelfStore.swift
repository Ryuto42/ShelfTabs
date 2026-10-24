import AppKit

enum ShelfAccent: Int, CaseIterable {
    case blue, purple, pink, red, orange, yellow, green, gray

    var label: String {
        switch self {
        case .blue: loc("ブルー")
        case .purple: loc("パープル")
        case .pink: loc("ピンク")
        case .red: loc("レッド")
        case .orange: loc("オレンジ")
        case .yellow: loc("イエロー")
        case .green: loc("グリーン")
        case .gray: loc("グレー")
        }
    }

    var color: NSColor {
        switch self {
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .gray: .systemGray
        }
    }
}

struct Shelf {
    let id: UUID
    var name: String
    var accent: ShelfAccent
    var windowIDs: [CGWindowID]
    var activeIndex: Int

    var activeWindowID: CGWindowID { windowIDs[activeIndex] }
}

struct ShelfChange {
    var touched: Set<UUID> = []
    var freed: [CGWindowID] = []
}

final class ShelfStore {
    private(set) var shelves: [UUID: Shelf] = [:]
    private var membership: [CGWindowID: UUID] = [:]
    private var createdCount = 0

    var allWindowIDs: Set<CGWindowID> { Set(membership.keys) }

    func shelf(containing windowID: CGWindowID) -> Shelf? {
        membership[windowID].flatMap { shelves[$0] }
    }

    func merge(source: CGWindowID, into target: CGWindowID) -> (id: UUID, change: ShelfChange)? {
        guard source != target else { return nil }
        let sourceShelfID = membership[source]
        let targetShelfID = membership[target]

        if let sourceShelfID, sourceShelfID == targetShelfID {
            setActive(source)
            return (sourceShelfID, ShelfChange(touched: [sourceShelfID]))
        }

        var change = ShelfChange()
        let incoming = sourceShelfID.flatMap { shelves[$0]?.windowIDs } ?? [source]

        let id: UUID
        if let targetShelfID {
            id = targetShelfID
        } else {
            id = makeShelf(with: target)
        }

        if let sourceShelfID {
            shelves.removeValue(forKey: sourceShelfID)
            change.touched.insert(sourceShelfID)
        }

        for windowID in incoming where membership[windowID] != id {
            shelves[id]?.windowIDs.append(windowID)
            membership[windowID] = id
        }
        setActive(source)
        change.touched.insert(id)
        return (id, change)
    }

    func move(_ windowID: CGWindowID, toShelf shelfID: UUID) -> ShelfChange {
        guard shelves[shelfID] != nil, membership[windowID] != shelfID else { return ShelfChange() }
        var change = ShelfChange()
        if let oldID = membership[windowID] {
            removeMember(windowID, from: oldID, destroyed: false, change: &change, freeRemoved: false)
        }
        shelves[shelfID]?.windowIDs.append(windowID)
        membership[windowID] = shelfID
        setActive(windowID)
        change.touched.insert(shelfID)
        return change
    }

    func detach(_ windowID: CGWindowID) -> ShelfChange {
        var change = ShelfChange()
        guard let id = membership[windowID] else { return change }
        removeMember(windowID, from: id, destroyed: false, change: &change, freeRemoved: true)
        return change
    }

    func remove(_ gone: Set<CGWindowID>) -> ShelfChange {
        var change = ShelfChange()
        for windowID in gone {
            guard let id = membership[windowID] else { continue }
            removeMember(windowID, from: id, destroyed: true, change: &change, freeRemoved: false)
        }
        return change
    }

    func dissolve(_ shelfID: UUID) -> ShelfChange {
        guard let shelf = shelves.removeValue(forKey: shelfID) else { return ShelfChange() }
        for windowID in shelf.windowIDs {
            membership.removeValue(forKey: windowID)
        }
        return ShelfChange(touched: [shelfID], freed: shelf.windowIDs)
    }

    func setActive(_ windowID: CGWindowID) {
        guard let id = membership[windowID],
              let index = shelves[id]?.windowIDs.firstIndex(of: windowID) else { return }
        shelves[id]?.activeIndex = index
    }

    func replace(_ old: CGWindowID, with new: CGWindowID) {
        guard old != new, membership[new] == nil, let id = membership[old],
              let index = shelves[id]?.windowIDs.firstIndex(of: old) else { return }
        shelves[id]?.windowIDs[index] = new
        membership.removeValue(forKey: old)
        membership[new] = id
    }

    func step(from windowID: CGWindowID, by delta: Int) -> CGWindowID? {
        guard let shelf = shelf(containing: windowID),
              let index = shelf.windowIDs.firstIndex(of: windowID) else { return nil }
        let count = shelf.windowIDs.count
        return shelf.windowIDs[((index + delta) % count + count) % count]
    }

    func reorder(_ shelfID: UUID, to order: [CGWindowID]) {
        guard let shelf = shelves[shelfID], order.count == shelf.windowIDs.count, Set(order) == Set(shelf.windowIDs),
              let index = order.firstIndex(of: shelf.activeWindowID) else { return }
        shelves[shelfID]?.windowIDs = order
        shelves[shelfID]?.activeIndex = index
    }

    func rename(_ shelfID: UUID, to name: String) {
        shelves[shelfID]?.name = name
    }

    func setAccent(_ shelfID: UUID, to accent: ShelfAccent) {
        shelves[shelfID]?.accent = accent
    }

    private func makeShelf(with windowID: CGWindowID) -> UUID {
        let accent = ShelfAccent.allCases[createdCount % ShelfAccent.allCases.count]
        createdCount += 1
        let shelf = Shelf(id: UUID(), name: "", accent: accent, windowIDs: [windowID], activeIndex: 0)
        shelves[shelf.id] = shelf
        membership[windowID] = shelf.id
        return shelf.id
    }

    private func removeMember(
        _ windowID: CGWindowID,
        from shelfID: UUID,
        destroyed: Bool,
        change: inout ShelfChange,
        freeRemoved: Bool
    ) {
        guard var shelf = shelves[shelfID],
              let removedIndex = shelf.windowIDs.firstIndex(of: windowID) else { return }

        shelf.windowIDs.remove(at: removedIndex)
        membership.removeValue(forKey: windowID)
        if freeRemoved { change.freed.append(windowID) }

        if removedIndex < shelf.activeIndex {
            shelf.activeIndex -= 1
        } else if removedIndex == shelf.activeIndex {
            shelf.activeIndex = min(removedIndex, max(shelf.windowIDs.count - 1, 0))
        }

        if shelf.windowIDs.count < 2 {
            shelves.removeValue(forKey: shelfID)
            for remaining in shelf.windowIDs {
                membership.removeValue(forKey: remaining)
                change.freed.append(remaining)
            }
        } else {
            shelves[shelfID] = shelf
        }
        change.touched.insert(shelfID)
    }
}
