import AppKit
import CoreGraphics

/// Thumbnail capture and caching — extracted from WindowManager to keep it
/// focused on window-list lifecycle and ordering.
final class ThumbnailCapturer {
    static let shared = ThumbnailCapturer()

    private var windowManager: WindowManager { WindowManager.shared }

    // MARK: - Raw capture

    /// Stateless raw capture — safe to call from any thread.
    func captureRawImage(for windowID: CGWindowID, ownerName: String = "?") -> NSImage? {
        let t0 = CACurrentMediaTime()
        let cgImageUnmanaged = WindowSwitcher_CaptureWindowImage(windowID)
        let t1 = CACurrentMediaTime()
        guard let cgImage = cgImageUnmanaged?.takeRetainedValue() else {
            logDebug("CAPTURE: FAIL [\(ownerName)] win=\(windowID) dt=\(Int((t1 - t0) * 1000))ms")
            return nil
        }
        logDebug("CAPTURE: OK [\(ownerName)] win=\(windowID) size=\(cgImage.width)x\(cgImage.height) dt=\(Int((t1 - t0) * 1000))ms")
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    // MARK: - Cached capture

    func captureThumbnail(for windowID: CGWindowID) -> NSImage? {
        if let cached = windowManager.windows[windowID]?.thumbnail { return cached }
        guard let image = captureRawImage(for: windowID) else { return nil }
        setThumbnail(image, for: windowID)
        return image
    }

    func preloadThumbnails(count: Int) {
        let t0 = CACurrentMediaTime()
        let ids = Array(windowManager.orderingEngine.orderedIDs.prefix(count))
        var successCount = 0
        for id in ids {
            if captureThumbnail(for: id) != nil {
                successCount += 1
            }
        }
        let dt = Int((CACurrentMediaTime() - t0) * 1000)
        logDebug("CAPTURE: preloadThumbnails count=\(count) ids=\(ids.count) success=\(successCount) dt=\(dt)ms")
    }

    // MARK: - Cache management

    func setThumbnail(_ image: NSImage, for windowID: CGWindowID) {
        windowManager.windows[windowID]?.thumbnail = image
    }

    func clearCache() {
        for key in windowManager.windows.keys {
            windowManager.windows[key]?.thumbnail = nil
        }
    }
}
