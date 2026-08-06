import SwiftUI

final class OverlayViewModel: ObservableObject {
    @Published var windows: [WindowInfo] = []
    @Published var focusedIndex: Int = 0
    @Published var hoveredIndex: Int? = nil

    var displayIndex: Int { hoveredIndex ?? focusedIndex }

    var isEmpty: Bool { windows.isEmpty }

    func show(windows: [WindowInfo]) {
        self.windows = windows
        self.focusedIndex = 0
        self.hoveredIndex = nil
    }

    func hide() {
        windows = []
        focusedIndex = 0
        hoveredIndex = nil
    }

    @discardableResult
    func moveFocusRight() -> Bool {
        guard !windows.isEmpty else { return false }
        let cyclic = AppSettings.shared.cyclicScrollEnabled
        let newIndex = focusedIndex + 1
        if newIndex >= windows.count {
            if cyclic {
                focusedIndex = 0
                return true
            } else {
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
                return true
            } else {
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
