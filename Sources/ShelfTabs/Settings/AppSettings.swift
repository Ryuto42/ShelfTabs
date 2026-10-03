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

    var displayString: String {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(bitPattern: modifiers))
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + Shortcut.keyName(UInt16(clamping: keyCode))
    }

    func matches(_ event: CGEvent) -> Bool {
        Int(event.getIntegerValueField(.keyboardEventKeycode)) == keyCode
            && (UInt(event.flags.rawValue) & Shortcut.relevantModifiers) == (UInt(bitPattern: modifiers) & Shortcut.relevantModifiers)
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

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let dataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(keyCode)"
        }
        let layoutData = unsafeBitCast(dataPointer, to: CFData.self)
        let layout = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
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
    }

    static let controlOption = Int(bitPattern: NSEvent.ModifierFlags([.control, .option]).rawValue)
    static let defaultPreviousTab = Shortcut(keyCode: 123, modifiers: controlOption)
    static let defaultNextTab = Shortcut(keyCode: 124, modifiers: controlOption)

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
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

    private static func raw<T: RawRepresentable>(_ key: String, default fallback: T) -> T where T.RawValue == String {
        UserDefaults.standard.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }
}
