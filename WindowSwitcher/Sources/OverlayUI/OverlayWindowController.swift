import AppKit
import SwiftUI

final class OverlayWindowController {
    static let shared = OverlayWindowController()

    private var panel: NSPanel?
    private let viewModel = OverlayViewModel()
    private var localKeyMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    var onWindowSelected: ((WindowInfo) -> Void)?
    var onDismiss: (() -> Void)?

    private init() {}

    // MARK: - Show / Hide

    func show(with windows: [WindowInfo]) {
        guard !windows.isEmpty else { return }

        if panel == nil {
            createPanel()
        }

        viewModel.show(windows: windows)

        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)

        // Local event monitor for overlay keyboard navigation.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53: // ESC
                self.hide()
                return nil
            case 36: // Enter
                self.selectFocused()
                return nil
            case 123: // Left arrow
                self.viewModel.moveFocusLeft()
                return nil
            case 124: // Right arrow
                self.viewModel.moveFocusRight()
                return nil
            default:
                return event
            }
        }
    }

    func hide() {
        if let m = localKeyMonitor {
            NSEvent.removeMonitor(m)
            localKeyMonitor = nil
        }
        panel?.orderOut(nil)
        viewModel.hide()
        onDismiss?()
    }

    // MARK: - Navigation

    func moveFocusRight() {
        logDebug("OVERLAY-CTRL: moveFocusRight, windows=\(viewModel.windows.count), focusedIndex=\(viewModel.focusedIndex)")
        viewModel.moveFocusRight()
    }

    func moveFocusLeft() {
        logDebug("OVERLAY-CTRL: moveFocusLeft, windows=\(viewModel.windows.count), focusedIndex=\(viewModel.focusedIndex)")
        viewModel.moveFocusLeft()
    }

    func selectFocused() {
        guard let window = viewModel.selectFocused() else { return }
        logDebug("OVERLAY-SELECT: window=\(window.ownerName) — \(window.windowTitle)")
        hide()
        WindowManager.shared.activateWindow(window.id)
        onWindowSelected?(window)
    }

    func updateProgress(_ progress: Float) {
        // Continuous swipe tracking — reserved for future use.
    }

    // MARK: - Private

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSScreen.main?.frame ?? .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false

        let overlayView = OverlayView(
            viewModel: viewModel,
            onSelect: { [weak self] window in
                logDebug("OVERLAY-CLICK: window=\(window.ownerName) — \(window.windowTitle)")
                self?.hide()
                WindowManager.shared.activateWindow(window.id)
                self?.onWindowSelected?(window)
            },
            onDismiss: { [weak self] in
                self?.hide()
            }
        )
        let hosting = NSHostingView(rootView: overlayView)
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel
    }

}
