import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    private(set) var islandController: IslandWindowController?
    private var dndCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE — prevents crash when nb-hook closes socket before we write response
        signal(SIGPIPE, SIG_IGN)
        // Warm up Keychain cache on main thread BEFORE any poller or view touches it
        _ = KeychainStore.shared
        NSApp.setActivationPolicy(.accessory)
        setupMenuBarItem()
        setupIsland()
    }

    // MARK: - Menu bar

    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon()

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Open Coucou", action: #selector(openIsland), keyEquivalent: "")
        let dndItem = NSMenuItem(title: "Do Not Disturb", action: #selector(toggleDND), keyEquivalent: "")
        dndItem.state = AppState.shared.isDND ? .on : .off
        menu.addItem(dndItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem?.menu = menu

        dndCancellable = AppState.shared.$isDND
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBarIcon()
            }
    }

    func updateMenuBarIcon() {
        guard let button = statusItem?.button else { return }
        let isDND = AppState.shared.isDND
        let imageName = isDND ? "MenuBarIconSleep" : "MenuBarIcon"
        let fallbackSymbol = isDND ? "moon.fill" : "circle.fill"
        let img = NSImage(named: imageName) ?? NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: "Coucou")
        img?.size = NSSize(width: 24, height: 18)
        img?.accessibilityDescription = isDND ? "Coucou (Mode sommeil)" : "Coucou"
        img?.isTemplate = true
        button.image = img
        button.toolTip = isDND ? "Coucou — Mode sommeil (Ne pas déranger)" : "Coucou"
    }

    // MARK: - Actions

    @objc private func openIsland() {
        islandController?.expand(to: .overview)
    }

    @objc private func toggleDND() {
        AppState.shared.toggleDND()
    }

    private var settingsWindow: NSWindow?

    @objc private func openSettings() {
        if let w = settingsWindow, w.isVisible { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 540),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Settings — Coucou"
        win.contentView = NSHostingView(rootView: SettingsView())
        win.center()
        win.isReleasedWhenClosed = false
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Island setup

    private func setupIsland() {
        islandController = IslandWindowController()
        islandController?.showWindow(nil)
        if !AppState.shared.isDND {
            islandController?.fsm.launch()
        }
        HookServer.shared.start()
        N8nPoller.shared.start()
        VercelPoller.shared.start()
        ResendPoller.shared.start()
        GithubPoller.shared.start()
        StripePoller.shared.start()
        CalcomPoller.shared.start()
        NotionPoller.shared.start()
        AntigravityContextService.shared.start()
        NotificationCenter.default.addObserver(self, selector: #selector(openSettings),
                                               name: .openFullSettings, object: nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if let item = menu.item(withTitle: "Do Not Disturb") {
            item.state = AppState.shared.isDND ? .on : .off
        }
    }
}
