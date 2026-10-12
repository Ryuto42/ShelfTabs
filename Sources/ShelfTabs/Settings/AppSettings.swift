import AppKit
import Carbon

enum MergeModifier: String, CaseIterable, Identifiable {
    case shift, option, control, command

    var id: String { rawValue }

    var label: String {
        switch self {
        case .shift: "Shift"
        case .option: "Option"
        case .control: "Control"
        case .command: "Command"
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .shift: .maskShift
        case .option: .maskAlternate
        case .control: .maskControl
        case .command: .maskCommand
        }
    }
}

enum ExternalDockEdge: String, CaseIterable, Identifiable {
    case bottom, left, right, top

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottom: "下"
        case .left: "左"
        case .right: "右"
        case .top: "上"
        }
    }
}

enum StyleMode: String, CaseIterable, Identifiable {
    case auto, glass, solid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "自動"
        case .glass: "リキッドグラス"
        case .solid: "単色"
        }
    }
}

enum GlassVariant: String, CaseIterable, Identifiable {
    case regular, clear

    var id: String { rawValue }

    var label: String {
        switch self {
        case .regular: "標準"
        case .clear: "クリア"
        }
    }
}

enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "システム"
        case .light: "ライト"
        case .dark: "ダーク"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

struct Shortcut {
    static let relevantModifiers: UInt = NSEvent.ModifierFlags([.command, .control, .option, .shift]).rawValue

    var keyCode: Int
    var modifiers: Int

    static let unassigned = Shortcut(keyCode: -1, modifiers: 0)

    var isAssigned: Bool { keyCode >= 0 }

