import AppKit
import CoreGraphics

/// 滑动过渡几何纯函数（共享、可单测）。统一模型下不再做 buried/reveal 模式判别
///（第 15 轮移除：仅目标窗口滑入、源/遮挡者/反向邻居全部静态留背景），仅保留
/// 屏幕归属计算供预捕使用。
enum SlideGeometry {
    /// 源窗口 CG bounds（左上原点）中心点所在屏幕；找不到匹配时回退主屏。
    /// CG 的 y 原点为主显示器顶部，与 NS（左下原点）相反，需先换算中心点。
    static func screen(containingCGFrame frame: CGRect, screens: [NSScreen]) -> NSScreen? {
        let primaryTop = screens.first?.frame.maxY ?? 0
        let mid = NSPoint(x: frame.midX, y: primaryTop - frame.midY)
        return screens.first(where: {
            $0.frame.insetBy(dx: -40, dy: -40).contains(mid)
        }) ?? screens.first
    }
}
