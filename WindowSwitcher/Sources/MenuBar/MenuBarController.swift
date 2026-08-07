import AppKit
import SwiftUI

// MARK: - MenuItemView

private final class MenuItemView: NSView {
    var title: String { didSet { needsDisplay = true } }
    var isOn: Bool { didSet { needsDisplay = true } }
    var isEnabled: Bool { didSet { needsDisplay = true } }
    var showsHighlight: Bool
    var selectable: Bool
    var onClick: (() -> Void)?
    var debugTag: String = "?"

    private(set) var isHighlighted = false {
        didSet {
            if oldValue != isHighlighted {
                needsDisplay = true
                logDebug("[MENU-HOVER] [\(debugTag)] isHighlighted: \(oldValue) → \(isHighlighted)")
            }
        }
    }
    private var hoverTimer: Timer?

    init(title: String, isOn: Bool, isEnabled: Bool, showsHighlight: Bool,
         selectable: Bool, onClick: (() -> Void)?) {
        self.title = title
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.showsHighlight = showsHighlight
        self.selectable = selectable
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        wantsLayer = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        logDebug("[MENU-VIEW] [\(debugTag)] viewDidMoveToWindow, window=\(window != nil ? "yes" : "nil"), showsHighlight=\(showsHighlight), isEnabled=\(isEnabled)")
        if window != nil, showsHighlight, isEnabled {
            startHoverTimer()
        } else {
            stopHoverTimer()
        }
    }

    deinit { stopHoverTimer() }

    private func startHoverTimer() {
        stopHoverTimer()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.pollMouseLocation()
        }
        RunLoop.current.add(timer, forMode: .default)
        RunLoop.current.add(timer, forMode: .eventTracking)
        hoverTimer = timer
    }

    private func stopHoverTimer() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        isHighlighted = false
    }

    private func pollMouseLocation() {
        guard let w = window, isEnabled, showsHighlight else { return }
        let windowPt = w.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPt = convert(windowPt, from: nil)
        let inside = bounds.contains(localPt)
        if inside != isHighlighted {
            isHighlighted = inside
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, selectable else { return }
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = true

        if isHighlighted, showsHighlight {
            NSColor.selectedContentBackgroundColor.set()
            bounds.fill()
        }

        let textColor: NSColor
        if isHighlighted, showsHighlight {
            textColor = .selectedMenuItemTextColor
        } else if !isEnabled {
            textColor = .labelColor.withAlphaComponent(0.4)
        } else {
            textColor = .labelColor
        }

        let font = NSFont.systemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: NSFont.Weight(0.1))
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]

        if isOn {
            let ck = NSAttributedString(string: "\u{2713}", attributes: attrs)
            let ckSize = ck.size()
            ck.draw(at: NSPoint(x: 8, y: (bounds.height - ckSize.height) / 2))
        }

        let t = NSAttributedString(string: title, attributes: attrs)
        let tSize = t.size()
        t.draw(at: NSPoint(x: 23, y: (bounds.height - tSize.height) / 2))
    }
}

// MARK: - MenuBarController

