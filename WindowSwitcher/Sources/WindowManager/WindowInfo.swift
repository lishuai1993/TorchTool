import AppKit

struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let windowNumber: Int
    let ownerPid: pid_t
    let ownerName: String      // app bundle name or process name
    let ownerBundleID: String?
    let windowTitle: String
    let frame: CGRect          // window frame in screen coordinates
    let isOnScreen: Bool
    let windowLayer: Int

    // Computed
    var idKey: CGWindowID { id }

    // Thumbnail loaded on demand
    var thumbnail: NSImage?

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id
    }
}
