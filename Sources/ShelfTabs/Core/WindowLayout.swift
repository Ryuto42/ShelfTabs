import AppKit

enum LayoutAction: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
    case maximize, almostMaximize, maximizeHeight, center
    case restore, nextDisplay, previousDisplay

    var id: String { rawValue }

    var label: String {
        switch self {
        case .leftHalf: loc("左半分")
        case .rightHalf: loc("右半分")
        case .topHalf: loc("上半分")
        case .bottomHalf: loc("下半分")
        case .topLeft: loc("左上")
        case .topRight: loc("右上")
        case .bottomLeft: loc("左下")
        case .bottomRight: loc("右下")
        case .firstThird: loc("最初の1/3")
        case .centerThird: loc("中央の1/3")
        case .lastThird: loc("最後の1/3")
        case .firstTwoThirds: loc("最初の2/3")
        case .lastTwoThirds: loc("最後の2/3")
        case .maximize: loc("最大化")
        case .almostMaximize: loc("ほぼ最大化")
        case .maximizeHeight: loc("縦に最大化")
        case .center: loc("中央")
        case .restore: loc("元に戻す")
        case .nextDisplay: loc("次のディスプレイ")
        case .previousDisplay: loc("前のディスプレイ")
        }
    }

    var isSnappable: Bool {
        switch self {
        case .restore, .nextDisplay, .previousDisplay: false
        default: true
        }
    }

    var defaultShortcut: Shortcut {
        let controlOption = AppSettings.controlOption
        let shift = Int(bitPattern: NSEvent.ModifierFlags.shift.rawValue)
        let command = Int(bitPattern: NSEvent.ModifierFlags.command.rawValue)
        func letter(_ character: String, _ fallback: Int) -> Shortcut {
            Shortcut(keyCode: Shortcut.keyCode(for: character, fallback: fallback), modifiers: controlOption)
        }
        switch self {
        case .leftHalf: return Shortcut(keyCode: 123, modifiers: controlOption)
        case .rightHalf: return Shortcut(keyCode: 124, modifiers: controlOption)
        case .topHalf: return Shortcut(keyCode: 126, modifiers: controlOption)
        case .bottomHalf: return Shortcut(keyCode: 125, modifiers: controlOption)
        case .topLeft: return letter("u", 32)
        case .topRight: return letter("i", 34)
        case .bottomLeft: return letter("j", 38)
        case .bottomRight: return letter("k", 40)
        case .firstThird: return letter("d", 2)
        case .centerThird: return letter("f", 3)
        case .lastThird: return letter("g", 5)
        case .firstTwoThirds: return letter("e", 14)
        case .lastTwoThirds: return letter("t", 17)
        case .maximize: return Shortcut(keyCode: 36, modifiers: controlOption)
        case .almostMaximize: return .unassigned
        case .maximizeHeight: return Shortcut(keyCode: 126, modifiers: controlOption | shift)
        case .center: return letter("c", 8)
        case .restore: return Shortcut(keyCode: 51, modifiers: controlOption)
        case .nextDisplay: return Shortcut(keyCode: 124, modifiers: controlOption | command)
        case .previousDisplay: return Shortcut(keyCode: 123, modifiers: controlOption | command)
        }
    }

    func targetFrame(current: CGRect) -> CGRect? {
        let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
        guard let home = Geometry.screen(containingAX: current), let index = screens.firstIndex(of: home) else { return nil }
        let homeVisible = ExternalDock.usableFrame(for: home)
        switch self {
        case .nextDisplay, .previousDisplay:
            guard screens.count > 1 else { return nil }
            let step = self == .nextDisplay ? 1 : -1
            let destination = screens[(index + step + screens.count) % screens.count]
            return WindowLayout.frame(of: current, from: homeVisible, to: ExternalDock.usableFrame(for: destination))
        default:
            return WindowLayout.frame(for: self, current: current, visible: homeVisible)
        }
    }
}

enum SnapArea: String, CaseIterable, Identifiable {
    case topLeftCorner, top, topRightCorner
    case left, right
    case bottomLeftCorner, bottom, bottomRightCorner

    var id: String { rawValue }

    static let none = "none"
    static let thirds = "thirds"

    var defaultChoice: String {
        switch self {
        case .topLeftCorner: LayoutAction.topLeft.rawValue
        case .top: LayoutAction.maximize.rawValue
        case .topRightCorner: LayoutAction.topRight.rawValue
        case .left: LayoutAction.leftHalf.rawValue
        case .right: LayoutAction.rightHalf.rawValue
        case .bottomLeftCorner: LayoutAction.bottomLeft.rawValue
        case .bottom: Self.thirds
        case .bottomRightCorner: LayoutAction.bottomRight.rawValue
        }
    }
}

enum WindowLayout {
    static func frame(for action: LayoutAction, current: CGRect, visible v: CGRect) -> CGRect? {
        func part(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            let minX = (v.minX + x * v.width).rounded()
            let maxX = (v.minX + (x + w) * v.width).rounded()
            let minY = (v.minY + y * v.height).rounded()
            let maxY = (v.minY + (y + h) * v.height).rounded()
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        let horizontal = v.width >= v.height
        func slice(_ start: CGFloat, _ length: CGFloat) -> CGRect {
            horizontal ? part(start, 0, length, 1) : part(0, start, 1, length)
        }
        let third = CGFloat(1) / 3

        switch action {
        case .leftHalf: return part(0, 0, 0.5, 1)
        case .rightHalf: return part(0.5, 0, 0.5, 1)
        case .topHalf: return part(0, 0, 1, 0.5)
        case .bottomHalf: return part(0, 0.5, 1, 0.5)
        case .topLeft: return part(0, 0, 0.5, 0.5)
        case .topRight: return part(0.5, 0, 0.5, 0.5)
        case .bottomLeft: return part(0, 0.5, 0.5, 0.5)
        case .bottomRight: return part(0.5, 0.5, 0.5, 0.5)
        case .firstThird: return slice(0, third)
        case .centerThird: return slice(third, third)
        case .lastThird: return slice(2 * third, third)
        case .firstTwoThirds: return slice(0, 2 * third)
        case .lastTwoThirds: return slice(third, 2 * third)
        case .maximize: return v
        case .almostMaximize: return part(0.05, 0.05, 0.9, 0.9)
        case .maximizeHeight:
            return CGRect(x: current.minX, y: v.minY, width: min(current.width, v.width), height: v.height)
        case .center:
            let size = CGSize(width: min(current.width, v.width), height: min(current.height, v.height))
            return CGRect(
                x: (v.midX - size.width / 2).rounded(),
                y: (v.midY - size.height / 2).rounded(),
                width: size.width,
                height: size.height
            )
        case .restore, .nextDisplay, .previousDisplay:
            return nil
        }
    }

    static func frame(of current: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return destination }
        let scaleX = destination.width / source.width
        let scaleY = destination.height / source.height
        return CGRect(
            x: (destination.minX + (current.minX - source.minX) * scaleX).rounded(),
            y: (destination.minY + (current.minY - source.minY) * scaleY).rounded(),
            width: (current.width * scaleX).rounded(),
            height: (current.height * scaleY).rounded()
        )
    }
}
