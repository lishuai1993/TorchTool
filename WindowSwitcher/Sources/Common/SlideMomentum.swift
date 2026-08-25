import CoreGraphics

/// 路径A动量助推（纯函数，可单测）。
/// - off: 抬手时位移（px，右滑为负）。路径A 不参与方向判定——方向保护用会话主方向
///   而非 off 方向，避免快甩起步 off≈0 符号不稳误杀；保留该参数便于将来路径B扩展。
/// - releaseVel: 抬手前即时速度（px/s，带符号，已过 800px/s 下限拦截）
/// - mainDirSign: 会话主方向符号（+1 / −1 / 0），取自会话峰值速度符号
/// - window: 动量外推时间窗口（秒）
/// - maxBoostPx: 最大助推（px）
/// 仅当 releaseVel 与主方向同向时给助推，否则 0（停顿零速/反向回退 → 助推归零，
/// 回归纯位移判定）；结果 clamp 到 ±maxBoostPx。
func momentumBoost(off: CGFloat, releaseVel: CGFloat, mainDirSign: Int,
                   window: CGFloat, maxBoostPx: CGFloat) -> CGFloat {
    guard releaseVel != 0, mainDirSign != 0,
          releaseVel * CGFloat(mainDirSign) > 0 else { return 0 }
    let boost = releaseVel * window
    return max(-maxBoostPx, min(maxBoostPx, boost))
}
