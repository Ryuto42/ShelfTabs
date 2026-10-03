import AppKit

final class WindowAnimator: NSObject {
    static let duration: CFTimeInterval = 0.22
    private static let slowResizeThreshold: CFTimeInterval = 0.008

    private struct Job {
        let element: AXUIElement
        let from: CGRect
        let to: CGRect?
        let alphaFrom: Float
        let alphaTo: Float
        let start: CFTimeInterval
        let completion: (() -> Void)?
        var lastPosition: CGPoint?
        var lastSize: CGSize?
        var resizeIsSlow = false
    }

    // AX writes block until the target app responds, so they run off the main thread.
    private let queue = DispatchQueue(label: "ShelfTabs.WindowAnimator", qos: .userInteractive)
    private var jobs: [CGWindowID: Job] = [:]
    private var inFlight: Set<CGWindowID> = []
    private var finishing: Set<CGWindowID> = []
    private var displayLink: CADisplayLink?

    func isAnimating(_ windowID: CGWindowID) -> Bool {
        jobs[windowID] != nil || finishing.contains(windowID)
    }

    func animate(
        _ windowID: CGWindowID,
        element: AXUIElement,
        from: CGRect,
        to: CGRect?,
        alphaFrom: Float = 1,
        alphaTo: Float = 1,
        completion: (() -> Void)? = nil
    ) {
        jobs[windowID] = Job(
            element: element,
            from: from,
            to: to,
            alphaFrom: alphaFrom,
            alphaTo: alphaTo,
            start: CACurrentMediaTime(),
            completion: completion
        )
        guard displayLink == nil,
              let link = (NSScreen.main ?? NSScreen.screens.first)?.displayLink(target: self, selector: #selector(step)) else { return }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func cancel(_ windowID: CGWindowID) {
        guard jobs.removeValue(forKey: windowID) != nil || inFlight.contains(windowID) || finishing.contains(windowID) else { return }
        queue.sync {}
        inFlight.remove(windowID)
        finishing.remove(windowID)
    }

    func cancelAll() {
        jobs.removeAll()
        stopDisplayLink()
        queue.sync {}
        inFlight.removeAll()
        finishing.removeAll()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step() {
        let now = CACurrentMediaTime()

        for (windowID, job) in jobs {
            let t = min((now - job.start) / Self.duration, 1)
            let eased = CGFloat(1 - pow(1 - t, 3))

            if job.alphaFrom != job.alphaTo {
                SkyLight.shared.setAlpha(job.alphaFrom + (job.alphaTo - job.alphaFrom) * Float(eased), for: windowID)
            }

            if t >= 1 {
                jobs.removeValue(forKey: windowID)
                finish(windowID, job: job)
                continue
            }

            guard let to = job.to, !inFlight.contains(windowID) else { continue }
            let position = CGPoint(
                x: (job.from.minX + (to.minX - job.from.minX) * eased).rounded(),
                y: (job.from.minY + (to.minY - job.from.minY) * eased).rounded()
            )
            var size: CGSize?
            if job.from.size != to.size, !job.resizeIsSlow {
                size = CGSize(
                    width: (job.from.width + (to.width - job.from.width) * eased).rounded(),
                    height: (job.from.height + (to.height - job.from.height) * eased).rounded()
                )
                if size == job.lastSize { size = nil }
            }
            let movePosition = position != job.lastPosition ? position : nil
            guard movePosition != nil || size != nil else { continue }

            jobs[windowID]?.lastPosition = position
            if let size { jobs[windowID]?.lastSize = size }
            inFlight.insert(windowID)
            let element = job.element
            queue.async { [weak self] in
                if let movePosition {
                    AXWindow.setPosition(movePosition, of: element)
                }
                var slow = false
                if let size {
                    let started = CACurrentMediaTime()
                    AXWindow.setSize(size, of: element)
                    slow = CACurrentMediaTime() - started > Self.slowResizeThreshold
                }
                DispatchQueue.main.async {
                    self?.inFlight.remove(windowID)
                    if slow {
                        self?.jobs[windowID]?.resizeIsSlow = true
                    }
                }
            }
        }

        if jobs.isEmpty {
            stopDisplayLink()
        }
    }

    private func finish(_ windowID: CGWindowID, job: Job) {
        finishing.insert(windowID)
        let element = job.element
        let to = job.to
        queue.async { [weak self] in
            if let to {
                AXWindow.setFrame(to, of: element)
            }
            DispatchQueue.main.async {
                guard let self, self.finishing.remove(windowID) != nil else { return }
                self.inFlight.remove(windowID)
                job.completion?()
            }
        }
    }
}
