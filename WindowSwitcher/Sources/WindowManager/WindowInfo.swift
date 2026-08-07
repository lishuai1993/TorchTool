import AppKit

struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let ownerPid: pid_t
    let ownerName: String      // app bundle name or process name
    let ownerBundleID: String?
    let windowTitle: String
    let frame: CGRect          // window frame in screen coordinates

    /// Returns a copy with a different window title (used to backfill AX titles).
    func withTitle(_ newTitle: String) -> WindowInfo {
        WindowInfo(
            id: id,
            ownerPid: ownerPid,
            ownerName: ownerName,
            ownerBundleID: ownerBundleID,
            windowTitle: newTitle,
            frame: frame
        )
    }

    // Thumbnail loaded on demand
    var thumbnail: NSImage?

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id && lhs.thumbnail === rhs.thumbnail
    }
}
