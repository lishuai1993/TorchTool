import Foundation
import CoreGraphics

/// 链式会话（连甩连贯）纯函数决策与偏移，可单测。
///
/// 极快同向连续快甩时，旧会话的 settle/fade 可被打断、面板复用，仅最后一下完整
/// 落定。本模块封装两个纯逻辑：① 新 swipeUpdate 到达时的会话派发决策；② 链式
/// 进位偏移（位置继承）。实机路径在 AppDelegate / SlideTransitionController。
enum SlideChain {
    /// 会话派发动作。
    enum Action: Equatable {
        /// 全新会话（无活动会话）。
        case freshBegin
        /// 同一手势继续跟手（会话跟随中，非收尾）。
        case update
        /// 同方向链式接续（会话收尾中，可打断复用面板）。
        case chain
        /// 反向打断：取消旧会话，回落全新 begin。
        case cancelAndFresh
    }

    /// 依据会话状态与方向决定动作。
    /// - Parameters:
    ///   - isActive: 会话是否存活。
    ///   - isSettling: 会话是否处于收尾（settle/fade）而非跟手。
    ///   - settleComplete: 收尾是否已走完「目标已激活/fade」阶段（方案C：fade 期不
    ///     链式——旧背景已失效，重开会话从新前置目标继续，替代静默跳过）。
    ///   - newSign: 新手势方向（progress≥0 → 1，否则 -1）。
    ///   - lastSettleSign: 最近一次 settle 的推进方向（finalOffset<0 → -1）。
    static func decision(isActive: Bool, isSettling: Bool, settleComplete: Bool,
                         newSign: CGFloat, lastSettleSign: CGFloat) -> Action {
        guard isActive else { return .freshBegin }
        if !isSettling { return .update }
        if settleComplete { return .cancelAndFresh }
        return newSign == lastSettleSign ? .chain : .cancelAndFresh
    }

    /// 新手势方向符号：progress≥0 → 1，否则 -1。0 视为正方向（首帧无位移，方向
    /// 将由后续 swipeUpdate 修正；链式判定仅在 isSettling 且 direction 明确时有效）。
    static func sign(ofProgress progress: CGFloat) -> CGFloat {
        progress >= 0 ? 1 : -1
    }

    /// 链式进位偏移（位置继承）：currentOffset = carry + eased(progress)。
    /// carry=0 退化为普通 eased 映射。不在此 clamp（停靠钳制与 commit 判定在控制器）。
    static func chainedOffset(progress: CGFloat, carry: CGFloat,
                              pointsPerProgress: CGFloat, screenWidth: CGFloat) -> CGFloat {
        SlideOffset.chained(progress: progress, carry: carry,
                            pointsPerProgress: pointsPerProgress, screenWidth: screenWidth)
    }
}
