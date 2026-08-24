import AppKit
import CoreGraphics

/// 方案一：三指落地（trackingBegan）时把滑动面板需要的窗口图像（源 + 左右邻）在
/// 后台并行预取并缓存，begin() 一次性消费命中即免同步截屏——把源/目标窗口截屏从
/// begin() 关键路径上移出（原同步截屏阻塞主线程约 30ms，期间 swipeUpdate 积压成
/// 批量补放跳变），压缩「全新会话约 160ms 死区」中的截屏部分。
///
/// 会话模型对齐 BackdropPreCapturer：start 发起、begin 一次性消费（take 即清空）、
/// 手势结束 cancel 兜底。方向未知故左右邻都预取，begin 按 sign 决定目标（左/右）。
/// 窗口重建/换屏导致 begin 参数与预捕会话失配时 take 返回 nil，begin 回退同步截屏，
/// 保证正确性不回退。
///
/// 截屏函数与窗口帧通过闭包注入，本类不依赖 WindowManager，可单测纯判定。
final class WindowImagePreCapturer {
    static let shared = WindowImagePreCapturer()

    /// 单个窗口预取结果：图像 + 捕获时刻的 CG 帧（begin 校验尺寸，防窗口在预取后
    /// 改尺寸导致图像被拉伸）。
    struct Entry {
        let image: NSImage
        let frame: CGRect
    }

    /// begin 消费结果：源 + 左右邻（方向未定，左右都取）。
    struct PreCaptured {
        let source: Entry?
        let left: Entry?
        let right: Entry?
    }

    private struct Session {
        let sourceID: CGWindowID
        let leftID: CGWindowID?
        let rightID: CGWindowID?
        var source: Entry?
        var left: Entry?
        var right: Entry?
    }

    private var session: Session?
    private let queue = DispatchQueue(label: "ws.windowImagePreCapture", attributes: .concurrent)

    private init() {}

    // MARK: - 纯判定（可单测）

    /// 预捕会话参数与 begin 参数一致才消费（防窗口列表在预取后变化，误用旧图）。
    static func sessionMatches(sessionSource: CGWindowID, sessionLeft: CGWindowID?, sessionRight: CGWindowID?,
                               sourceID: CGWindowID, leftID: CGWindowID?, rightID: CGWindowID?) -> Bool {
        sessionSource == sourceID && sessionLeft == leftID && sessionRight == rightID
    }

    /// 预取图的捕获帧与当前帧尺寸吻合才采用（防窗口在预取后改尺寸导致图像拉伸）。
    static func frameMatches(entryFrame: CGRect, frame: CGRect) -> Bool {
        abs(entryFrame.width - frame.width) < 1 && abs(entryFrame.height - frame.height) < 1
    }

    // MARK: - 会话生命周期

    /// trackingBegan：按最近一次 refresh 的窗口快照并行预取源 + 左右邻。
    /// - Parameters:
    ///   - capture: 单窗口截屏（后台并发队列调用，须线程安全）。
    ///   - frames: 窗口 CG 帧（捕获时刻快照，供 begin 尺寸校验）。
    func start(sourceID: CGWindowID, leftID: CGWindowID?, rightID: CGWindowID?,
               capture: @escaping (CGWindowID) -> NSImage?,
               frames: @escaping (CGWindowID) -> CGRect) {
        session = Session(sourceID: sourceID, leftID: leftID, rightID: rightID)
        captureAsync(sourceID, frame: frames(sourceID), capture: capture) { $0.source = $1 }
        if let leftID {
            captureAsync(leftID, frame: frames(leftID), capture: capture) { $0.left = $1 }
        }
        if let rightID {
            captureAsync(rightID, frame: frames(rightID), capture: capture) { $0.right = $1 }
        }
    }

    /// begin() 一次性消费：会话失配返回 nil（begin 回退同步截屏）。消费即清空，
    /// 防旧图被后续手势误用。
    func take(sourceID: CGWindowID, leftID: CGWindowID?, rightID: CGWindowID?) -> PreCaptured? {
        guard let s = session,
              Self.sessionMatches(sessionSource: s.sourceID, sessionLeft: s.leftID, sessionRight: s.rightID,
                                  sourceID: sourceID, leftID: leftID, rightID: rightID) else {
            return nil
        }
        session = nil
        return PreCaptured(source: s.source, left: s.left, right: s.right)
    }

    /// 手势结束 / 打断 / 服务停止时清理未消费会话。
    func cancel() {
        session = nil
    }

    // MARK: - Private

    private func captureAsync(_ id: CGWindowID, frame: CGRect,
                              capture: @escaping (CGWindowID) -> NSImage?,
                              assign: @escaping (inout Session, Entry) -> Void) {
        queue.async { [weak self] in
            guard let image = capture(id) else { return }
            let entry = Entry(image: image, frame: frame)
            DispatchQueue.main.async {
                guard var s = self?.session else { return }
                assign(&s, entry)
                self?.session = s
            }
        }
    }
}
