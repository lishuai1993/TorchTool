import AppKit
import SwiftUI

final class MenuBarController: NSObject, NSMenuDelegate {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    private override init() {
        super.init()
    }

    func setup() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        guard let button = statusItem?.button else { return }

        // Use SF Symbol for the menu bar icon
        if let image = NSImage(
            systemSymbolName: "rectangle.3.group",
            accessibilityDescription: "WindowSwitcher"
        ) {
            button.image = image
            button.image?.isTemplate = true
        } else {
            button.title = "WS"
        }

        buildMenu()
    }

    func remove() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.minimumWidth = 220

        // Header
        let headerItem = NSMenuItem()
        headerItem.title = "WindowSwitcher"
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())

        // Service toggle
        let toggleItem = NSMenuItem(
            title: "启用服务",
            action: #selector(toggleService),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.state = AppSettings.shared.serviceEnabled ? .on : .off
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        // Mode toggles
        let immersiveItem = NSMenuItem(
            title: "沉浸式预览模式",
            action: #selector(toggleImmersiveMode),
            keyEquivalent: ""
        )
        immersiveItem.target = self
        immersiveItem.state = AppSettings.shared.immersiveModeEnabled ? .on : .off
        menu.addItem(immersiveItem)

        let quickSwitchItem = NSMenuItem(
            title: "快捷切换模式",
            action: #selector(toggleQuickSwitchMode),
            keyEquivalent: ""
        )
        quickSwitchItem.target = self
        quickSwitchItem.state = AppSettings.shared.quickSwitchModeEnabled ? .on : .off
        menu.addItem(quickSwitchItem)

        menu.addItem(.separator())

        // Settings
        menu.addItem(NSMenuItem(
            title: "显示设置...",
            action: #selector(openSettings),
            keyEquivalent: ","
        ).withTarget(self))
        menu.addItem(.separator())

        // Quit
        menu.addItem(NSMenuItem(
            title: "退出",
            action: #selector(quitApp),
            keyEquivalent: "q"
        ).withTarget(self))

        statusItem?.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Refresh menu item states
        buildMenu()
    }

    // MARK: - Actions

    @objc private func toggleService() {
        let newValue = !AppSettings.shared.serviceEnabled
        AppSettings.shared.serviceEnabled = newValue
        if newValue {
            _ = GestureEngine.shared.start()
            AppDelegate.shared.startAllServices()
        } else {
            GestureEngine.shared.stop()
            AppDelegate.shared.stopAllServices()
        }
    }

    @objc private func toggleImmersiveMode() {
        AppSettings.shared.immersiveModeEnabled.toggle()
    }

    @objc private func toggleQuickSwitchMode() {
        AppSettings.shared.quickSwitchModeEnabled.toggle()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingView(rootView: SettingsPanelView())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "WindowSwitcher 设置"
            window.contentView = hosting
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        GestureEngine.shared.stop()
        WindowManager.shared.stopInteractionMonitoring()
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - NSMenuItem helper

private extension NSMenuItem {
    func withTarget(_ target: AnyObject) -> NSMenuItem {
        self.target = target
        return self
    }
}
