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

    /// 链式会话 offset（像素）：从进位偏移 carry 起算，再叠加 eased(progress)。
    /// carry=0 时退化为普通 eased 映射（行为与现状一致）；carry≠0 时新目标从被打断
    /// 位置**继续**滑动（运动位置不回跳，仅内容切换到新目标）。不在此 clamp——
    /// 停靠钳制由 applyCurrentOffset 负责，commit 判定用完整 carry+travel。
    static func chained(progress: CGFloat, carry: CGFloat,
                        pointsPerProgress: CGFloat, screenWidth: CGFloat) -> CGFloat {
        eased(progress: progress, pointsPerProgress: pointsPerProgress, screenWidth: screenWidth) + carry
    }
}
