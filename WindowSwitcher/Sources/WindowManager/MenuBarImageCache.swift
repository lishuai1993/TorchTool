import CoreGraphics
import Foundation

/// 屏幕顶部菜单栏「刘海左侧横条」真实像素缓存。键为 App pid。
///
/// 设计约束（2026-08-19 定稿）：
/// - 顶部菜单栏是 Window Server 全局窗口，只渲染「当前激活 App」的菜单 → 目标
///   App 未激活时其菜单像素在屏幕上不存在，只能在它激活时采集。
/// - 菜单文字区（刘海左侧）会话内固定；状态栏图标区（刘海右侧）与 App 无关且
///   不可预测 → 只缓存 0 → 最左状态栏图标 x 的横条，不含状态栏图标区。
/// - 每个 App 会话内只采集一次（首次激活时），采集后不再重复。
final class MenuBarImageCache {
    static let shared = MenuBarImageCache()

    private var cache: [pid_t: CGImage] = [:]
    private let lock = NSLock()

    /// internal 供单测创建独立实例；App 内统一用 shared。
    init() {}

    /// 记录某 App 的菜单横条（刘海左侧真实像素）。
    func record(pid: pid_t, strip: CGImage) {
        lock.lock(); defer { lock.unlock() }
        cache[pid] = strip
    }

    /// 返回某 App 的菜单横条缓存；未采集过返回 nil。
    func strip(pid: pid_t) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return cache[pid]
    }

    /// 是否已有缓存（用于「每 App 会话内只采一次」判定）。
    func contains(pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cache[pid] != nil
    }

    /// 从整屏 CGImage 裁剪顶部菜单横条（刘海左侧 coverWidth 像素）。CGImage 坐标
    /// 顶部原点（y=0 为屏幕顶），与 SCK 截屏一致。
    static func cropTopStrip(from fullImage: CGImage,
                             coverWidthPx: Int,
                             menuBarPx: Int) -> CGImage? {
        guard coverWidthPx > 0, menuBarPx > 0 else { return nil }
        let w = min(coverWidthPx, fullImage.width)
        let h = min(menuBarPx, fullImage.height)
        guard w > 0, h > 0 else { return nil }
        return fullImage.cropping(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// 最左状态栏图标的全局 x（CG 顶部原点坐标）。扫描 layer==25、owner 非
    /// Window Server、位于屏幕顶部的窗口，取最小 minX。排除本进程窗口与 x<5
    /// 的异常窗口，防误测 0 导致覆盖条失效。采集端与显示端共用。
    static func leftmostStatusItemX(fallbackScreenWidth: CGFloat) -> CGFloat {
        var minX: CGFloat?
        if let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            for w in list {
                guard let layer = w[kCGWindowLayer as String] as? Int, layer == 25 else { continue }
                let owner = w[kCGWindowOwnerName as String] as? String ?? ""
                if owner == "Window Server" { continue }
                if let pid = w[kCGWindowOwnerPID as String] as? Int,
                   pid == ProcessInfo.processInfo.processIdentifier { continue }
                guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                      let x = b["X"], let y = b["Y"], let height = b["Height"] else { continue }
                guard y < 8, height >= 15, x >= 5 else { continue }
                if minX == nil || x < minX! { minX = x }
            }
        }
        return minX ?? fallbackScreenWidth
    }
}
