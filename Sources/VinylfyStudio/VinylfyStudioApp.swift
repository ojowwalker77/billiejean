import SwiftUI
import AppKit

/// The SwiftUI app shell. The real UI is an AppDelegate-owned `NSPanel`; the
/// SwiftUI scene is an empty `Settings` scene so no ordinary window is created.
/// NOT annotated `@main` — the `@available` gate lives in `main.swift`.
@available(macOS 14.2, *)
struct VinylfyStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Owns the main window and the floating widget mini-mode, wires the engine to
/// tap Music, and tears down on quit.
///
/// billiejean is a real app: `.regular` activation (Dock presence), one main
/// window, and the floating widget card as a mini-mode. Main window open →
/// widget hidden. Main window minimized/closed (with the setting on) → widget
/// appears. Reopening the main window hides the widget again.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var widgetPanel: NSPanel?
    private var statusMenuController: AnyObject?
    private var windowController: AnyObject?

    /// Manual override: the user asked (from chrome) for the widget to show even
    /// while the main window is up. Reset when the window is hidden/restored.
    private var widgetForcedVisible = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A real Dock app.
        NSApp.setActivationPolicy(.regular)

        guard #available(macOS 14.2, *) else { return }
        MainActor.assumeIsolated {
            buildWidgetPanel()

            let controller = MainWindowController()
            controller.onWindowVisible = { [weak self] in self?.handleWindowVisible() }
            controller.onWindowHidden = { [weak self] in self?.handleWindowHidden() }
            controller.onToggleWidget = { [weak self] in self?.toggleWidgetManually() }
            windowController = controller

            let status = StatusMenuController()
            status.openMainWindow = { [weak self] in self?.showMainWindow() }
            status.install()
            statusMenuController = status

            // Engine taps Music only, set BEFORE start (inside bootstrap).
            StudioViewModel.shared.setMusicTapTarget()
            StudioViewModel.shared.bootstrap()

            controller.showWindow()
        }
    }

    // MARK: - Widget panel

    @available(macOS 14.2, *)
    @MainActor
    private func buildWidgetPanel() {
        let model = StudioViewModel.shared
        let size = NSSize(width: Theme.cardWidth, height: Theme.cardHeight)

        let root = CardView(model: model)
            .background(WidgetContextMenu(model: model))
            .background(WidgetClickCatcher { [weak self] in self?.showMainWindow() })
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = hosting
        panel.contentMinSize = size
        panel.contentMaxSize = size

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 24, y: vf.minY + 24))
        }
        // Start hidden — the main window opens on launch.
        self.widgetPanel = panel
    }

    private var showWidgetOnMinimize: Bool {
        UserDefaults.standard.object(forKey: "billiejean.showWidgetOnMinimize") as? Bool ?? true
    }

    // MARK: - Coordination

    @available(macOS 14.2, *)
    @MainActor
    private func showMainWindow() {
        (windowController as? MainWindowController)?.showWindow()
    }

    @MainActor
    private func handleWindowVisible() {
        widgetForcedVisible = false
        widgetPanel?.orderOut(nil)
    }

    @MainActor
    private func handleWindowHidden() {
        if showWidgetOnMinimize {
            widgetPanel?.orderFrontRegardless()
        }
    }

    @MainActor
    private func toggleWidgetManually() {
        guard let panel = widgetPanel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            widgetForcedVisible = false
        } else {
            panel.orderFrontRegardless()
            widgetForcedVisible = true
        }
    }

    // MARK: - Reopen (Dock icon)

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if #available(macOS 14.2, *) {
            MainActor.assumeIsolated { showMainWindow() }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if #available(macOS 14.2, *) {
            MainActor.assumeIsolated {
                StudioViewModel.shared.shutdown()
            }
        }
    }
}

/// Bridges a single click on the widget's card (not the knobs) to reopen the
/// main window. Sits behind the card; knob catchers swallow their own clicks.
@available(macOS 14.2, *)
struct WidgetClickCatcher: NSViewRepresentable {
    var onClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = ClickView()
        v.onClick = onClick
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ClickView)?.onClick = onClick
    }

    final class ClickView: NSView {
        var onClick: (() -> Void)?
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseUp(with event: NSEvent) {
            // Single click on the record area reopens the main window.
            if event.clickCount == 1 { onClick?() }
        }
    }
}

