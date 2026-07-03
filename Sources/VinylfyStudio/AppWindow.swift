import SwiftUI
import AppKit

// MARK: - The window

/// An `NSPanel` subclass configured to behave as a standard document window,
/// per skeleton §2. Catches app-menu shortcuts and broadcasts them.
@available(macOS 14.2, *)
final class AppWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = false
        level = .normal
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = true
        isMovableByWindowBackground = false
        collectionBehavior = [.fullScreenPrimary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = ActiveTheme.selected.appearance
        title = "billiejean"
    }

    /// Reposition the traffic lights onto the floating control-row centerline.
    func layoutWindowChromeButtons() {
        guard !styleMask.contains(.fullScreen) else { return }
        guard let container = standardWindowButton(.closeButton)?.superview else { return }
        let rowCenterY = WindowChrome.rowCenterY
        var x = WindowChrome.edgeInset
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(type) else { continue }
            let y = container.isFlipped
                ? rowCenterY - button.frame.height / 2
                : container.frame.height - rowCenterY - button.frame.height / 2
            button.setFrameOrigin(NSPoint(x: x, y: y))
            x += button.frame.width + 6
        }
    }

    // MARK: - Keyboard bridge (§8)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let editing = firstResponder is NSTextView
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = mods.contains(.command)

        // Space = play/pause when not editing text.
        if !editing, event.charactersIgnoringModifiers == " ", mods.isEmpty {
            NotificationCenter.default.post(name: .billiePlayPause, object: nil)
            return true
        }

        if cmd {
            switch event.charactersIgnoringModifiers {
            case String(UnicodeScalar(NSLeftArrowFunctionKey)!):
                NotificationCenter.default.post(name: .billiePrev, object: nil)
                return true
            case String(UnicodeScalar(NSRightArrowFunctionKey)!):
                NotificationCenter.default.post(name: .billieNext, object: nil)
                return true
            case "1":
                NotificationCenter.default.post(name: .billieLibrary, object: nil)
                return true
            case ",":
                NotificationCenter.default.post(name: .billieSettings, object: nil)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Controller

/// Owns the main window's lifecycle: build/show/hide, frame autosave, theme
/// application + content rebuild, and the four traffic-light delegate hooks.
/// Coordinates the floating widget mini-mode with the AppDelegate via callbacks.
@available(macOS 14.2, *)
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: AppWindow?

    /// Called when the window should hide the widget (window shown/restored).
    var onWindowVisible: (() -> Void)?
    /// Called when the window is minimized or closed (maybe show the widget).
    var onWindowHidden: (() -> Void)?
    /// The manual widget toggle from chrome.
    var onToggleWidget: (() -> Void)?

    /// Bridges @AppStorage("billiejean.showWidgetOnMinimize") into SwiftUI.
    @AppStorage("billiejean.showWidgetOnMinimize") private var showWidgetOnMinimize = true

    override init() {
        super.init()
        // The controller is an app-lifetime singleton; the observer never needs
        // removal, so no stored token is kept (avoids a nonisolated-deinit issue).
        NotificationCenter.default.addObserver(
            forName: .billieFlavorChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyThemeAndRebuild() }
        }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    // MARK: - Show / build

    func showWindow() {
        if let window {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            layoutButtons()
            onWindowVisible?()
            return
        }
        build()
    }

    private func build() {
        let frame = Self.firstLaunchFrame()
        let window = AppWindow(contentRect: frame)
        window.delegate = self
        window.minSize = NSSize(width: 640, height: 460)

        installContent(into: window)

        window.setFrameAutosaveName("billiejean.main")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        layoutButtons()
        onWindowVisible?()
    }

    private func installContent(into window: AppWindow) {
        let root = MainWindowView(
            onToggleWidget: { [weak self] in self?.onToggleWidget?() },
            showWidgetOnMinimize: Binding(
                get: { [weak self] in self?.showWidgetOnMinimize ?? true },
                set: { [weak self] in self?.showWidgetOnMinimize = $0 }
            )
        )
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []

        let container = ContainerView()
        container.translatesAutoresizingMaskIntoConstraints = true
        container.autoresizingMask = [.width, .height]
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        window.contentView = container
    }

    /// Theme switch = full content rebuild + re-layout traffic lights.
    private func applyThemeAndRebuild() {
        guard let window else { return }
        window.appearance = ActiveTheme.selected.appearance
        installContent(into: window)
        layoutButtons()
    }

    // MARK: - Traffic lights

    private func layoutButtons() {
        window?.layoutWindowChromeButtons()
    }

    // MARK: - Frame

    private static func firstLaunchFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(1180, screen.width * 0.72)
        let h = min(820, screen.height * 0.84)
        let x = screen.minX + (screen.width - w) / 2
        let y = screen.minY + (screen.height - h) / 2
        return NSRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - NSWindowDelegate (four hooks + minimize/close coordination)

    func windowDidResize(_ notification: Notification) { layoutButtons() }
    func windowDidMove(_ notification: Notification) { layoutButtons() }
    func windowDidBecomeKey(_ notification: Notification) { layoutButtons() }
    func windowDidResignKey(_ notification: Notification) { layoutButtons() }

    func windowDidMiniaturize(_ notification: Notification) {
        onWindowHidden?()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        layoutButtons()
        onWindowVisible?()
    }

    func windowWillClose(_ notification: Notification) {
        onWindowHidden?()
    }
}

/// Container whose background drag never moves the window (the canvas owns drag).
@available(macOS 14.2, *)
private final class ContainerView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}
