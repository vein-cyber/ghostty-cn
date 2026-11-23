import AppKit

/// A window-level action, not a tab: it remains available when the sidebar is closed.
final class FileBrowserTitlebarAccessory: NSTitlebarAccessoryViewController {
    /// Keep the action clear of the native window corner; the inner gap is independent.
    static let outerInset: CGFloat = 16
    static let accessorySpacing: CGFloat = 12
    static let rowHeight: CGFloat = 32
    let button: NSButton
    private let action: () -> Void
    private let preferences: UserDefaults
    private var preferencesObserver: NSObjectProtocol?
    private(set) var symbolName = ""

    init(preferences: UserDefaults = .ghostty, action: @escaping () -> Void) {
        self.preferences = preferences
        self.action = action
        button = FileBrowserToggleButton(title: "", target: nil, action: nil)
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .right
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        // Keep native toggle/accessibility behavior without the accent-colored bezel.
        (button.cell as? NSButtonCell)?.highlightsBy = []
        (button.cell as? NSButtonCell)?.showsStateBy = []
        button.font = .systemFont(ofSize: FileBrowserButtonLayout.fontSize, weight: .regular)
        button.target = self
        button.action = #selector(toggle)
        button.setAccessibilityIdentifier("fileBrowserToggle")
        button.setAccessibilityLabel(String(localized: "File Browser"))
        let width = button.fittingSize.width + Self.accessorySpacing + Self.outerInset
        // AppKit sizes this transparent container to its native titlebar row.
        view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Self.rowHeight))
        view.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.accessorySpacing),
            button.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.outerInset),
            button.heightAnchor.constraint(equalToConstant: FileBrowserButtonLayout.height),
        ])
        sync(isVisible: false)
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncSymbol() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    }

    func sync(isVisible: Bool) {
        syncSymbol()
        button.state = isVisible ? .on : .off
        button.toolTip = isVisible ? String(localized: "Hide file browser") : String(localized: "Show file browser")
    }

    private func syncSymbol() {
        let name = preferences.string(forKey: FileBrowserPreferences.positionKey) == "right" ? "sidebar.right" : "sidebar.left"
        guard symbolName != name else { return }
        symbolName = name
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        button.needsDisplay = true
    }

    @objc private func toggle() { action() }
}

/// Compact icon-only action, independent of NSButtonCell's bezel insets.
struct FileBrowserButtonLayout {
    static let fontSize: CGFloat = 13
    static let iconSize: CGFloat = 14
    static let height: CGFloat = 24
    static let size = NSSize(width: 28, height: height)
    let icon: NSRect

    init(bounds: NSRect) {
        icon = NSRect(x: bounds.midX - Self.iconSize / 2, y: bounds.midY - Self.iconSize / 2,
                      width: Self.iconSize, height: Self.iconSize)
    }
}

private final class FileBrowserToggleButton: NSButton {
    override var state: NSControl.StateValue {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize { FileBrowserButtonLayout.size }
    override var fittingSize: NSSize { intrinsicContentSize }

    // NSButton's accessory bezel has invisible alignment insets. Our custom
    // drawing has no such bezel: constraints must describe the actual bounds,
    // or a 24-point height constraint produces a taller, edge-clipped button.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }

    override func draw(_ dirtyRect: NSRect) {
        // Always reveal the titlebar beneath the icon, including on/pressed states.
        let layout = FileBrowserButtonLayout(bounds: bounds)
        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = min(layout.icon.width / image.size.width, layout.icon.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let rect = NSRect(x: layout.icon.midX - size.width / 2, y: layout.icon.midY - size.height / 2,
                              width: size.width, height: size.height)
            let foreground: NSColor = !isEnabled ? .disabledControlTextColor : state == .on ? .labelColor : .secondaryLabelColor
            let tinted = image.withSymbolConfiguration(.init(hierarchicalColor: foreground)) ?? image
            tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: isFlipped, hints: nil)
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}
