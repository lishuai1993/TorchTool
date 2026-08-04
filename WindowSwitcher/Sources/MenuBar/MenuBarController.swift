import AppKit
import SwiftUI

final class MenuBarController: NSObject, NSMenuDelegate {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    /// The menu is created once and its items are rebuilt on every open.
    private let menu: NSMenu = {
        let m = NSMenu()
        m.minimumWidth = 220
        m.autoenablesItems = false
        return m
    }()

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

    /// Assign the menu to the status item once. Only called from setup().
    private func buildMenu() {
        menu.delegate = self
        rebuildMenuItems()
        statusItem?.menu = menu
    }

    /// Remove all items and re-add with current states. Called on every menuWillOpen
    /// so the enable/disable and check states always match reality.
    private func rebuildMenuItems() {
        menu.removeAllItems()
        let running = AppDelegate.shared.serviceIsRunning

        // Header
        let headerItem = NSMenuItem()
        headerItem.title = "WindowSwitcher"
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())

        // Service controls
        let startItem = NSMenuItem(title: "启动服务", action: #selector(startServiceAction), keyEquivalent: "")
        startItem.target = self
        startItem.isEnabled = !running
        menu.addItem(startItem)

        let stopItem = NSMenuItem(title: "停止服务", action: #selector(stopServiceAction), keyEquivalent: "")
        stopItem.target = self
        stopItem.isEnabled = running
        menu.addItem(stopItem)

        let restartItem = NSMenuItem(title: "重启服务", action: #selector(restartServiceAction), keyEquivalent: "")
        restartItem.target = self
        restartItem.isEnabled = running
        menu.addItem(restartItem)

        menu.addItem(.separator())

        // Mode toggles
        let immersiveItem = NSMenuItem(title: "沉浸式预览模式", action: #selector(toggleImmersiveMode), keyEquivalent: "")
        immersiveItem.target = self
        immersiveItem.state = AppSettings.shared.immersiveModeEnabled ? .on : .off
        menu.addItem(immersiveItem)

        let quickSwitchItem = NSMenuItem(title: "快捷切换模式", action: #selector(toggleQuickSwitchMode), keyEquivalent: "")
        quickSwitchItem.target = self
        quickSwitchItem.state = AppSettings.shared.quickSwitchModeEnabled ? .on : .off
        menu.addItem(quickSwitchItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "显示设置...", action: #selector(openSettings), keyEquivalent: ",").withTarget(self))
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q").withTarget(self))

        updateIconAppearance()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenuItems()
    }

    /// Update only the button image color — called from actions for immediate feedback.
    /// Running: default template (system light/dark). Stopped: RGB(164,164,194).
    private func updateIconAppearance() {
        let running = AppDelegate.shared.serviceIsRunning
        if running {
            let img = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "WindowSwitcher")
            img?.isTemplate = true
            statusItem?.button?.image = img
        } else {
            let color = NSColor(red: 164.0 / 255.0, green: 164.0 / 255.0, blue: 194.0 / 255.0, alpha: 1.0)
            if let tpl = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil) {
                let colored = NSImage(size: tpl.size)
                colored.lockFocus()
                color.set()
                NSRect(origin: .zero, size: tpl.size).fill()
                tpl.draw(in: NSRect(origin: .zero, size: tpl.size), from: .zero, operation: .destinationIn, fraction: 1.0)
                colored.unlockFocus()
                colored.isTemplate = false
                statusItem?.button?.image = colored
            }
        }
    }

    // MARK: - Actions

    @objc private func startServiceAction() {
        AppDelegate.shared.startService()
        updateIconAppearance()
    }

    @objc private func stopServiceAction() {
        AppDelegate.shared.stopService()
        updateIconAppearance()
    }

    @objc private func restartServiceAction() {
        AppDelegate.shared.restartService()
        updateIconAppearance()
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
