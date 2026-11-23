import AppKit

@MainActor
final class Feedback {
    private var window: NSPanel?
    private var dismissal: Task<Void, Never>?

    func show(_ text: String, relativeTo button: NSStatusBarButton?, isError: Bool) {
        dismiss()
        guard let screen = button?.window?.screen ?? NSScreen.main else { return }
        let width: CGFloat = 310
        let content = NSVisualEffectView()
        content.material = .popover
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 11

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = isError ? .systemRed : .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 11),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -11),
            label.widthAnchor.constraint(equalToConstant: width - 28)
        ])
        let height = ceil(content.fittingSize.height)
        let visible = screen.visibleFrame
        let anchor = button?.window?.frame.midX ?? visible.maxX
        let x = max(visible.minX + 8, min(anchor - width / 2, visible.maxX - width - 8))
        let frame = NSRect(x: x, y: visible.maxY - height - 6, width: width, height: height)
        let toast = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        toast.isOpaque = false
        toast.backgroundColor = .clear
        toast.hasShadow = true
        toast.level = .statusBar
        toast.ignoresMouseEvents = true
        toast.hidesOnDeactivate = false
        toast.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        toast.contentView = content
        window = toast
        toast.orderFrontRegardless()
        NSAccessibility.post(element: label, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])

        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(isError ? 8 : 4)) } catch { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        window?.orderOut(nil)
        window = nil
    }
}
