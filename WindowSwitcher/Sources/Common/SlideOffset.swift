import Foundation
import CoreGraphics

/// 滑动过渡 offset 映射（纯函数，可单测）。
///
/// offset = eased(p) × pointsPerProgress，软起步曲线 eased(p) = p·|p|/(|p|+knee)：
/// p=0 处斜率为 0（起步平滑无弹射），p 增大后趋近线性。
/// 供 SlideTransitionController 与单元测试共用，保证「滑动全程连续、无瞬移」。
enum SlideOffset {
    /// 软起步膝点。
    static let softStartKnee: CGFloat = 0.4

    /// progress → offset（像素），clamp 在 ±screenWidth。
    static func eased(progress: CGFloat, pointsPerProgress: CGFloat, screenWidth: CGFloat) -> CGFloat {
        let p = progress
        let eased = p * abs(p) / (abs(p) + softStartKnee)
        let offset = eased * pointsPerProgress
        return min(max(offset, -screenWidth), screenWidth)
    }
}
