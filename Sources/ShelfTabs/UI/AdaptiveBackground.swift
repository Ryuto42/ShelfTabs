import AppKit

enum BarStyle: Equatable {
    case glass(clear: Bool)
    case solid(highContrast: Bool)

    static func resolve() -> BarStyle {
        let workspace = NSWorkspace.shared
        let highContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        switch AppSettings.styleMode {
        case .glass:
            return .glass(clear: AppSettings.glassVariant == .clear)
        case .solid:
            return .solid(highContrast: highContrast)
        case .auto:
            if workspace.accessibilityDisplayShouldReduceTransparency || highContrast {
                return .solid(highContrast: highContrast)
            }
            return .glass(clear: AppSettings.glassVariant == .clear)
        }
    }
}

extension NSView {
    var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    func resolvedCGColor(_ color: NSColor) -> CGColor {
        var result = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            result = color.cgColor
        }
        return result
    }
}

final class AdaptiveBackground: NSView {
    static let cornerRadius: CGFloat = 12

    let content = NSView()

    var accent: NSColor {
        didSet { applyColors() }
    }

    private(set) var style: BarStyle

    private var holder: NSView?
    private var glass: NSGlassEffectView?
    private var solid: NSView?

    init(style: BarStyle, accent: NSColor) {
        self.style = style
        self.accent = accent
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setStyle(_ newStyle: BarStyle) {
        guard newStyle != style else { return }
        style = newStyle
        build()
    }

    override func layout() {
        super.layout()
        if let holder, let glass {
            glass.frame = bounds
            holder.frame = glass.bounds
            content.frame = holder.bounds
        } else if let solid {
            solid.frame = bounds
            content.frame = bounds
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func build() {
        content.removeFromSuperview()
        glass?.removeFromSuperview()
        solid?.removeFromSuperview()
        holder = nil
        glass = nil
        solid = nil

        switch style {
        case .glass(let clear):
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cornerRadius
            glass.style = clear ? .clear : .regular

            let holder = NSView()
            holder.addSubview(content)
            glass.contentView = holder
            addSubview(glass)

            self.holder = holder
            self.glass = glass
        case .solid:
            let solid = NSView()
            solid.wantsLayer = true
            solid.layer?.cornerRadius = Self.cornerRadius
            addSubview(solid)
            addSubview(content)
            self.solid = solid
        }

        applyColors()
        needsLayout = true
    }

    private func applyColors() {
        glass?.tintColor = accent.withAlphaComponent(0.16)

        guard let layer = solid?.layer else { return }
        var base = NSColor.windowBackgroundColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            base = NSColor.windowBackgroundColor.blended(withFraction: 0.12, of: accent) ?? NSColor.windowBackgroundColor
        }
        layer.backgroundColor = resolvedCGColor(base)

        if case .solid(let highContrast) = style, highContrast {
            layer.borderWidth = 2
            layer.borderColor = resolvedCGColor(.separatorColor)
        } else {
            layer.borderWidth = 0
        }
    }
}