/// Menu-bar status item — the primary control surface: transport, A/B,
/// skins, and quit, always one click away. The menu is rebuilt each time it
/// opens so checkmarks always reflect current state.
@available(macOS 14.2, *)
final class StatusMenuController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    /// Reopen the main window (top menu item).
    var openMainWindow: (() -> Void)?

    @MainActor
    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "opticaldisc.fill",
            accessibilityDescription: "billiejean"
        )
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let (running, bypass, skinKind) = MainActor.assumeIsolated {
            let model = StudioViewModel.shared
            return (model.isRunning, model.bypass, model.skinKind)
        }
        let widgetOnMinimize = UserDefaults.standard.object(
            forKey: "billiejean.showWidgetOnMinimize"
        ) as? Bool ?? true

        let open = NSMenuItem(title: "Open billiejean", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let transport = NSMenuItem(
            title: running ? "Stop" : "Start",
            action: #selector(toggleTransport), keyEquivalent: ""
        )
        transport.target = self
        menu.addItem(transport)

        menu.addItem(.separator())

        let vinyl = NSMenuItem(title: "Vinyl", action: #selector(useVinyl), keyEquivalent: "")
        vinyl.target = self
        vinyl.state = bypass ? .off : .on
        menu.addItem(vinyl)

        let original = NSMenuItem(title: "Original", action: #selector(useOriginal), keyEquivalent: "")
        original.target = self
        original.state = bypass ? .on : .off
        menu.addItem(original)

        menu.addItem(.separator())

        for kind in SkinKind.allCases {
            let item = NSMenuItem(
                title: "\(kind.displayName) Skin",
                action: #selector(selectSkin(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = kind.rawValue
            item.state = kind == skinKind ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let widgetToggle = NSMenuItem(
            title: "Show Widget on Minimize",
            action: #selector(toggleWidgetOnMinimize), keyEquivalent: ""
        )
        widgetToggle.target = self
        widgetToggle.state = widgetOnMinimize ? .on : .off
        menu.addItem(widgetToggle)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit billiejean", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func openWindow() {
        openMainWindow?()
    }

    @objc private func toggleWidgetOnMinimize() {
        let current = UserDefaults.standard.object(
            forKey: "billiejean.showWidgetOnMinimize"
        ) as? Bool ?? true
        UserDefaults.standard.set(!current, forKey: "billiejean.showWidgetOnMinimize")
    }

    @objc private func toggleTransport() {
        MainActor.assumeIsolated { StudioViewModel.shared.toggleRunning() }
    }
    @objc private func useVinyl() {
        MainActor.assumeIsolated { StudioViewModel.shared.bypass = false }
    }
    @objc private func useOriginal() {
        MainActor.assumeIsolated { StudioViewModel.shared.bypass = true }
    }
    @objc private func selectSkin(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = SkinKind(rawValue: raw) else { return }
        MainActor.assumeIsolated { StudioViewModel.shared.skinKind = kind }
    }
    @objc private func quit() {
        MainActor.assumeIsolated {
            StudioViewModel.shared.shutdown()
            NSApp.terminate(nil)
        }
    }
}

/// Bridges an AppKit right-click menu onto the whole card, since a borderless
/// panel has no default menu. Right-click anywhere shows Start/Stop, the
/// Original/Vinyl bypass toggle, and Quit.
@available(macOS 14.2, *)
struct WidgetContextMenu: NSViewRepresentable {
    var model: StudioViewModel

    func makeNSView(context: Context) -> NSView {
        let view = MenuHostView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MenuHostView)?.model = model
    }

    @available(macOS 14.2, *)
    final class MenuHostView: NSView {
        weak var model: StudioViewModel?

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let model else { return nil }
            let menu = NSMenu()

            let transport = NSMenuItem(
                title: model.isRunning ? "Stop" : "Start",
                action: #selector(toggleTransport), keyEquivalent: ""
            )
            transport.target = self
            menu.addItem(transport)

            menu.addItem(.separator())

            let vinyl = NSMenuItem(title: "Vinyl", action: #selector(useVinyl), keyEquivalent: "")
            vinyl.target = self
            vinyl.state = model.bypass ? .off : .on
            menu.addItem(vinyl)

            let original = NSMenuItem(title: "Original", action: #selector(useOriginal), keyEquivalent: "")
            original.target = self
            original.state = model.bypass ? .on : .off
            menu.addItem(original)

            menu.addItem(.separator())

            let skinItem = NSMenuItem(title: "Skin", action: nil, keyEquivalent: "")
            let skinMenu = NSMenu()
            let currentSkin = MainActor.assumeIsolated { model.skinKind }
            for kind in SkinKind.allCases {
                let item = NSMenuItem(
                    title: kind.displayName,
                    action: #selector(selectSkin(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = kind.rawValue
                item.state = kind == currentSkin ? .on : .off
                skinMenu.addItem(item)
            }
            skinItem.submenu = skinMenu
            menu.addItem(skinItem)

            menu.addItem(.separator())

            let quit = NSMenuItem(title: "Quit Vinylfy", action: #selector(quit), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)

            return menu
        }

        @objc private func selectSkin(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let kind = SkinKind(rawValue: raw) else { return }
            MainActor.assumeIsolated { model?.skinKind = kind }
        }

        @objc private func toggleTransport() {
            MainActor.assumeIsolated { model?.toggleRunning() }
        }
        @objc private func useVinyl() {
            MainActor.assumeIsolated { model?.bypass = false }
        }
        @objc private func useOriginal() {
            MainActor.assumeIsolated { model?.bypass = true }
        }
        @objc private func quit() {
            MainActor.assumeIsolated { model?.shutdown() }
            NSApp.terminate(nil)
        }
    }
}
