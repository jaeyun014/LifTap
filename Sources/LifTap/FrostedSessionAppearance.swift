import AppKit

@MainActor
enum FrostedSessionAppearance {
    static func color(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let highlight = color(light: .white.withAlphaComponent(0.78),
                                 dark: .white.withAlphaComponent(0.22))
    static let fill = color(light: .white.withAlphaComponent(0.32),
                            dark: .white.withAlphaComponent(0.075))
    static let selectedFill = color(light: NSColor(srgbRed: 0.82, green: 0.92, blue: 1, alpha: 0.88),
                                    dark: NSColor(srgbRed: 0.25, green: 0.49, blue: 0.79, alpha: 0.35))
    static let selectionOutline = color(light: NSColor(srgbRed: 0.50, green: 0.67, blue: 0.88, alpha: 0.70),
                                         dark: NSColor(srgbRed: 0.52, green: 0.75, blue: 1, alpha: 0.50))
    static let secondaryText = color(light: NSColor(srgbRed: 0.23, green: 0.30, blue: 0.40, alpha: 1),
                                      dark: NSColor(srgbRed: 0.78, green: 0.84, blue: 0.94, alpha: 1))

    static func paintPlate(in rect: NSRect, radius: CGFloat, selected: Bool = false) {
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: radius, yRadius: radius)
        (selected ? selectedFill : fill).setFill()
        shape.fill()
        (selected ? selectionOutline : highlight).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

@MainActor
final class FrostedSessionSurface: NSVisualEffectView {
    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 28
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        let coating = FrostedCoating(frame: bounds)
        coating.autoresizingMask = [.width, .height]
        addSubview(coating)
    }

    required init?(coder: NSCoder) { nil }
}

private final class FrostedCoating: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let opacity: CGFloat = reduced ? 1 : (dark ? 0.83 : 0.69)
        let base = dark
            ? NSColor(srgbRed: 0.105, green: 0.14, blue: 0.22, alpha: opacity)
            : NSColor(srgbRed: 0.91, green: 0.95, blue: 1, alpha: opacity)
        base.setFill()
        bounds.fill()

        let warm = NSColor(srgbRed: 1, green: 0.88, blue: 0.68, alpha: dark ? 0.17 : 0.63)
        let ocean = NSColor(srgbRed: 0.25, green: 0.57, blue: 1, alpha: dark ? 0.44 : 0.56)
        glow(warm, x: 0.02, y: 1.03, radius: 0.80)
        glow(ocean, x: 1.04, y: 0.04, radius: 1.02)

        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 27, yRadius: 27)
        NSColor.white.withAlphaComponent(dark ? 0.28 : 0.90).setStroke()
        edge.lineWidth = 1
        edge.stroke()
    }

    private func glow(_ color: NSColor, x: CGFloat, y: CGFloat, radius: CGFloat) {
        let center = NSPoint(x: bounds.width * x, y: bounds.height * y)
        NSGradient(starting: color, ending: color.withAlphaComponent(0))?
            .draw(fromCenter: center, radius: 0, toCenter: center,
                  radius: max(bounds.width, bounds.height) * radius, options: [.drawsAfterEndingLocation])
    }
}

private final class FrostedSessionPlate: NSView {
    override func draw(_ dirtyRect: NSRect) {
        FrostedSessionAppearance.paintPlate(in: bounds, radius: 17)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
func frostedSessionPlate(wrapping content: NSView, horizontal: CGFloat, vertical: CGFloat) -> NSView {
    let plate = FrostedSessionPlate()
    content.translatesAutoresizingMaskIntoConstraints = false
    plate.addSubview(content)
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: horizontal),
        content.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -horizontal),
        content.topAnchor.constraint(equalTo: plate.topAnchor, constant: vertical),
        content.bottomAnchor.constraint(equalTo: plate.bottomAnchor, constant: -vertical)
    ])
    return plate
}

final class FrostedSectionButton: NSButton {
    override var state: NSControl.StateValue {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            FrostedSessionAppearance.paintPlate(in: bounds.insetBy(dx: 1, dy: 2), radius: 13, selected: true)
        }
        super.draw(dirtyRect)
    }
}

final class FrostedSessionRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawBackground(in dirtyRect: NSRect) {
        FrostedSessionAppearance.paintPlate(in: bounds.insetBy(dx: 5, dy: 1), radius: 13)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        FrostedSessionAppearance.paintPlate(in: bounds.insetBy(dx: 5, dy: 1), radius: 13, selected: true)
    }
}

final class FrostedOpenButton: NSButton {
    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        if isEnabled {
            let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
            NSColor(srgbRed: 0.96, green: 0.98, blue: 1, alpha: isHighlighted ? 0.73 : 0.96).setFill()
            pill.fill()
        } else {
            FrostedSessionAppearance.paintPlate(in: bounds.insetBy(dx: 1, dy: 1), radius: radius)
        }
        super.draw(dirtyRect)
    }
}
