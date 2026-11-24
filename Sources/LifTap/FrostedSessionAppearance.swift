import AppKit

@MainActor
enum FrostedSessionAppearance {
    static func color(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let highlight = color(light: .white.withAlphaComponent(0.67),
                                 dark: .white.withAlphaComponent(0.22))
    static let fill = color(light: .white.withAlphaComponent(0.19),
                            dark: .white.withAlphaComponent(0.075))
    static let selectedFill = color(light: .black.withAlphaComponent(0.085),
                                    dark: .white.withAlphaComponent(0.17))
    static let selectionOutline = color(light: .black.withAlphaComponent(0.24),
                                         dark: .white.withAlphaComponent(0.44))
    static let secondaryText = color(light: NSColor(white: 0.28, alpha: 1),
                                      dark: NSColor(white: 0.84, alpha: 1))

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
        // Keep the system's behind-window material visible through the neutral tint.
        let opacity: CGFloat = reduced ? 1 : (dark ? 0.26 : 0.40)
        let base = NSColor(white: dark ? 0.12 : 1, alpha: opacity)
        base.setFill()
        bounds.fill()

        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 27, yRadius: 27)
        NSColor.white.withAlphaComponent(dark ? 0.27 : 0.74).setStroke()
        edge.lineWidth = 1
        edge.stroke()
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
            NSColor(white: 0.97, alpha: isHighlighted ? 0.72 : 0.90).setFill()
            pill.fill()
        } else {
            FrostedSessionAppearance.paintPlate(in: bounds.insetBy(dx: 1, dy: 1), radius: radius)
        }
        super.draw(dirtyRect)
    }
}
