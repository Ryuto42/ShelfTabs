import CoreGraphics
import Darwin

final class SkyLight {
    static let shared = SkyLight()

    private typealias ConnectionFunction = @convention(c) () -> UInt32
    private typealias SetAlphaFunction = @convention(c) (UInt32, CGWindowID, Float) -> Int32
    private typealias GetAlphaFunction = @convention(c) (UInt32, CGWindowID, UnsafeMutablePointer<Float>) -> Int32

    private var connectionID: UInt32 = 0
    private var setAlphaFunction: SetAlphaFunction?
    private var getAlphaFunction: GetAlphaFunction?

    private init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connectionSymbol = dlsym(handle, "SLSMainConnectionID") else { return }
        connectionID = unsafeBitCast(connectionSymbol, to: ConnectionFunction.self)()
        setAlphaFunction = dlsym(handle, "SLSSetWindowAlpha").map { unsafeBitCast($0, to: SetAlphaFunction.self) }
        getAlphaFunction = dlsym(handle, "SLSGetWindowAlpha").map { unsafeBitCast($0, to: GetAlphaFunction.self) }
    }

    // Recent macOS silently ignores alpha changes on other processes' windows; once seen, stop calling.
    private(set) var isAlphaSupported = true
    private(set) var dimmedWindows: Set<CGWindowID> = []

    @discardableResult
    func setAlpha(_ alpha: Float, for windowID: CGWindowID) -> Bool {
        guard isAlphaSupported, connectionID != 0, let setAlphaFunction else { return false }
        guard setAlphaFunction(connectionID, windowID, alpha) == 0 else { return false }
        if alpha < 1 {
            dimmedWindows.insert(windowID)
        } else {
            dimmedWindows.remove(windowID)
        }
        guard let getAlphaFunction else { return true }
        var applied: Float = -1
        guard getAlphaFunction(connectionID, windowID, &applied) == 0 else { return true }
        if abs(applied - alpha) < 0.01 { return true }
        isAlphaSupported = false
        dimmedWindows.removeAll()
        return false
    }

    func resetAllAlpha() {
        for windowID in dimmedWindows {
            setAlpha(1, for: windowID)
        }
        dimmedWindows.removeAll()
    }
}
