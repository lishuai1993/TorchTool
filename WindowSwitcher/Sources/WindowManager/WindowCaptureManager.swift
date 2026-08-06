import ScreenCaptureKit
import CoreGraphics

final class WindowCaptureManager {
    static let shared = WindowCaptureManager()

    private var cachedContent: SCShareableContent?
    private var contentAccessFailed = false

    private init() {}

    func getShareableContent() async -> SCShareableContent? {
        if let cached = cachedContent { return cached }
        if contentAccessFailed { return nil }
        do {
            let content = try await SCShareableContent.current
            cachedContent = content
            contentAccessFailed = false
            return content
        } catch {
            logDebug("WindowCaptureManager: SCShareableContent.current failed: \(error.localizedDescription)")
            contentAccessFailed = true
            return nil
        }
    }

    func invalidateContentCache() {
        cachedContent = nil
        contentAccessFailed = false
    }

    func captureImage(windowID: CGWindowID, shareableContent: SCShareableContent) async -> CGImage? {
        guard let scWindow = shareableContent.windows.first(where: { $0.windowID == windowID }) else {
            logDebug("WindowCaptureManager: windowID \(windowID) not found in SCShareableContent")
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.width = Int(scWindow.frame.width)
        config.height = Int(scWindow.frame.height)
        config.showsCursor = false
        config.capturesAudio = false

        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            logDebug("WindowCaptureManager: captureImage failed for win=\(windowID): \(error.localizedDescription)")
            return nil
        }
    }
}
