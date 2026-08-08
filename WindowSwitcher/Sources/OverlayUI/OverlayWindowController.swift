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

    private init() {}

    // MARK: - Show / Hide

    func show(with windows: [WindowInfo]) {
        guard !windows.isEmpty else { return }

        if panel == nil {
            createPanel()
        }

        viewModel.show(windows: windows)

        let withThumbnails = windows.filter { $0.thumbnail != nil }.count
        logDebug("CAPTURE-UI: overlay show, windows=\(windows.count), withThumbnails=\(withThumbnails)")

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

        // Scroll-wheel monitor.
        //
        // All events forwarded to NSScrollView for native live scrolling
        // and native inertia — zero interference with the scroll curve.
        //
        // Mode A (centerFocus disabled): focus = cursor X.
        // Mode B (centerFocus enabled):  focus = screen horizontal center;
        //         after scrolling fully stops, snap the nearest card so its
        //         center aligns with the focus point.
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let sv = self.viewModel.scrollView else { return event }

            let centerFocus = AppSettings.shared.centerFocusEnabled
            let targetX: CGFloat = centerFocus
                ? (NSScreen.main?.frame.width ?? 0) / 2
                : NSEvent.mouseLocation.x

            // Forward ALL events for native curve.
            sv.scrollWheel(with: event)

            // Update hover.
            if let idx = self.nearestCardIndex(to: targetX) {
                self.viewModel.hoveredIndex = idx
            }

            // Mode B: on scroll-complete, snap nearest card to focus point.
            // Snap is independently disabled by centerSnapEnabled.
            if centerFocus, AppSettings.shared.centerSnapEnabled,
               let snapIdx = self.nearestCardIndex(to: targetX),
               let cardFrame = self.viewModel.cardFrames[snapIdx] {

                let isScrollComplete = event.momentumPhase.contains(.ended)
                                    || (event.phase == .ended && event.momentumPhase.isEmpty)

                if isScrollComplete {
                    let currentX = sv.contentView.bounds.origin.x
                    var targetOriginX = cardFrame.midX + currentX - targetX
                    let maxX = max(0, sv.documentView!.frame.width - sv.contentView.bounds.width)
                    targetOriginX = min(max(targetOriginX, 0), maxX)

                    logDebug("SNAP: idx=\(snapIdx) currentX=\(Int(currentX)) targetX=\(Int(targetOriginX)) delta=\(Int(targetOriginX - currentX)) centerFocus=\(centerFocus)")

                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.15
                        ctx.allowsImplicitAnimation = true
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        sv.contentView.animator().setBoundsOrigin(
                            NSPoint(x: targetOriginX, y: sv.contentView.bounds.origin.y)
                        )
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
        logDebug("CAPTURE-UI: overlay hide called, isVisible=\(isVisible)")
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
    }

    // MARK: - Thumbnail refresh

    func refreshThumbnails() {
        viewModel.windows = WindowManager.shared.orderedWindows
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
