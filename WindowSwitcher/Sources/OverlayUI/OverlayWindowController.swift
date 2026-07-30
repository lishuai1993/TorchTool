import AppKit
import SwiftUI

final class OverlayWindowController {
    static let shared = OverlayWindowController()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<OverlayView>?

    var isVisible: Bool { panel?.isVisible ?? false }

    // State
    private var windows: [WindowInfo] = []
    private var focusedIndex: Int = 0
    private var dismissTimer: Timer?

    // Callbacks
    var onWindowSelected: ((WindowInfo) -> Void)?
    var onDismiss: (() -> Void)?

    private init() {}

    // MARK: - Show / Hide

    func show(with windows: [WindowInfo]) {
        guard !windows.isEmpty else { return }

        self.windows = windows
        self.focusedIndex = windows.count / 2

        let settings = AppSettings.shared

        // Preload thumbnails
        WindowManager.shared.preloadThumbnails(count: min(windows.count, settings.maxVisibleCount))

        if panel == nil {
            createPanel()
        }

        // Rebuild the SwiftUI view with current data
        rebuildHostingView()

        panel?.makeKeyAndOrderFront(nil)
        resetDismissTimer()
    }

    func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
        onDismiss?()
    }

    // MARK: - Navigation (called from gesture handler)

    func moveFocusRight() {
        guard !windows.isEmpty else { return }
        let settings = AppSettings.shared
        focusedIndex = min(focusedIndex + 1, windows.count - 1)
        updateFocusBinding()
        withAnimation(settings.animationDuration) {
            rebuildHostingView()
        }
        resetDismissTimer()
    }

    func moveFocusLeft() {
        guard !windows.isEmpty else { return }
        let settings = AppSettings.shared
        focusedIndex = max(focusedIndex - 1, 0)
        updateFocusBinding()
        withAnimation(settings.animationDuration) {
            rebuildHostingView()
        }
        resetDismissTimer()
    }

    func selectFocused() {
        guard focusedIndex >= 0, focusedIndex < windows.count else { return }
        let selected = windows[focusedIndex]
        hide()
        WindowManager.shared.activateWindow(selected.id)
        onWindowSelected?(selected)
    }

    func updateProgress(_ progress: Float) {
        // Map progress to an index offset for continuous swipe tracking
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

        self.panel = panel
    }

    private func rebuildHostingView() {
        let binding = Binding<Int>(
            get: { self.focusedIndex },
            set: { self.focusedIndex = $0 }
        )

        let overlayView = OverlayView(
            windows: windows,
            focusedIndex: binding,
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
        hosting.frame = panel?.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]

        panel?.contentView = hosting
        self.hostingView = hosting
    }

    private func updateFocusBinding() {
        hostingView?.rootView = OverlayView(
            windows: windows,
            focusedIndex: Binding<Int>(
                get: { self.focusedIndex },
                set: { self.focusedIndex = $0 }
            ),
            onSelect: { [weak self] window in
                self?.hide()
                WindowManager.shared.activateWindow(window.id)
                self?.onWindowSelected?(window)
            },
            onDismiss: { [weak self] in
                self?.hide()
            }
        )
    }

    private func resetDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.overlayDismissTimeout,
            repeats: false
        ) { [weak self] _ in
            self?.hide()
        }
    }

    private func withAnimation(_ duration: TimeInterval, _ block: () -> Void) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(
                name: .easeOut
            )
            block()
        }
    }
}
