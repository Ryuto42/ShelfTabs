import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = ShelfController()
    private let inputMonitor = InputMonitor()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var monitorRetryTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.registerDefaults()
        setUpStatusItem()
        setUpInput()
        controller.start()
        installSignalHandlers()

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            startMonitorRetry()
        } else if !inputMonitor.start() {
            if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
            startMonitorRetry()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        inputMonitor.stop()
        controller.restoreAll()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "ShelfTabs")

        let menu = NSMenu()
        menu.addItem(withTitle: "設定…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "すべてのウィンドウを復元", action: #selector(restoreAllWindows), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "ShelfTabs を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    private func setUpInput() {
        inputMonitor.onMouseDown = { [controller] point in controller.mouseDown(at: point) }
        inputMonitor.onMouseDragged = { [controller] point, flags in controller.mouseDragged(at: point, flags: flags) }
        inputMonitor.onMouseUp = { [controller] flags in controller.mouseUp(flags: flags) }
        inputMonitor.onFlagsChanged = { [controller] flags in controller.flagsChanged(flags) }
        inputMonitor.onShortcut = { [controller] action in controller.handleShortcut(action) }
    }

    private func startMonitorRetry() {
        monitorRetryTimer?.invalidate()
        monitorRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, AXIsProcessTrusted(), self.inputMonitor.start() else { return }
            timer.invalidate()
            self.monitorRetryTimer = nil
        }
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "ShelfTabs 設定"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func restoreAllWindows() {
        controller.restoreAll()
    }
}
