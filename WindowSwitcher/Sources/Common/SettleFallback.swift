import CoreGraphics

/// 淡出停滞兜底的动作决策（纯函数，可单测）。
enum SettleFallbackAction {
    /// 面板已拆除，无需处理。
    case noPanel
    /// 面板仍可见（淡出停滞或未完成）：先补短淡出再拆除，避免不透明面板瞬间消失的黑闪。
    case refadeThenTeardown
    /// 面板已透明但未拆除：直接拆除。
    case teardownNow
}

enum SettleFallback {
    /// 依据面板存在性与当前透明度选择兜底动作。
    /// - 面板已拆（nil）→ noPanel；
    /// - 透明度 > 0.05（仍可见）→ refadeThenTeardown；
    /// - 透明度 ≤ 0.05（不可见）→ teardownNow。
    static func action(panelExists: Bool, panelAlpha: CGFloat) -> SettleFallbackAction {
        guard panelExists else { return .noPanel }
        return panelAlpha > 0.05 ? .refadeThenTeardown : .teardownNow
    }
}