final class MenuBarController: NSObject, NSMenuDelegate {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    // Custom view references for dynamic state updates
    private weak var startServiceView: MenuItemView?
    private weak var stopServiceView: MenuItemView?
    private weak var restartServiceView: MenuItemView?
    private weak var immersiveToggleView: MenuItemView?
    private weak var quickSwitchToggleView: MenuItemView?
    private weak var cyclicToggleView: MenuItemView?
    private weak var elasticDragToggleView: MenuItemView?
    private weak var hintShakeToggleView: MenuItemView?
    private weak var displacementLabelView: MenuItemView?
    private weak var threeFingerTapToggleView: MenuItemView?
    private weak var threeFingerSwipeUpToggleView: MenuItemView?
    private weak var centerFocusToggleView: MenuItemView?

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
        menu.delegate = self
        rebuildMenuItems()
        statusItem?.menu = menu
    }

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
        let startItem = makeActionItem(title: "启动服务", isEnabled: !running) { [weak self] in
            self?.startService()
        }
        startServiceView = menuItemView(from: startItem)
        menu.addItem(startItem)

        let stopItem = makeActionItem(title: "停止服务", isEnabled: running) { [weak self] in
            self?.stopService()
        }
        stopServiceView = menuItemView(from: stopItem)
        menu.addItem(stopItem)

        let restartItem = makeActionItem(title: "重启服务", isEnabled: running) { [weak self] in
            self?.restartService()
        }
        restartServiceView = menuItemView(from: restartItem)
        menu.addItem(restartItem)

        menu.addItem(.separator())

        // Mode toggles
        let immersiveItem = makeToggleItem(title: "沉浸预览模式",
                                            isOn: AppSettings.shared.immersiveModeEnabled) {
            AppSettings.shared.immersiveModeEnabled.toggle()
            self.immersiveToggleView?.isOn = AppSettings.shared.immersiveModeEnabled
        }
        immersiveToggleView = menuItemView(from: immersiveItem)
        menu.addItem(immersiveItem)

        let quickSwitchItem = makeToggleItem(title: "快捷切换模式",
                                              isOn: AppSettings.shared.quickSwitchModeEnabled) {
            AppSettings.shared.quickSwitchModeEnabled.toggle()
            self.quickSwitchToggleView?.isOn = AppSettings.shared.quickSwitchModeEnabled
        }
        quickSwitchToggleView = menuItemView(from: quickSwitchItem)
        menu.addItem(quickSwitchItem)

        let cyclicItem = makeToggleItem(title: "循环滚动",
                                         isOn: AppSettings.shared.cyclicScrollEnabled) {
            AppSettings.shared.cyclicScrollEnabled.toggle()
            self.cyclicToggleView?.isOn = AppSettings.shared.cyclicScrollEnabled
        }
        cyclicToggleView = menuItemView(from: cyclicItem)
        menu.addItem(cyclicItem)

        menu.addItem(.separator())

        // Elastic drag settings submenu
        buildElasticSubmenu()

        // Activation submenu
        buildActivationSubmenu()

        menu.addItem(.separator())

        // Settings — MenuItemView, closes menu before opening settings window
        let settingsItem = makeActionItem(title: "显示设置...", isEnabled: true) { [weak self] in
            guard let self else { return }
            self.menu.cancelTracking()
            DispatchQueue.main.async { self.openSettings() }
        }
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // Quit — MenuItemView, closes menu before terminating
        let quitItem = makeActionItem(title: "退出", isEnabled: true) { [weak self] in
            guard let self else { return }
            self.menu.cancelTracking()
            DispatchQueue.main.async {
                GestureEngine.shared.stop()
                WindowManager.shared.stopInteractionMonitoring()
                NSApplication.shared.terminate(nil)
            }
        }
        menu.addItem(quitItem)

        updateIconAppearance()
    }

    private func buildElasticSubmenu() {
        let sub = NSMenu()
        sub.autoenablesItems = false

        let elasticToggle = makeToggleItem(title: "弹性拖拽回弹",
                                            isOn: AppSettings.shared.elasticDragEnabled) {
            AppSettings.shared.elasticDragEnabled.toggle()
            self.elasticDragToggleView?.isOn = AppSettings.shared.elasticDragEnabled
        }
        elasticDragToggleView = menuItemView(from: elasticToggle)
        sub.addItem(elasticToggle)

        let hintShake = makeToggleItem(title: "提示文字抖动",
                                        isOn: AppSettings.shared.hintShakeEnabled) {
            AppSettings.shared.hintShakeEnabled.toggle()
            self.hintShakeToggleView?.isOn = AppSettings.shared.hintShakeEnabled
        }
        hintShakeToggleView = menuItemView(from: hintShake)
        sub.addItem(hintShake)

        sub.addItem(.separator())

        let disp = AppSettings.shared.elasticDragMaxDisplacement
        let labelItem = makeLabelItem(title: "最大偏移像素 \(disp)px")
        displacementLabelView = menuItemView(from: labelItem)
        sub.addItem(labelItem)

        let decreaseItem = makeActionItem(title: "减小偏移 (−10px)", isEnabled: true) { [weak self] in
            guard let self else { return }
            let v = max(10, AppSettings.shared.elasticDragMaxDisplacement - 10)
            AppSettings.shared.elasticDragMaxDisplacement = v
            self.displacementLabelView?.title = "最大偏移像素 \(v)px"
        }
        sub.addItem(decreaseItem)

        let increaseItem = makeActionItem(title: "增大偏移 (+10px)", isEnabled: true) { [weak self] in
            guard let self else { return }
            let v = min(200, AppSettings.shared.elasticDragMaxDisplacement + 10)
            AppSettings.shared.elasticDragMaxDisplacement = v
            self.displacementLabelView?.title = "最大偏移像素 \(v)px"
        }
        sub.addItem(increaseItem)

        // Parent — standard NSMenuItem for native submenu tracking (hover auto-open)
        let parentItem = NSMenuItem(title: "弹性拖拽设置", action: nil, keyEquivalent: "")
        parentItem.submenu = sub
        parentItem.image = menuIndentImage()
        menu.addItem(parentItem)
    }

    private func buildActivationSubmenu() {
        let sub = NSMenu()
        sub.autoenablesItems = false

        let tapToggle = makeToggleItem(title: "三指轻点激活",
                                       isOn: AppSettings.shared.threeFingerTapEnabled) {
            AppSettings.shared.threeFingerTapEnabled.toggle()
            self.threeFingerTapToggleView?.isOn = AppSettings.shared.threeFingerTapEnabled
        }
        threeFingerTapToggleView = menuItemView(from: tapToggle)
        sub.addItem(tapToggle)

        let swipeUpToggle = makeToggleItem(title: "三指上扫激活",
                                           isOn: AppSettings.shared.threeFingerSwipeUpEnabled) {
            AppSettings.shared.threeFingerSwipeUpEnabled.toggle()
            self.threeFingerSwipeUpToggleView?.isOn = AppSettings.shared.threeFingerSwipeUpEnabled
        }
        threeFingerSwipeUpToggleView = menuItemView(from: swipeUpToggle)
        sub.addItem(swipeUpToggle)

        sub.addItem(.separator())

        let centerFocus = makeToggleItem(title: "焦点居中",
                                         isOn: AppSettings.shared.centerFocusEnabled) {
            AppSettings.shared.centerFocusEnabled.toggle()
            self.centerFocusToggleView?.isOn = AppSettings.shared.centerFocusEnabled
        }
        centerFocusToggleView = menuItemView(from: centerFocus)
        sub.addItem(centerFocus)

        let parentItem = NSMenuItem(title: "预览模式设置", action: nil, keyEquivalent: "")
        parentItem.submenu = sub
        parentItem.image = menuIndentImage()
        menu.addItem(parentItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenuItems()
    }

    // MARK: - View factories

    private func makeCustomItem(title: String, isOn: Bool, isEnabled: Bool,
                                 showsHighlight: Bool, selectable: Bool,
                                 onClick: (() -> Void)?) -> NSMenuItem {
        let item = NSMenuItem()
        let view = MenuItemView(title: title, isOn: isOn, isEnabled: isEnabled,
                                 showsHighlight: showsHighlight, selectable: selectable,
                                 onClick: onClick)
        item.view = view
        return item
    }

    private func makeToggleItem(title: String, isOn: Bool,
                                 onClick: @escaping () -> Void) -> NSMenuItem {
        makeCustomItem(title: title, isOn: isOn, isEnabled: true,
                        showsHighlight: true, selectable: true, onClick: onClick)
    }

    private func makeActionItem(title: String, isEnabled: Bool,
                                 onClick: @escaping () -> Void) -> NSMenuItem {
        makeCustomItem(title: title, isOn: false, isEnabled: isEnabled,
                        showsHighlight: true, selectable: true, onClick: onClick)
    }

    private func makeLabelItem(title: String) -> NSMenuItem {
        makeCustomItem(title: title, isOn: false, isEnabled: false,
                        showsHighlight: false, selectable: false, onClick: nil)
    }

    private func menuItemView(from item: NSMenuItem) -> MenuItemView? {
        item.view as? MenuItemView
    }

    private func menuIndentImage() -> NSImage {
        NSImage(size: NSSize(width: 8, height: 12), flipped: false) { _ in true }
    }

    // MARK: - Icon

    func updateIconAppearance() {
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

    // MARK: - Service control actions

    private func startService() {
        AppDelegate.shared.startService()
        updateIconAppearance()
        startServiceView?.isEnabled = false
        stopServiceView?.isEnabled = true
        restartServiceView?.isEnabled = true
    }

    private func stopService() {
        AppDelegate.shared.stopService()
        updateIconAppearance()
        startServiceView?.isEnabled = true
        stopServiceView?.isEnabled = false
        restartServiceView?.isEnabled = false
    }

    private func restartService() {
        AppDelegate.shared.restartService()
        updateIconAppearance()
        startServiceView?.isEnabled = false
        stopServiceView?.isEnabled = true
        restartServiceView?.isEnabled = true
    }

    // MARK: - Settings / Quit

    private func openSettings() {
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
}
