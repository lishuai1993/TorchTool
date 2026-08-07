import SwiftUI

final class OverlayViewModel: ObservableObject {
    @Published var windows: [WindowInfo] = []
    @Published var focusedIndex: Int = 0
    @Published var hoveredIndex: Int? = nil

    /// Card global frames keyed by index, updated via GeometryReader.
    /// Used by the mouse-move monitor for full-screen hover detection.
    var cardFrames: [Int: CGRect] = [:]

    /// Weak ref to backing NSScrollView for forwarding scrollWheel events.
    weak var scrollView: NSScrollView?

    var displayIndex: Int { hoveredIndex ?? focusedIndex }

    var isEmpty: Bool { windows.isEmpty }

    func show(windows: [WindowInfo]) {
        self.windows = windows
        self.focusedIndex = 0
        self.hoveredIndex = nil
        self.cardFrames = [:]
    }

    func hide() {
        windows = []
        focusedIndex = 0
        hoveredIndex = nil
        cardFrames = [:]
    }

    /// Called from onHover when a card scrolls under the cursor.
    func notifyScrollHover(at index: Int) {
        hoveredIndex = index
    }

    @discardableResult
    func moveFocusRight() -> Bool {
        guard !windows.isEmpty else { return false }
        let cyclic = AppSettings.shared.cyclicScrollEnabled
        let newIndex = focusedIndex + 1
        if newIndex >= windows.count {
            if cyclic {
                focusedIndex = 0
                logDebug("FOCUS-VM: moveRight cyclic wrap → 0")
                return true
            } else {
                logDebug("FOCUS-VM: moveRight boundary hit at \(focusedIndex)")
                return false
            }
        }
        focusedIndex = newIndex
        return true
    }

    @discardableResult
    func moveFocusLeft() -> Bool {
        guard !windows.isEmpty else { return false }
        let cyclic = AppSettings.shared.cyclicScrollEnabled
        let newIndex = focusedIndex - 1
        if newIndex < 0 {
            if cyclic {
                focusedIndex = windows.count - 1
                logDebug("FOCUS-VM: moveLeft cyclic wrap → \(windows.count - 1)")
                return true
            } else {
                logDebug("FOCUS-VM: moveLeft boundary hit at 0")
                return false
            }
        }
        focusedIndex = newIndex
        return true
    }

    func selectFocused() -> WindowInfo? {
        let idx = displayIndex
        guard idx >= 0, idx < windows.count else { return nil }
        return windows[idx]
    }
}
