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
    var clearable = false

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
                if clearable {
                    Button("クリア") {
                        stopRecording()
                        keyCode = Shortcut.unassigned.keyCode
                        modifiers = Shortcut.unassigned.modifiers
                    }
                    .disabled(keyCode < 0)
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

private struct LayoutShortcutRow: View {
    let action: LayoutAction
    @AppStorage private var keyCode: Int
    @AppStorage private var modifiers: Int

    init(action: LayoutAction) {
        self.action = action
        let shortcut = action.defaultShortcut
        _keyCode = AppStorage(wrappedValue: shortcut.keyCode, AppSettings.Key.shortcutKeyCode(action))
        _modifiers = AppStorage(wrappedValue: shortcut.modifiers, AppSettings.Key.shortcutModifiers(action))
    }

    var body: some View {
        ShortcutRecorderView(
            title: action.label,
            keyCode: $keyCode,
            modifiers: $modifiers,
            defaultShortcut: action.defaultShortcut,
            clearable: true
        )
    }
}

private struct SnapAreaPicker: View {
    let area: SnapArea
    @AppStorage private var choice: String

    init(area: SnapArea) {
        self.area = area
        _choice = AppStorage(wrappedValue: area.defaultChoice, AppSettings.Key.snapArea(area))
    }

    var body: some View {
        Picker(selection: $choice) {
            Text("なし").tag(SnapArea.none)
            if area == .bottom {
                Text("3分割、中心にドラッグで2/3").tag(SnapArea.thirds)
            }
            ForEach(LayoutAction.allCases.filter(\.isSnappable)) { Text($0.label).tag($0.rawValue) }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .frame(width: 150)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("一般", systemImage: "gearshape") }
            TabSettingsView()
                .tabItem { Label("タブ", systemImage: "rectangle.stack") }
            SnapSettingsView()
                .tabItem { Label("スナップ領域", systemImage: "rectangle.split.3x3") }
            ShortcutSettingsView()
                .tabItem { Label("キーボードショートカット", systemImage: "keyboard") }
        }
        .frame(width: 580, height: 640)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(AppSettings.Key.styleMode) private var styleMode = StyleMode.auto
    @AppStorage(AppSettings.Key.glassVariant) private var glassVariant = GlassVariant.regular
    @AppStorage(AppSettings.Key.themeMode) private var themeMode = ThemeMode.system
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

private struct TabSettingsView: View {
    @AppStorage(AppSettings.Key.mergeModifier) private var mergeModifier = MergeModifier.shift
    @AppStorage(AppSettings.Key.previousTabKeyCode) private var previousKeyCode = AppSettings.defaultPreviousTab.keyCode
    @AppStorage(AppSettings.Key.previousTabModifiers) private var previousModifiers = AppSettings.defaultPreviousTab.modifiers
    @AppStorage(AppSettings.Key.nextTabKeyCode) private var nextKeyCode = AppSettings.defaultNextTab.keyCode
    @AppStorage(AppSettings.Key.nextTabModifiers) private var nextModifiers = AppSettings.defaultNextTab.modifiers

    var body: some View {
        Form {
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
        }
        .formStyle(.grouped)
    }
}

private struct SnapSettingsView: View {
    @AppStorage(AppSettings.Key.snapEnabled) private var snapEnabled = true
    @AppStorage(AppSettings.Key.snapRestoreSize) private var restoreSize = true
    @AppStorage(AppSettings.Key.snapHaptics) private var haptics = true
    @AppStorage(AppSettings.Key.animateWindowMove) private var animate = true
    @State private var wallpaper: NSImage?

    var body: some View {
        Form {
            Section {
                Toggle("ドラッグでウインドウをスナップ", isOn: $snapEnabled)
                Toggle("スナップが解除されたらウインドウサイズを元に戻す", isOn: $restoreSize)
                Toggle("触覚フィードバック", isOn: $haptics)
                Toggle("ウインドウ移動をアニメーション", isOn: $animate)
            }

            Section {
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        SnapAreaPicker(area: .topLeftCorner)
                        SnapAreaPicker(area: .top)
                        SnapAreaPicker(area: .topRightCorner)
                    }
                    GridRow {
                        SnapAreaPicker(area: .left)
                        preview
                        SnapAreaPicker(area: .right)
                    }
                    GridRow {
                        SnapAreaPicker(area: .bottomLeftCorner)
                        SnapAreaPicker(area: .bottom)
                        SnapAreaPicker(area: .bottomRightCorner)
                    }
                }
                .frame(maxWidth: .infinity)
                .disabled(!snapEnabled)
            }

            ExternalDockSection()
        }
        .formStyle(.grouped)
        .task {
            guard wallpaper == nil, let screen = NSScreen.main,
                  let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
            wallpaper = NSImage(contentsOf: url)
        }
    }

    private var preview: some View {
        ZStack {
            if let wallpaper {
                Image(nsImage: wallpaper)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .frame(width: 150, height: 94)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.5)))
    }
}

