import AppKit

// Records windows ShelfTabs has moved out of sight so they can be brought back after a crash.
final class ParkedJournal {
    struct Entry: Codable, Equatable {
        let pid: pid_t
        let windowID: CGWindowID
        let bundleID: String?
        let restoreFrame: CGRect
    }

    private let url: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("ShelfTabs", isDirectory: true)
        .appendingPathComponent("parked.json")

    private var current: [Entry] = []
    private var leftover: [Entry] = []
    private var written: [Entry]?
    private var writeScheduled = false

    init() {
        guard let url, let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        leftover = entries
        written = entries
    }

    func update(_ entries: [Entry]) {
        current = entries
        scheduleWrite()
    }

    // Moves journaled windows that still exist back into a visible screen; needs Accessibility permission.
    func recover() {
        guard !leftover.isEmpty, AXIsProcessTrusted() else { return }
        let alive = Dictionary(WindowList.describe(leftover.map(\.windowID)).map { ($0.id, $0.pid) }, uniquingKeysWith: { a, _ in a })
        for entry in leftover where alive[entry.windowID] == entry.pid {
            guard let app = NSRunningApplication(processIdentifier: entry.pid),
                  entry.bundleID == nil || app.bundleIdentifier == entry.bundleID,
                  let element = AXWindow.element(pid: entry.pid, id: entry.windowID) else { continue }
            AXWindow.setFrame(Geometry.clampedIntoVisibleScreen(entry.restoreFrame), of: element)
            SkyLight.shared.setAlpha(1, for: entry.windowID)
        }
        leftover = []
        scheduleWrite()
    }

    func flush() {
        write()
    }

    private func scheduleWrite() {
        guard !writeScheduled else { return }
        writeScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.writeScheduled = false
            self?.write()
        }
    }

    private func write() {
        let currentIDs = Set(current.map(\.windowID))
        let entries = current + leftover.filter { !currentIDs.contains($0.windowID) }
        guard entries != written, let url else { return }
        written = entries
        do {
            if entries.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(entries).write(to: url, options: .atomic)
            }
        } catch {
            written = nil
            NSLog("ShelfTabs: failed to write parked journal: \(error.localizedDescription)")
        }
    }
}
