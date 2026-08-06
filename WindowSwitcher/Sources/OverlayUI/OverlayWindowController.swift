import AppKit
import SwiftUI

final class OverlayWindowController {
    static let shared = OverlayWindowController()

    private var panel: NSPanel?
    private let viewModel = OverlayViewModel()

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
        panel?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
        viewModel.hide()
        onDismiss?()
    }

    // MARK: - Navigation

    func moveFocusRight() {
        viewModel.moveFocusRight()
    }

    func moveFocusLeft() {
        viewModel.moveFocusLeft()
    }

    func selectFocused() {
        guard let window = viewModel.selectFocused() else { return }
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
