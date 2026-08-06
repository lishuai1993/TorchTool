import AppKit
import SwiftUI

final class OverlayWindowController {
    static let shared = OverlayWindowController()

    private var panel: NSPanel?
    private let viewModel = OverlayViewModel()
    private var localKeyMonitor: Any?
    private var mouseMoveMonitor: Any?
    private var scrollWheelMonitor: Any?

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

        // Global mouse tracking: map cursor X to the nearest card's index,
        // enabling full-screen hover detection (not just within card rects).
        panel?.acceptsMouseMovedEvents = true
        mouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self else { return event }
            if let idx = self.nearestCardIndex(to: NSEvent.mouseLocation.x),
               idx != self.viewModel.hoveredIndex {
                self.viewModel.hoveredIndex = idx
            }
            return event
        }

        // Scroll-wheel monitor: forward events to NSScrollView for full-screen
        // trackpad scrolling. Manually track hover (onHover doesn't fire when
        // events are consumed). On finger lift, correct the offset so the card
        // nearest to cursor aligns its center with the cursor X.
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let sv = self.viewModel.scrollView else { return event }
            sv.scrollWheel(with: event)

            // Update hover from card frames (onHover doesn't fire since we consume the event)
            let mouseX = NSEvent.mouseLocation.x
            if let idx = self.nearestCardIndex(to: mouseX) {
                self.viewModel.hoveredIndex = idx
            }

            if event.phase == .ended, let idx = self.viewModel.hoveredIndex {
                // Defer to next run loop so GeometryReader has updated cardFrames
                // after NSScrollView.scrollWheel(with:) changed bounds synchronously.
                let snapMouseX = mouseX
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          let sv = self.viewModel.scrollView,
                          let cardFrame = self.viewModel.cardFrames[idx] else { return }
                    let currentX = sv.contentView.bounds.origin.x
                    let correction = cardFrame.midX - snapMouseX
                    var newX = currentX + correction
                    let maxX = max(0, sv.documentView!.frame.width - sv.contentView.bounds.width)
                    newX = min(max(newX, 0), maxX)
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.2
                        ctx.allowsImplicitAnimation = true
                        sv.contentView.scroll(to: NSPoint(x: newX, y: sv.contentView.bounds.origin.y))
                    }
                }
            }
            return nil
        }

        // Local event monitor for overlay keyboard navigation.
        // Sync focusedIndex from hoveredIndex before each action, so keyboard
        // and trackpad scrolling always share the same baseline cursor.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53: // ESC
                self.hide()
                return nil
            case 36: // Enter
                self.syncFromHover()
                self.selectFocused()
                return nil
            case 123: // Left arrow
                self.syncFromHover()
                self.viewModel.moveFocusLeft()
                return nil
            case 124: // Right arrow
                self.syncFromHover()
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
        if let m = mouseMoveMonitor {
            NSEvent.removeMonitor(m)
            mouseMoveMonitor = nil
        }
        if let m = scrollWheelMonitor {
            NSEvent.removeMonitor(m)
            scrollWheelMonitor = nil
        }
        panel?.orderOut(nil)
        viewModel.hide()
        onDismiss?()
    }

    // MARK: - Thumbnail refresh

    func refreshThumbnails() {
        let orderedIDs = WindowManager.shared.orderingEngine.orderedIDs
        viewModel.windows = orderedIDs.compactMap { WindowManager.shared.windows[$0] }
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

    /// Align focusedIndex to wherever the user's mouse is pointing (hoveredIndex).
    /// Called before each keyboard action so that keyboard and trackpad scrolling
    /// always start from the same baseline.
    private func syncFromHover() {
        if let h = viewModel.hoveredIndex {
            viewModel.focusedIndex = h
        }
        viewModel.hoveredIndex = nil
    }

    /// Sync focusedIndex to the current frontmost window's position in the LRU list.
    /// Keeps keyboard arrow focus and gesture-driven focus on the same baseline.
    func syncFocusedIndex() {
        let orderedIDs = WindowManager.shared.orderingEngine.orderedIDs
        let oldIdx = viewModel.focusedIndex
        guard let frontID = WindowManager.shared.frontmostWindowID,
              let idx = orderedIDs.firstIndex(of: frontID) else {
            logDebug("FOCUS-SYNC: frontID=\(WindowManager.shared.frontmostWindowID?.description ?? "nil"), orderedIDs.count=\(orderedIDs.count), NOT synced")
            return
        }
        logDebug("FOCUS-SYNC: oldFocused=\(oldIdx) → newFocused=\(idx), frontID=\(frontID), hovered=\(String(describing: viewModel.hoveredIndex))")
        viewModel.focusedIndex = idx
        viewModel.hoveredIndex = nil
    }

    func updateProgress(_ progress: Float) {
        // Continuous swipe tracking — reserved for future use.
    }

    // MARK: - Helpers

    /// Find the card index whose horizontal center is closest to the given X.
    private func nearestCardIndex(to mouseX: CGFloat) -> Int? {
        var bestIdx: Int?
        var bestDist = CGFloat.infinity
        for (idx, frame) in viewModel.cardFrames {
            let dist = abs(frame.midX - mouseX)
            if dist < bestDist {
                bestDist = dist
                bestIdx = idx
            }
        }
        return bestIdx
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
