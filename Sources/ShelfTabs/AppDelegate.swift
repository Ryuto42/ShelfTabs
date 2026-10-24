import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let controller = ShelfController()
    private let inputMonitor = InputMonitor()
    private let updater = MainActor.assumeIsolated { UpdateController() }
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var monitorRetryTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.registerDefaults()
        StyleCenter.start()
        setUpStatusItem()
        setUpInput()
        controller.start()
        installSignalHandlers()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil
        )

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
        menu.addItem(withTitle: loc("設定…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: loc("すべてのウィンドウを復元"), action: #selector(restoreAllWindows), keyEquivalent: "").target = self
        menu.addItem(withTitle: loc("アップデートを確認…"), action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: loc("ShelfTabs を終了"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    private func setUpInput() {
        inputMonitor.onMouseDown = { [controller] point in controller.mouseDown(at: point) }
        inputMonitor.onMouseDragged = { [controller] point, flags in controller.mouseDragged(at: point, flags: flags) }
        inputMonitor.onMouseUp = { [controller] flags in controller.mouseUp(flags: flags) }
        inputMonitor.onFlagsChanged = { [controller] flags in controller.flagsChanged(flags) }
        inputMonitor.onShortcut = { [controller] action in controller.handleShortcut(action) }
        controller.onShelfPIDsChanged = { [inputMonitor] pids in inputMonitor.update(shelfPIDs: pids) }
    }

    private func startMonitorRetry() {
        guard monitorRetryTimer == nil else { return }
        monitorRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, AXIsProcessTrusted(), self.inputMonitor.start() else { return }
            timer.invalidate()
            self.monitorRetryTimer = nil
            self.controller.accessibilityGranted()
        }
    }

    @objc private func applicationActivated(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        inputMonitor.update(frontmostPID: app?.processIdentifier ?? 0)
        // A revoked permission leaves a tap that can no longer act; stop it until permission returns.
        if inputMonitor.isRunning, !AXIsProcessTrusted() {
            inputMonitor.stop()
            startMonitorRetry()
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
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(updater: updater)))
            window.title = loc("ShelfTabs 設定")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        settingsWindow?.delegate = nil
        DispatchQueue.main.async { [weak self] in self?.settingsWindow = nil }
    }

    @objc private func restoreAllWindows() {
        controller.restoreAll()
    }

    @objc private func checkForUpdates() {
        MainActor.assumeIsolated { updater.checkForUpdates() }
    }
}
