import AppKit

/// Coordinates the immersive overlay presentation: window refresh, thumbnail
/// preloading (visible windows on main thread, remaining in background), and
/// timing diagnostics.
final class ImmersiveOverlayCoordinator {
    static let shared = ImmersiveOverlayCoordinator()

    private let windowManager = WindowManager.shared
    private let overlayController = OverlayWindowController.shared

    /// Show the immersive overlay with thumbnail preloading.
    /// - Important: Must be called on the main thread.
    func show() {
        let t0 = CACurrentMediaTime()
        logDebug("TIMING: [t=0ms] showImmersiveOverlay called")

        let windowList = windowManager.refreshWindows()
        let t1 = CACurrentMediaTime()
        logDebug("TIMING: [t=\(Int((t1 - t0) * 1000))ms] refreshWindows done, \(windowList.count) windows")

        guard !windowList.isEmpty else {
            logDebug("showImmersiveOverlay: no windows found, aborting")
            return
        }

        // Preload only visible windows synchronously, the rest in background
        let visibleCount = min(AppSettings.shared.maxVisibleCount, windowList.count)
        windowManager.preloadThumbnails(count: visibleCount)
        let t2 = CACurrentMediaTime()
        let cachedCount = windowList.prefix(visibleCount).filter { $0.thumbnail != nil }.count
        logDebug("TIMING: [t=\(Int((t2 - t0) * 1000))ms] preload visible done (capture=\(Int((t2 - t1) * 1000))ms, hit=\(cachedCount), miss=\(visibleCount - cachedCount))")

        let orderedIDs = windowManager.orderingEngine.orderedIDs
        let windowsWithThumbnails = windowManager.orderedWindows
        let names = orderedIDs.compactMap { windowManager.windows[$0]?.ownerName }
        logDebug("IMMERSIVE-SHOW: LRU order = \(names.enumerated().map { "[\($0)]\($1)" }.joined(separator: " → "))")
        overlayController.show(with: windowsWithThumbnails)
        let t3 = CACurrentMediaTime()
        logDebug("TIMING: [t=\(Int((t3 - t0) * 1000))ms] overlay shown (UI=\(Int((t3 - t2) * 1000))ms, total=\(Int((t3 - t0) * 1000))ms)")

        // Background: capture remaining windows
        let remaining = windowList.count - visibleCount
        if remaining > 0 {
            logDebug("CAPTURE: background capture starting, remaining=\(remaining), overlay shown at t=\(Int((t3 - t0) * 1000))ms")
            let remainingIDs = Array(orderedIDs.dropFirst(visibleCount))
            var namesSnapshot: [CGWindowID: String] = [:]
            for id in remainingIDs {
                namesSnapshot[id] = windowManager.orderingEngine.windowNames[id] ?? "?"
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let bgStart = CACurrentMediaTime()
                var captured: [(CGWindowID, NSImage)] = []
                for id in remainingIDs {
                    if let image = self.windowManager.captureRawImage(for: id, ownerName: namesSnapshot[id] ?? "?") {
                        captured.append((id, image))
                    }
                }
                let bgTotal = Int((CACurrentMediaTime() - bgStart) * 1000)
                if !captured.isEmpty {
                    DispatchQueue.main.async {
                        for (id, image) in captured {
                            self.windowManager.setThumbnail(image, for: id)
                        }
                        self.overlayController.refreshThumbnails()
                        logDebug("CAPTURE: background capture complete, captured=\(captured.count)/\(remainingIDs.count), dt=\(bgTotal)ms")
                    }
                } else {
                    logDebug("CAPTURE: background capture complete, captured=0/\(remainingIDs.count), dt=\(bgTotal)ms")
                }
            }
        }
    }
}
