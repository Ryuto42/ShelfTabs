import AppKit
import Combine
import ServiceManagement
import SwiftUI

private final class KeyMonitor {
    private var monitor: Any?

    func start(_ handler: @escaping (NSEvent) -> NSEvent?) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct ShortcutRecorderView: View {
    let title: String
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    let defaultShortcut: Shortcut

    @State private var isRecording = false
    @State private var keyMonitor = KeyMonitor()

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Button(action: toggleRecording) {
                    Text(isRecording ? "キーを押してください…" : Shortcut(keyCode: keyCode, modifiers: modifiers).displayString)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 110)
                }
                Button("初期値") {
                    stopRecording()
                    keyCode = defaultShortcut.keyCode
                    modifiers = defaultShortcut.modifiers
                }
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        keyMonitor.start { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            let captured = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !captured.isEmpty else { return nil }
            keyCode = Int(event.keyCode)
            modifiers = Int(bitPattern: captured.rawValue)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        keyMonitor.stop()
    }
}

struct SettingsView: View {
    @AppStorage(AppSettings.Key.mergeModifier) private var mergeModifier = MergeModifier.shift
    @AppStorage(AppSettings.Key.styleMode) private var styleMode = StyleMode.auto
    @AppStorage(AppSettings.Key.glassVariant) private var glassVariant = GlassVariant.regular
    @AppStorage(AppSettings.Key.themeMode) private var themeMode = ThemeMode.system
    @AppStorage(AppSettings.Key.previousTabKeyCode) private var previousKeyCode = AppSettings.defaultPreviousTab.keyCode
    @AppStorage(AppSettings.Key.previousTabModifiers) private var previousModifiers = AppSettings.defaultPreviousTab.modifiers
    @AppStorage(AppSettings.Key.nextTabKeyCode) private var nextKeyCode = AppSettings.defaultNextTab.keyCode
    @AppStorage(AppSettings.Key.nextTabModifiers) private var nextModifiers = AppSettings.defaultNextTab.modifiers
    @State private var isTrusted = AXIsProcessTrusted()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    private let permissionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("一般") {
                Toggle("ログイン時に起動", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("操作") {
                Picker("合体用の修飾キー", selection: $mergeModifier) {
                    ForEach(MergeModifier.allCases) { Text($0.label).tag($0) }
                }
                ShortcutRecorderView(
                    title: "前のタブ",
                    keyCode: $previousKeyCode,
                    modifiers: $previousModifiers,
                    defaultShortcut: AppSettings.defaultPreviousTab
                )
                ShortcutRecorderView(
                    title: "次のタブ",
                    keyCode: $nextKeyCode,
                    modifiers: $nextModifiers,
                    defaultShortcut: AppSettings.defaultNextTab
                )
            }

            Section("外観") {
                Picker("スタイル", selection: $styleMode) {
                    ForEach(StyleMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("グラスの種類", selection: $glassVariant) {
                    ForEach(GlassVariant.allCases) { Text($0.label).tag($0) }
                }
                .disabled(styleMode == .solid)
                Picker("テーマ", selection: $themeMode) {
                    ForEach(ThemeMode.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("アクセシビリティ権限") {
                LabeledContent("状態") {
                    Label(isTrusted ? "許可済み" : "未許可", systemImage: isTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(isTrusted ? .green : .orange)
                }
                Button("システム設定を開く") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(permissionTimer) { _ in
            isTrusted = AXIsProcessTrusted()
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "設定できませんでした: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