private struct ExternalDockSection: View {
    @AppStorage(AppSettings.Key.externalDockBundleID) private var bundleID = ""
    @AppStorage(AppSettings.Key.externalDockShownMargin) private var shownMargin = 0.0
    @AppStorage(AppSettings.Key.externalDockHiddenMargin) private var hiddenMargin = 0.0
    @State private var apps: [(id: String, name: String)] = []
    @State private var statuses: [(name: String, text: String)] = []
    @State private var usesPublished = false

    var body: some View {
        Section("外部Dock") {
            Picker("外部Dockアプリ", selection: $bundleID) {
                Text("なし").tag("")
                ForEach(apps, id: \.id) { Text($0.name).tag($0.id) }
            }
            Stepper(value: $shownMargin, in: 0...60, step: 1) {
                LabeledContent("表示中の追加余白", value: "\(Int(shownMargin)) pt")
            }
            .disabled(bundleID.isEmpty)
            VStack(alignment: .leading, spacing: 2) {
                Stepper(value: $hiddenMargin, in: 0...120, step: 1) {
                    LabeledContent("隠れているときの余白", value: "\(Int(hiddenMargin)) pt")
                }
                Text("自動的に隠れるDockで、隠れている間も空けておく幅です")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(bundleID.isEmpty)
            ForEach(Array(statuses.enumerated()), id: \.offset) { _, entry in
                LabeledContent(entry.name) {
                    Text(entry.text).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("再検出", action: refresh)
                if !usesPublished {
                    Button("記憶した位置をリセット") {
                        ExternalDock.resetRememberedEdges()
                        refresh()
                    }
                }
            }
            .disabled(bundleID.isEmpty)
        }
        .onAppear(perform: refresh)
        .onChange(of: bundleID) { refresh() }
    }

    private func refresh() {
        let ownID = Bundle.main.bundleIdentifier
        var list = NSWorkspace.shared.runningApplications.compactMap { app -> (id: String, name: String)? in
            guard let id = app.bundleIdentifier, id != ownID, let name = app.localizedName else { return nil }
            return (id, name)
        }
        if !bundleID.isEmpty, !list.contains(where: { $0.id == bundleID }) {
            list.append((bundleID, bundleID))
        }
        var seen = Set<String>()
        apps = list.filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        usesPublished = ExternalDock.usesPublishedData
        statuses = NSScreen.screens.map { screen in
            let text: String
            switch ExternalDock.status(for: screen, fresh: true) {
            case .notConfigured: text = ""
            case .notRunning: text = "起動していません"
            case .none: text = "Dockなし"
            case .hidden(let edge, let margin):
                text = usesPublished ? "GlassDock から取得：自動的に隠す（\(edge.label)端に \(Int(margin.rounded())) pt 空ける）"
                    : "非表示（\(edge.label)端に \(Int(margin.rounded())) pt 空ける）"
            case .shown(let edge, let thickness):
                text = usesPublished ? "GlassDock から取得：表示中 \(edge.label)端 \(Int(thickness.rounded())) pt"
                    : "表示中：\(edge.label)端 \(Int(thickness.rounded())) pt"
            }
            return (screen.localizedName, text)
        }
    }
}

private struct ShortcutSettingsView: View {
    var body: some View {
        Form {
            Section {
                ForEach(LayoutAction.allCases) { LayoutShortcutRow(action: $0) }
            }
        }
        .formStyle(.grouped)
    }
}
