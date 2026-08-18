import Foundation

/// The current gesture/interaction phase of the window switcher.
/// Encodes which interaction is in progress and which events may be
/// intercepted. AppDelegate drives transitions; WindowManager reads.
enum GesturePhase {
    case idle
    case quickSwitching   // 三指横滑快捷切换进行中
    case elasticDragging  // 非循环模式边界碰壁的弹性拖拽进行中
    case overlayVisible   // 沉浸覆盖层开启
    case slidingTransition // 三指横滑「跟随手指」滑动过渡进行中

    /// Whether a scroll event should be treated as a gesture artifact
    /// (thus NOT trigger LRU window reorder).
    var interceptsScroll: Bool {
        switch self {
        case .quickSwitching, .elasticDragging, .slidingTransition: return true
        case .idle, .overlayVisible: return false
        }
    }
}
