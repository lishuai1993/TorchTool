import AppKit
import ScreenCaptureKit

/// 一次滑动方向的计划：仅方向目标。由 SlideResolver 计算，trackingBegan 预捕与
/// begin() 实际计算共用同一份代码，保证两者判别完全一致。
struct SlidePlan {
    let targetID: CGWindowID?
    let reverseID: CGWindowID?
}

/// 滑动过渡方向计划（统一模型：仅目标窗口滑入，背景无排除集）。
/// sign≥0（右滑）→ 目标=leftID、反向=rightID；sign<0（左滑）→ 目标=rightID、反向=leftID。
enum SlideResolver {
    static func plan(sign: Int, leftID: CGWindowID?, rightID: CGWindowID?) -> SlidePlan {
        let targetID = sign >= 0 ? leftID : rightID
        let reverseID = sign >= 0 ? rightID : leftID
        return SlidePlan(targetID: targetID, reverseID: reverseID)
    }
}

/// 三指落地（trackingBegan）时对左右两个滑动方向并行预捕 SCK 背景。
/// begin() 一次性消费命中方向：图已就绪 → 面板弹出即带完整桌面背景（零黑，根治
/// 非全屏源黑闪）；图在途 → 交给异步 backdrop 路径短等；无匹配 → 全新捕获回退。
/// 会话一次消费即清空（take），防旧图被后续手势误用；手势结束时 cancel 兜底。
/// 无 @MainActor 注解：本类仅被主线程调用（AppDelegate / SlideTransitionController 均为
/// 主线程约定），SCK 异步续体用 `Task { @MainActor in }` 保证主线程写回，无数据竞争。
final class BackdropPreCapturer {
    static let shared = BackdropPreCapturer()

    /// 预捕方向结果（类引用：捕获 Task 写回，begin/异步路径轮询读取）。
    final class Direction {
        let sign: Int
        let plan: SlidePlan
        var image: CGImage?
        var excludedCount: Int?
        var done = false
        init(sign: Int, plan: SlidePlan) {
            self.sign = sign
            self.plan = plan
        }
    }

    private struct Session {
        let sourceID: CGWindowID
        let leftID: CGWindowID?
        let rightID: CGWindowID?
        let screenSize: CGSize
        let rightSwipe: Direction   // sign=+1，目标=leftID
        let leftSwipe: Direction    // sign=-1，目标=rightID
    }

    private var session: Session?

    private init() {}

    /// begin() 消费结果。
    enum TakeResult {
        /// 图已就绪：直接平铺（零黑）。
        case ready(CGImage)
        /// 方向计划匹配但在捕获中：交给异步 backdrop 路径短等该 Direction。
        case inflight(Direction)
        /// 无匹配会话 / 方向计划不匹配：全新捕获回退。
        case none
    }

    /// 三指落地：按当前（最近一次 refresh 的）LRU 快照计算左右两方向计划并并行捕获。
    /// sourceID/leftID/rightID 由 WindowManager.beginBackdropPreCapture 提供。
    func start(sourceID: CGWindowID, leftID: CGWindowID?, rightID: CGWindowID?, screenSize: CGSize) {
        let right = Direction(sign: 1, plan: SlideResolver.plan(sign: 1, leftID: leftID, rightID: rightID))
        let left = Direction(sign: -1, plan: SlideResolver.plan(sign: -1, leftID: leftID, rightID: rightID))
        session = Session(sourceID: sourceID, leftID: leftID, rightID: rightID,
                          screenSize: screenSize, rightSwipe: right, leftSwipe: left)
        logDebug("SLIDE: pre-capture start source=\(sourceID) left=\(leftID.map(String.init) ?? "nil") right=\(rightID.map(String.init) ?? "nil")")
        // 源窗口阴影完全移除：背景预捕同时排除源窗口（背景不自带其真实投影）。
        // 源截取关闭时源区域无 sourceView 兜底，保留源在背景中，避免露出背后桌面。
        let excl: Set<CGWindowID> = AppSettings.shared.sourceShadowCleanEnabled
            && AppSettings.shared.sourceCaptureEnabled ? [sourceID] : []
        Task { @MainActor in await Self.capture(into: right, screenSize: screenSize, excluding: excl) }
        Task { @MainActor in await Self.capture(into: left, screenSize: screenSize, excluding: excl) }
    }

    /// 预捕会话是否可用于当前 begin 的判定（纯函数，可单测）。
    /// 方案B2：只校验屏幕尺寸——预捕背景图是「桌面减本进程窗口」，与源/左右邻身份无关；
    /// 快速连续手势里「提交→激活」间隙的预捕源过期、以及两次刷新间 LRU 邻序漂移，都不
    /// 应让 begin 放弃已就绪的背景。失配仍采用预捕图（略旧但可用），避免全新捕获回退的
    /// 不透明黑占位闪屏。仅源窗口换屏才需重捕（屏幕尺寸变化）。
    static func sessionUsable(sessionScreen: CGSize, beginScreen: CGSize) -> Bool {
        sessionScreen == beginScreen
    }