    var displayString: String {
        guard isAssigned else { return "未設定" }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(bitPattern: modifiers))
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + Shortcut.keyName(UInt16(clamping: keyCode))
    }

    static func keyName(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 36: return "↩"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "⌫"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: break
        }

        return translate(keyCode, action: kUCKeyActionDisplay)?.uppercased() ?? "Key \(keyCode)"
    }

    private static let layoutKeyCodes: [String: Int] = {
        var result: [String: Int] = [:]
        for code in 0..<128 {
            guard let character = translate(UInt16(code), action: kUCKeyActionDown)?.lowercased(),
                  character.count == 1, result[character] == nil else { continue }
            result[character] = code
        }
        return result
    }()

    static func keyCode(for character: String, fallback: Int) -> Int {
        layoutKeyCodes[character] ?? fallback
    }

    private static func translate(_ keyCode: UInt16, action: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let dataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = unsafeBitCast(dataPointer, to: CFData.self)
        let layout = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout,
            keyCode,
            UInt16(action),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

enum AppSettings {
    enum Key {
        static let mergeModifier = "mergeModifier"
        static let styleMode = "styleMode"
        static let glassVariant = "glassVariant"
        static let themeMode = "themeMode"
        static let previousTabKeyCode = "previousTabKeyCode"
        static let previousTabModifiers = "previousTabModifiers"
        static let nextTabKeyCode = "nextTabKeyCode"
        static let nextTabModifiers = "nextTabModifiers"
        static let snapEnabled = "snapEnabled"
        static let snapRestoreSize = "snapRestoreSize"
        static let snapHaptics = "snapHaptics"
        static let animateWindowMove = "animateWindowMove"
        static let externalDockBundleID = "externalDockBundleID"
        static let externalDockEdges = "externalDockEdges"
        static let externalDockShownMargin = "externalDockShownMargin"
        static let externalDockHiddenMargin = "externalDockHiddenMargin"

        static func shortcutKeyCode(_ action: LayoutAction) -> String { "shortcut.\(action.rawValue).keyCode" }
        static func shortcutModifiers(_ action: LayoutAction) -> String { "shortcut.\(action.rawValue).modifiers" }
        static func snapArea(_ area: SnapArea) -> String { "snap.\(area.rawValue)" }
    }

    static let controlOption = Int(bitPattern: NSEvent.ModifierFlags([.control, .option]).rawValue)
    static var defaultPreviousTab: Shortcut { Shortcut(keyCode: Shortcut.keyCode(for: "[", fallback: 33), modifiers: controlOption) }
    static var defaultNextTab: Shortcut { Shortcut(keyCode: Shortcut.keyCode(for: "]", fallback: 30), modifiers: controlOption) }

    private static func migrateLegacyTabShortcuts() {
        let defaults = UserDefaults.standard
        let legacy = [
            (Key.previousTabKeyCode, Key.previousTabModifiers, 123),
            (Key.nextTabKeyCode, Key.nextTabModifiers, 124),
        ]
        for (codeKey, modifiersKey, code) in legacy {
            guard defaults.object(forKey: codeKey) as? Int == code,
                  defaults.object(forKey: modifiersKey) as? Int == controlOption else { continue }
            defaults.removeObject(forKey: codeKey)
            defaults.removeObject(forKey: modifiersKey)
        }
    }

    static func registerDefaults() {
        migrateLegacyTabShortcuts()
        var layoutDefaults: [String: Any] = [:]
        for action in LayoutAction.allCases {
            let shortcut = action.defaultShortcut
            layoutDefaults[Key.shortcutKeyCode(action)] = shortcut.keyCode
            layoutDefaults[Key.shortcutModifiers(action)] = shortcut.modifiers
        }
        for area in SnapArea.allCases {
            layoutDefaults[Key.snapArea(area)] = area.defaultChoice
        }
        UserDefaults.standard.removeObject(forKey: "externalDockEdge")
        UserDefaults.standard.register(defaults: layoutDefaults)
        UserDefaults.standard.register(defaults: [
            Key.snapEnabled: true,
            Key.snapRestoreSize: true,
            Key.snapHaptics: true,
            Key.animateWindowMove: true,
            Key.externalDockBundleID: "",
            Key.externalDockShownMargin: 0.0,
            Key.externalDockHiddenMargin: 0.0,
            Key.mergeModifier: MergeModifier.shift.rawValue,
            Key.styleMode: StyleMode.auto.rawValue,
            Key.glassVariant: GlassVariant.regular.rawValue,
            Key.themeMode: ThemeMode.system.rawValue,
            Key.previousTabKeyCode: defaultPreviousTab.keyCode,
            Key.previousTabModifiers: defaultPreviousTab.modifiers,
            Key.nextTabKeyCode: defaultNextTab.keyCode,
            Key.nextTabModifiers: defaultNextTab.modifiers,
        ])
    }

    static var mergeModifier: MergeModifier { raw(Key.mergeModifier, default: .shift) }
    static var styleMode: StyleMode { raw(Key.styleMode, default: .auto) }
    static var glassVariant: GlassVariant { raw(Key.glassVariant, default: .regular) }
    static var themeMode: ThemeMode { raw(Key.themeMode, default: .system) }

    static var previousTab: Shortcut {
        Shortcut(
            keyCode: UserDefaults.standard.integer(forKey: Key.previousTabKeyCode),
            modifiers: UserDefaults.standard.integer(forKey: Key.previousTabModifiers)
        )
    }

    static var nextTab: Shortcut {
        Shortcut(
            keyCode: UserDefaults.standard.integer(forKey: Key.nextTabKeyCode),
            modifiers: UserDefaults.standard.integer(forKey: Key.nextTabModifiers)
        )
    }

    static func shortcut(for action: LayoutAction) -> Shortcut {
        Shortcut(
            keyCode: UserDefaults.standard.integer(forKey: Key.shortcutKeyCode(action)),
            modifiers: UserDefaults.standard.integer(forKey: Key.shortcutModifiers(action))
        )
    }

    static func snapChoice(for area: SnapArea) -> String {
        UserDefaults.standard.string(forKey: Key.snapArea(area)) ?? area.defaultChoice
    }

    static var snapEnabled: Bool { UserDefaults.standard.bool(forKey: Key.snapEnabled) }
    static var snapRestoreSize: Bool { UserDefaults.standard.bool(forKey: Key.snapRestoreSize) }
    static var snapHaptics: Bool { UserDefaults.standard.bool(forKey: Key.snapHaptics) }
    static var animateWindowMove: Bool { UserDefaults.standard.bool(forKey: Key.animateWindowMove) }

    static var externalDockBundleID: String { UserDefaults.standard.string(forKey: Key.externalDockBundleID) ?? "" }
    static var externalDockShownMargin: CGFloat { CGFloat(UserDefaults.standard.double(forKey: Key.externalDockShownMargin)) }
    static var externalDockHiddenMargin: CGFloat { CGFloat(UserDefaults.standard.double(forKey: Key.externalDockHiddenMargin)) }

    private static func raw<T: RawRepresentable>(_ key: String, default fallback: T) -> T where T.RawValue == String {
        UserDefaults.standard.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }
}
