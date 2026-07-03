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

/// Owns the floating always-on-top vinyl widget panel, auto-starts the engine,
/// wires the right-click context menu, and tears down on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var statusMenuController: AnyObject?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory app: no dock icon, floats over other apps, but still gets
        // a status item in the menu bar.
        NSApp.setActivationPolicy(.accessory)

        guard #available(macOS 14.2, *) else { return }
        MainActor.assumeIsolated {
            buildPanel()
            let controller = StatusMenuController()
            controller.install()
            statusMenuController = controller
            StudioViewModel.shared.bootstrap()
        }
    }

    @available(macOS 14.2, *)
    @MainActor
    private func buildPanel() {
        let model = StudioViewModel.shared
        let size = NSSize(width: Theme.cardWidth, height: Theme.cardHeight)

        let root = CardView(model: model)
            .background(WidgetContextMenu(model: model))
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

        // Bottom-right of the main screen's visible frame, 24pt margin.
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let origin = NSPoint(
                x: vf.maxX - size.width - 24,
                y: vf.minY + 24
            )
            panel.setFrameOrigin(origin)
        }

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func applicationWillTerminate(_ notification: Notification) {
        if #available(macOS 14.2, *) {
            MainActor.assumeIsolated {
                StudioViewModel.shared.shutdown()
            }
        }
    }
}

/// Menu-bar status item — the primary control surface: transport, A/B,
/// skins, and quit, always one click away. The menu is rebuilt each time it
/// opens so checkmarks always reflect current state.
@available(macOS 14.2, *)
final class StatusMenuController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    @MainActor
    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "opticaldisc.fill",
            accessibilityDescription: "Vinylfy"
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

        let quit = NSMenuItem(title: "Quit Vinylfy", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
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