    /// begin() 一次性消费：取命中方向的结果并清空会话（无论结果如何，本会话不再复用）。
    /// 仅屏幕尺寸不匹配（源已换屏）→ .none，begin 走全新捕获。
    func take(sourceID: CGWindowID, leftID: CGWindowID?, rightID: CGWindowID?,
              screenSize: CGSize, sign: Int) -> TakeResult {
        guard let session, Self.sessionUsable(sessionScreen: session.screenSize, beginScreen: screenSize) else { return .none }
        let dir = sign >= 0 ? session.rightSwipe : session.leftSwipe
        self.session = nil  // 消费即清空，防旧图被后续手势误用
        if let image = dir.image { return .ready(image) }
        return .inflight(dir)
    }

    /// 等待在途预捕 Direction 完成（短轮询，deadline 内）。成功返回图，超时返回 nil。
    /// 由 captureBackdrop 在 take() 返回 .inflight 时调用。
    func awaitImage(_ direction: Direction, timeout: TimeInterval) async -> CGImage? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !direction.done && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return direction.image
    }

    /// 手势结束 / 打断时清理未消费的预捕会话（已消费的会话早已被 take 清空）。
    func cancel() {
        session = nil
    }

    /// 单方向 SCK 捕获。统一模型背景默认无窗口排除集（接受目标滑入时与背景真实位重影）；
    /// windowIDs 携带菜单覆盖条等本进程面板窗口号，以及干净模式（源窗口阴影完全移除）
    /// 下待排除的源窗口；panelWindowNumber 为该会话全屏面板窗口号（全新捕获路径传入）。
    ///
    /// 排除规则：始终排除本进程自己的窗口（全屏滑动面板 + 菜单覆盖条）。预捕路径
    /// （panelWindowNumber=nil）此前不排除任何本进程窗口，但预捕异步执行可能滞后到
    /// begin() 建面板之后——本次实测：预捕 24.715 发起、24.813 执行，begin 24.748 建面板
    /// 落在其中，SCK 把「半透明黑占位罩在真实桌面 + 面板内源/目标图像」自拍进背景图，
    /// 造成暗层屏闪。真实源/目标窗口均为其他进程，不受排除影响。
    static func captureDesktop(size: CGSize, excluding windowIDs: Set<CGWindowID>,
                               panelWindowNumber: Int?) async throws -> (image: CGImage, excluded: [SCWindow]) {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: {
            Int($0.width) == Int(size.width) && Int($0.height) == Int(size.height)
        }) ?? content.displays.first else {
            throw NSError(domain: "SlideBackdrop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no matching display"])
        }
        let ourPid = ProcessInfo.processInfo.processIdentifier
        let excluded: [SCWindow] = content.windows.filter {
            Self.shouldExcludeWindow(
                WindowRef(windowID: $0.windowID, ownerPid: $0.owningApplication?.processID),
                windowIDs: windowIDs, panelWindowNumber: panelWindowNumber, ourPid: ourPid)
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        config.width = Int(size.width * scale)
        config.height = Int(size.height * scale)
        config.showsCursor = false
        config.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, excluded)
    }

    // MARK: - 排除判定（纯函数，可单测）

    /// 背景截屏排除判定的最小窗口信息（SCWindow 不可直接构造、无法在单测中实例化，
    /// 用等价值类型承载判定所需的窗口 ID 与进程）。
    struct WindowRef {
        let windowID: CGWindowID
        let ownerPid: pid_t?
    }

    /// 窗口是否应从背景截屏排除。
    /// 排除：① 调用方显式指定的 windowIDs；② panelWindowNumber 对应窗口；
    /// ③ 本进程 PID 的所有窗口（全屏面板、菜单覆盖条——任何时刻都不该入背景图，
    /// 含预捕路径：异步执行可能晚于 begin 建面板，必须排除否则自拍成暗层屏闪）。
    static func shouldExcludeWindow(_ ref: WindowRef, windowIDs: Set<CGWindowID>,
                                    panelWindowNumber: Int?, ourPid: pid_t) -> Bool {
        if windowIDs.contains(ref.windowID) { return true }
        if let pn = panelWindowNumber, ref.windowID == CGWindowID(pn) { return true }
        if let pid = ref.ownerPid, pid == ourPid { return true }
        return false
    }

    // MARK: - Private

    private static func capture(into direction: Direction, screenSize: CGSize,
                                excluding: Set<CGWindowID>) async {
        do {
            let result = try await captureDesktop(size: screenSize,
                                                  excluding: excluding,
                                                  panelWindowNumber: nil)
            direction.image = result.image
            direction.excludedCount = result.excluded.count
            direction.done = true
            logDebug("SLIDE: pre-capture done dir=\(direction.sign > 0 ? "right" : "left") "
                     + "\(result.image.width)x\(result.image.height)px")
        } catch {
            direction.done = true
            logDebug("SLIDE: pre-capture failed dir=\(direction.sign > 0 ? "right" : "left") — \(error.localizedDescription)")
        }
    }
}
