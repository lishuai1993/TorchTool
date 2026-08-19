import AppKit
import CoreGraphics

/// 滑动过渡渲染模式（与统一模型一致）：目标被完全覆盖 → buried（目标图像从对侧
/// 滑入、源 staticSource）；目标部分可见 → reveal（源 + 遮挡者滑出、目标留背景）。
/// 原 SlideTransitionController 私有枚举，提升为共享供预捕方向计划与控制器共用。
enum SlideMode: String {
    case staticSource
    case reveal
}

/// 滑动过渡几何纯函数（共享、可单测）。SlideTransitionController 与
/// BackdropPreCapturer（预捕方向计划）共用，保证两边判别完全一致。
enum SlideGeometry {
    /// 矩形减法：从 target 中逐步挖去 windows（前→后）的覆盖区域，返回剩余
    /// （露出）区域列表。几何运算与坐标系原点无关，CG/NS 坐标皆可。
    static func exposedRegions(_ target: CGRect, subtracting windows: [CGRect]) -> [CGRect] {
        var remaining = [target]
        for w in windows {
            var next: [CGRect] = []
            for r in remaining {
                let inter = r.intersection(w)
                if inter.isNull || inter.isEmpty { next.append(r); continue }
                if inter.minX > r.minX {
                    next.append(CGRect(x: r.minX, y: r.minY, width: inter.minX - r.minX, height: r.height))
                }
                if inter.maxX < r.maxX {
                    next.append(CGRect(x: inter.maxX, y: r.minY, width: r.maxX - inter.maxX, height: r.height))
                }
                if inter.minY > r.minY {
                    next.append(CGRect(x: inter.minX, y: r.minY, width: inter.width, height: inter.minY - r.minY))
                }
                if inter.maxY < r.maxY {
                    next.append(CGRect(x: inter.minX, y: inter.maxY, width: inter.width, height: r.maxY - inter.maxY))
                }
            }
            remaining = next
            if remaining.isEmpty { return [] }
        }
        return remaining
    }

    /// 「有效覆盖」测试：windows 是否盖住 target 的全部有效区域。露出区域需
    /// 宽、高两个维度均 ≥ minExposedSide 才算「部分可见」（→ reveal）；菜栏条、
    /// 屏外细缝、亚像素缝隙等微小露出视为被覆盖（→ buried）。
    static func isEffectivelyCovered(_ target: CGRect, by windows: [CGRect],
                                     minExposedSide: CGFloat = 60) -> Bool {
        let exposed = exposedRegions(target, subtracting: windows)
        if exposed.isEmpty { return true }
        let meaningful = exposed.contains { $0.width >= minExposedSide && $0.height >= minExposedSide }
        return !meaningful
    }

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
