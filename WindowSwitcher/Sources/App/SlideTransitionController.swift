import AppKit
import ScreenCaptureKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// 三指横滑「跟随手指」滑动过渡切换。
///
/// 统一模型：仅目标窗口图像从屏幕边缘滑入真实位，源、遮挡者、反向邻居全部静态留
/// 背景。目标窗口保持真实尺寸与纵向位置，横向按 offset 平移：
///   offset = progress × pointsPerProgress，pointsPerProgress = ratio × swipeMinDisplacement × 屏宽
///   target.x = −width + offset（右滑，前缘贴屏幕左缘）/ 屏宽 + offset（左滑，前缘贴右缘）
/// 边缘锚点保证手指一动即露边、从第一像素跟手（消除小窗口「先滑屏外、后冒出」的
/// 不可见预行程）；到达真实位后停住（右滑 min / 左滑 max 钳制），折返自动松开反向
/// 滑出。边界（目标侧无窗口）时源随手指按弹性公式 wall-bump，释放回弹。
///
/// 背景层（方案 B）用 ScreenCaptureKit 截取整屏桌面（无窗口排除集，接受目标滑入
/// 时与背景真实位重影；仅排除本面板与菜单覆盖条），不再使用半透明黑压层。
final class SlideTransitionController {
    static let shared = SlideTransitionController()

    /// 释放后的收尾动画时长（秒）。
    private let settleDuration: TimeInterval = 0.30

    private(set) var isActive = false
    /// 当前横向位移（像素，右为正，clamp 在 ±屏宽）。供释放判定使用。
    private(set) var currentOffset: CGFloat = 0
    /// 链式会话进位偏移：打断时继承的位移（新会话 currentOffset 从 carry 起算）。
    private(set) var carryOffset: CGFloat = 0
    /// 是否处于收尾动画（settle/fade）而非跟手：链式打断与三态派发的判定依据。
    private(set) var isSettling = false
    /// 最近一次 settle 的推进方向符号（finalOffset<0 → -1）。链式同向判定依据。
    private(set) var lastSettleSign: CGFloat = 1
    /// settle 已走完「目标已激活/fade」阶段：链式只能在激活前打断收尾动画；激活后
    /// 复用 stale 背景图会制造双重影像，应交给全新会话。finishSettle 置位、begin/chain 复位。
    private(set) var settleComplete = false
    /// 已 commit 但尚未执行窗口激活的目标（受 settle 300ms 与 token 保护）。链式接续时
    /// 由新 commit 覆盖（中间步按设计不激活）；会话被非链式方式结束（tap/纵向手势/
    /// 边界丢弃）时，cancel 补激活它，杜绝「滑了没切」与光标/真实前置不一致。
    private(set) var pendingActivationTarget: CGWindowID?
    /// 会话非链式结束时补激活 pending 目标的回调（AppDelegate 注入 activateWindow）。
    var onFlushPending: ((CGWindowID) -> Void)?
    /// 边界（目标侧无窗口）：无目标视图，源随手指按弹性公式 wall-bump，释放回弹。
    private var boundary = false
    /// 源窗口所在屏幕宽度（点）。
    var screenWidth: CGFloat { screenRect.width }

    private var panel: NSPanel?
    private var backdrop: NSView?
    /// 背景图像视图（像素诊断：采样其 presentation 透明度验证淡入是否真的渐变）。
    private var backdropImageView: NSImageView?
    /// 跟手期暂缓平铺的全屏背景图：滑动中到达的背景图先存入此槽，finishSettle 收尾
    /// 落图，避免 2940×1912 大图纹理上传阻塞主线程丢跟手帧。teardown 时清除。
    private var pendingBackdrop: CGImage?
    /// 当前面板窗口号（像素诊断：采样面板合成输出；teardown 置 0）。
    private var panelWindowNumber: CGWindowID = 0
    private var sourceView: NSImageView?
    /// 除源窗口外的滑动视图：统一模型下仅目标图像（前缘贴屏幕边缘锚定滑入），
    /// 按 offset 平移、到达真实位即停。
    private struct SlidingImage {
        let view: NSImageView
        let baseX: CGFloat
        let realFrame: NSRect
    }
    private var extraSlideViews: [SlidingImage] = []

    /// 屏幕顶部菜单栏覆盖条面板（level 25，37pt 高，全宽）。内部三层：材质模糊
    /// 背景（始终不透明，遮住真实源菜单）+ 源/目标菜单文字区（真实像素截图，
    /// alpha 随手指交叉淡化）。仅盖菜单文本区（0→最左状态栏图标 x），状态栏
    /// 图标区透明、全程可见。commit 后整个 panel 淡出，露出切换后的真实目标菜单。
    private var menuCoverPanel: NSPanel?
    /// 材质背景：SCK 截取的源菜单栏区域经高斯模糊（抹掉文字），替代「纯色块」。
    private var menuBackgroundView: NSImageView?
    /// 源/目标菜单文字区（真实像素）。源=整屏背景图裁剪的清晰源菜单截图，随手指
    /// 渐隐；目标=缓存的目标菜单截图（会话内该 App 激活过即有，无缓存则空层、
    /// commit 瞬显），随手指渐显。
    private var sourceMenuImageView: NSImageView?
    private var targetMenuImageView: NSImageView?

    /// 源窗口在面板本地坐标系中 offset=0 时的基准 frame。
    private var sourceBase: NSRect = .zero
    /// 会话源窗口 ID（干净模式下从背景截屏排除源窗口，去掉其真实投影）。
    private var slideSourceID: CGWindowID = 0

    private var screenRect: NSRect = .zero
    private var pointsPerProgress: CGFloat = 1

    /// 会话代币：begin 时自增，动画/截屏完成回调仅在 token 匹配时才生效，
    /// 防止旧会话的延迟回调污染新会话。
    private var sessionToken = 0
    /// 淡出停滞兜底是否已接管拆除：置位后正常淡出 completionHandler 放弃拆除，
    /// 避免与兜底的手动淡出竞争。在 teardownPanel 中复位（随会话切换重置）。
    private var settleFallbackEngaged = false

    /// 异步窗口图像回填队列：并发执行后台截取，主线程只做回填赋值。
    private let windowFillQueue = DispatchQueue(label: "ws.windowFill", attributes: .concurrent)

    // MARK: - 甩动动量：速度采样

    /// 采样点（offset 域）。缓冲保留最近 50ms，速度取末 4 点最小二乘斜率。
    private struct OffsetSample {
        let time: CFTimeInterval
        let offset: Double
    }
    private var offsetSamples: [OffsetSample] = []
    /// 采样开关：begin 置 true，settle 起置 false（收尾动画阶段不再追加）。
    private var samplingEnabled = true

    /// 会话峰值横向速度（progress/sec，带符号）。由 C 引擎按 MT 帧时间戳计算、
    /// gestureEnd 前一刻经 GestureSwipePeakVelocity 送达（方案A 动量助推），
    /// 规避主线程批处理/折返反号/抬手停顿导致的释放速度失真。
    private(set) var lastPeakVelocity: CGFloat = 0

    // MARK: - 屏闪诊断旁路开关

    /// 旁路全部屏闪诊断代码（REVEAL-FRAME /tmp/reveal 存图、REVEAL-DIAG、
    /// SLIDE:DIAG 亮度采样）：置 true 时各诊断函数立即返回，避免全屏截图/PNG
    /// 编码/弃用捕获 API 挤占窗口切换期间资源。恢复诊断：改为 false 即可。
    private let diagBypassed = true

    // MARK: - BGFLASH 诊断状态（仅日志，不影响行为）

    /// 会话诊断快照：begin 时记录，teardownPanel **不清除**（供目标激活后的
    /// CONFIRM 重算使用），由下一次 begin 覆盖。
    private var bgDiag = BGDiagnostics()
    /// 最后一次 settle 的提交方向（finalOffset<0 → 右滑），供激活后 CONFIRM 重算。
    private var bgLastCommitDirRight = false

    private struct BGDiagnostics {
        var sourceID: CGWindowID = 0
        var leftID: CGWindowID?
        var rightID: CGWindowID?
        var sourceName = ""
        var leftName = ""
        var rightName = ""
        /// 三窗口真实 frame（面板本地坐标）。
        var sourceReal: NSRect = .zero
        var leftReal: NSRect = .zero
        var rightReal: NSRect = .zero
        var targetName = ""
        var reverseName = ""
    }

    private init() {}

    // MARK: - Session

    /// 开始滑动过渡会话。sourceID 为当前窗口，leftID/rightID 为其 LRU 左右邻
    /// （可为 nil，表示该侧无窗口，如非循环模式的边界）。initialProgress 在面板
    /// 淡入前应用，避免「淡入后从 0 瞬移到首帧位移」的弹射。
    func begin(sourceID: CGWindowID, leftID: CGWindowID?, rightID: CGWindowID?, initialProgress: CGFloat) {
        sessionToken += 1
        teardownPanel()

        let wm = WindowManager.shared
        guard let sourceInfo = wm.windows[sourceID] else {
            logDebug("SLIDE: abort — source window missing (id=\(sourceID))")
            return
        }
        // 方案二（异步面板）：不再同步阻塞截 source/target。源/目标视图先以空图像就位，
        // 图像由后台队列异步回填（trackingBegan 预热保证热缓存，实测 ~15-50ms）。
        // 默认模式背景未排除源窗口 → 源区域由背景真实像素兜底，晚到回填无黑/空效应；
        // 干净模式背景排除源窗口 → 源图像需同步回填，避免源区域短暂露出桌面。
        slideSourceID = sourceID

        // 目标窗口所在屏幕：取源窗口 NS 坐标中心点所在屏幕。
        let sourceNS = nsGlobalRect(fromCG: sourceInfo.frame)
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.insetBy(dx: -40, dy: -40).contains(NSPoint(x: sourceNS.midX, y: sourceNS.midY))
        }) ?? NSScreen.screens.first else {
            logDebug("SLIDE: abort — no target screen")
            return
        }
        screenRect = screen.frame
        let settings = AppSettings.shared
        let ratio = CGFloat(settings.slidingRatio)
        let disp = CGFloat(settings.swipeMinDisplacement)
        pointsPerProgress = ratio * disp * screenRect.width

        // 方向计划：sign>=0 → 目标=left、反向=right；sign<0 相反。
        // 与 trackingBegan 预捕共用 SlideResolver，保证预捕预测与实际计算一致。
        let sign = initialProgress > 0 ? 1 : (initialProgress < 0 ? -1 : 0)
        let plan = SlideResolver.plan(sign: sign, leftID: leftID, rightID: rightID)
        let targetInfo = plan.targetID.flatMap { wm.windows[$0] }
        boundary = targetInfo == nil

        // 面板
        let panel = NSPanel(
            contentRect: screenRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // 层级取菜单栏(kCGMainMenuWindowLevel=24)之下、普通窗口(0)之上：若层级高于
        // 菜单栏并覆盖其区域，macOS 会自动隐藏菜单栏（演示模式机制），导致滑动全程
        // 菜单栏消失。降到 23 后真实菜单栏全程保持可见，不再突然消失。
        panel.level = NSWindow.Level(rawValue: 23)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(origin: .zero, size: screenRect.size))

        // 背景层：全程透明占位。SCK 截屏到达前的空窗期直接显示真实桌面（面板之下），
        // 从机制上消除「不透明黑占位」在背景图晚于动画到达时的整屏黑闪；源/目标快照
        // 视图在其上盖顶（源快照 frame 与真实源重合、不残像），背景图就位后以不透明
        // 全屏图平铺覆盖透明底。捕获失败保持透明即自然回退为真实桌面。
        let bg = NSView(frame: content.bounds)
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.clear.cgColor
        content.addSubview(bg)
        backdrop = bg

        // 源窗口图像：按真实屏幕帧摆放（居中、保留真实 y 与尺寸）。
        // sourceShadowEnabled 关闭时去掉人工 NSShadow——背景图已自带源窗口真实阴影，
        // 避免双重阴影光晕；开启保留现状动态效果。
        // 干净模式（sourceShadowCleanEnabled）下强制不加人工阴影——背景已排除源窗口
        // （无真实投影），叠加只会重新引入阴影，与「完全移除」目标相悖。
        sourceBase = localRect(forCG: sourceInfo.frame)
        // 源窗口截取关闭 → 不创建源快照视图：源区域由背景图（若开，含冻结源）或
        // 实时桌面（背景亦关）兜底，applyCurrentOffset/settle 均有 if let sourceView 守卫。
        if AppSettings.shared.sourceCaptureEnabled {
            let sourceShadowOn = !AppSettings.shared.sourceShadowCleanEnabled
                && AppSettings.shared.sourceShadowEnabled
            let sv = makeImageView(image: nil, frame: sourceBase, shadow: sourceShadowOn)
            content.addSubview(sv)
            sourceView = sv
            if AppSettings.shared.sourceShadowCleanEnabled {
                // 干净模式：背景已排除源窗口，需同步回填源图避免源区域露出桌面。
                sv.image = wm.captureRawImage(for: sourceID, ownerName: sourceInfo.ownerName)
            } else {
                fillAsync(view: sv, windowID: sourceID, ownerName: sourceInfo.ownerName)
            }
        }

        // 统一模型：仅目标窗口图像从屏幕边缘滑入真实位（滑动对象=目标）；源、遮挡者、
        // 反向邻居全部静态留背景（背景无窗口排除集，接受目标滑入时与背景真实位重影）。
        // 边缘锚点：右滑目标前缘贴屏幕左缘（baseX=-width）、左滑目标前缘贴右缘
        //（baseX=屏宽）——手指一动即露边、从第一像素跟手，消除小窗口「先滑屏外、
        // 后冒出」的不可见预行程。到达真实位由 applyCurrentOffset 钳制停住。
        // 边界（目标侧无窗口）→ 无目标视图，源随手指按弹性公式 wall-bump。
        if let info = targetInfo {
            let real = localRect(forCG: info.frame)
            let baseX = sign < 0 ? screenRect.width : -real.width
            // 目标图像异步回填：边缘锚定（前缘贴屏幕边缘），回填到达前目标视图在
            // 屏幕外/边缘不可见，晚到感知不到，无需同步阻塞。
            let tv = makeImageView(image: nil,
                                   frame: NSRect(x: baseX, y: real.minY, width: real.width, height: real.height))
            content.addSubview(tv)
            extraSlideViews.append(SlidingImage(view: tv, baseX: baseX, realFrame: real))
            fillAsync(view: tv, windowID: info.id, ownerName: info.ownerName)
        }

        panel.contentView = content

        // 背景预捕消费（一次消费即清空会话）：图已就绪 → 面板弹出前平铺（零黑，
        // 根治非全屏源黑闪）；图在途 → 异步路径短等该 Direction；无匹配 → 全新捕获。
        // 背景大图截取关闭 → 跳过全部预捕消费，透明占位直通实时桌面。
        var inflight: BackdropPreCapturer.Direction?
        var needAsyncBackdrop = true
        if AppSettings.shared.backdropCaptureEnabled {
            switch BackdropPreCapturer.shared.take(
                sourceID: sourceID, leftID: leftID, rightID: rightID,
                screenSize: screenRect.size, sign: sign) {
            case .ready(let image):
                applyBackdropImage(image, animate: false)
                // 预捕图就绪即同步喂菜单覆盖条：材质（模糊）+ 源文字（清晰裁剪）都取自
                // 同一张整屏图，避免预捕路径下覆盖条停留在占位透明态、源菜单不随手指渐隐。
                applyMenuBarContent(from: image)
                logDebug("SLIDE: backdrop pre-captured → 直接平铺（零黑）")
                needAsyncBackdrop = false
            case .inflight(let dir):
                inflight = dir
            case .none:
                break
            }
        } else {
            needAsyncBackdrop = false
            logDebug("SLIDE: backdrop capture disabled — 透明占位直通实时桌面")
        }

        panel.alphaValue = 0
        // 强制同步渲染：预捕 ready 的 2940×1912 全屏背景图与源/滑动窗口纹理在面板
        // 可见前完成 GPU 上传。若纹理上传落在淡入（60ms）之后，淡入首帧只能显示
        // 黑色占位底（begin+30ms 瞬黑）。对 inflight/none 路径（背景为黑色占位）
        // 同步渲染无副作用，源/滑动视图纹理同样提前就绪。
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.contentView?.displayIfNeeded()
        CATransaction.flush()
        panel.orderFrontRegardless()

        self.panel = panel
        panelWindowNumber = CGWindowID(panel.windowNumber)
        currentOffset = 0
        carryOffset = 0
        isSettling = false
        settleComplete = false
        offsetSamples.removeAll()
        lastPeakVelocity = 0
        samplingEnabled = true
        isActive = true

        // 顶部菜单栏覆盖条（level 25）：材质背景 + AX 自绘源/目标菜单文字随手指交叉淡化。
        // 菜单栏渐变开关关闭时跳过覆盖条创建（下游调用自然空转），采用原生顶栏切换动效。
        let sourcePID = sourceInfo.ownerPid
        let targetPID = plan.targetID.flatMap { wm.windows[$0]?.ownerPid }
        // 菜单覆盖条材质/源文字全部来自背景大图裁剪：背景截取关闭 → 覆盖条无材质来源，
        // 跳过创建（等效渐变关闭），采用原生顶栏切换动效。
        if AppSettings.shared.menuBarGradientEnabled && AppSettings.shared.backdropCaptureEnabled {
            createMenuCover(sourcePID: sourcePID, targetPID: targetPID)
        }

        // 首帧位移在面板可见前应用：淡入时即带正确的小位移，避免「淡入后从 0 瞬移」弹射。
        update(progress: initialProgress)

        // 淡入，缓解会话开始时的首帧跳变。
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.06
            panel.animator().alphaValue = 1
        }

        if needAsyncBackdrop {
            captureBackdrop(panelWindowNumber: panel.windowNumber,
                            coverWindowNumber: menuCoverPanel?.windowNumber, inflight: inflight)
        }
        scheduleDiagSamples()

        // 揭示诊断：记录会话窗口 ID 快照 + 基线采样（视频/目标窗口内容在会话内变化量，
        // 用于区分「冻结背景过期跳变」与「目标窗口激活重绘闪白」）。
        debugSourceWindowID = sourceID
        debugTargetWindowID = plan.targetID
        debugReverseWindowID = sign >= 0 ? rightID : leftID
        let diagPN = panelWindowNumber
        let diagTarget = plan.targetID
        let diagReverse = sign >= 0 ? rightID : leftID
        scheduleRevealDiag("T0+250ms", delay: 0.25, panelWindowNumber: diagPN,
                           targetID: diagTarget, reverseID: diagReverse)

        // 淡入期真实屏幕存帧诊断（方案4.1）：淡入 0.06s 内密集采样合成画面。
        // 占位层透明后淡入首帧=真实桌面（非黑），fN 帧用于验证空窗期无黑闪——若
        // 背景图晚到但画面保持真实桌面亮度，即证明根治；mean≈0 的黑帧将不复现。
        // fN 帧与淡出期 cN/rN 帧同存 /tmp/reveal（同名不冲突）。
        for (label, delay) in [("f1", 0.025), ("f2", 0.040), ("f3", 0.055),
                               ("f4", 0.070), ("f5", 0.090)] {
            scheduleFrame(label, delay: delay, panelWindowNumber: diagPN,
                          targetID: diagTarget, reverseID: diagReverse,
                          extraWindowMeans: false)
        }

        let leftName = leftID.flatMap { wm.windows[$0]?.ownerName } ?? "nil"
        let rightName = rightID.flatMap { wm.windows[$0]?.ownerName } ?? "nil"
        let leftReal = leftID.flatMap { id in wm.windows[id].map { info in localRect(forCG: info.frame) } } ?? .zero
        let rightReal = rightID.flatMap { id in wm.windows[id].map { info in localRect(forCG: info.frame) } } ?? .zero
        logDebug("SLIDE: begin source=[\(sourceInfo.ownerName)] left=\(leftName) right=\(rightName) screen=\(Int(screenRect.width))x\(Int(screenRect.height)) ratio=\(String(format: "%.2f", ratio)) disp=\(String(format: "%.2f", disp)) boundary=\(boundary)")
        logDebug("SLIDE:DBG begin cg source=\(dbgRect(sourceInfo.frame)) left=\(leftID.flatMap { id in wm.windows[id].map { dbgRect($0.frame) } } ?? "nil") right=\(rightID.flatMap { id in wm.windows[id].map { dbgRect($0.frame) } } ?? "nil")")
        logDebug("SLIDE:DBG begin base source=\(dbgRect(sourceBase)) extra=\(extraSlideViews.map { dbgRect($0.view.frame) }.joined(separator: " | "))")

        // BGFLASH ①：会话骨架、方向/目标/反向邻居判定、桌面全量快照（前→后）。
        bgDiag.sourceID = sourceID
        bgDiag.leftID = leftID
        bgDiag.rightID = rightID
        bgDiag.sourceName = sourceInfo.ownerName
        bgDiag.leftName = leftName
        bgDiag.rightName = rightName
        bgDiag.sourceReal = sourceBase
        bgDiag.leftReal = leftReal
        bgDiag.rightReal = rightReal
        bgDiag.targetName = sign >= 0 ? leftName : rightName
        bgDiag.reverseName = sign >= 0 ? rightName : leftName
        logDebug("BGFLASH:begin source=[\(bgDiag.sourceName)]@\(dbgRect(sourceInfo.frame)) left=[\(bgDiag.leftName)]@\(leftReal != .zero ? dbgRect(leftReal) : "nil") right=[\(bgDiag.rightName)]@\(rightReal != .zero ? dbgRect(rightReal) : "nil") boundary=\(boundary) dir=\(sign >= 0 ? "left" : "right") target=[\(bgDiag.targetName)] reverse=[\(bgDiag.reverseName)]")
        let ground = WindowManager.shared.snapshotDesktopWindows()
            .map { "[\($0.name)]@(\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width)),\(Int($0.frame.height)))" }
            .joined(separator: " ")
        logDebug("BGFLASH:ground \(ground)")
        logDebug("BGFLASH:统一模型背景无排除集（源/遮挡者/反向邻居均静态留背景）—— 仅排除本面板/菜单覆盖条")
    }

    /// 按最新 progress 平移窗口图像。offset = SlideOffset.eased(progress)，
    /// 严格跟手、全程连续无瞬移：任何一帧的位置都由当前 progress 经软起步曲线
    /// 推导，clamp 在 ±屏宽。静态源模式下源窗口不移动。
    /// 链式会话（carryOffset≠0）从进位位置起算：currentOffset = carry + eased(progress)。
    func update(progress: CGFloat) {
        guard isActive, !isSettling else { return }
        currentOffset = SlideOffset.chained(progress: progress,
                                            carry: carryOffset,
                                            pointsPerProgress: pointsPerProgress,
                                            screenWidth: screenRect.width)
        recordOffsetSample()
        applyCurrentOffset()
        applyMenuCover()
    }

    /// 链式接续（连甩连贯）：同向新快甩打断正在收尾（settle/fade）的会话，复用面板
    /// （不 teardown、不淡出），从被打断位置**继续**滑动下一目标。位置继承由
    /// carryOffset 实现：新目标 currentOffset = 打断位置 + eased(progress)，运动位置
    /// 不回跳，仅内容切换到新目标。背景图不重捕（链式期间无激活、窗口未移动，
    /// 原背景始终正确）。仅同向链式；反向/边界由调用方（AppDelegate）裁决。
    func chainBegin(sourceID: CGWindowID, leftID: CGWindowID?, rightID: CGWindowID?,
                    initialProgress: CGFloat) {
        guard isActive, isSettling else {
            logDebug("SLIDE-CHAIN: skip — not settling (isActive=\(isActive) isSettling=\(isSettling))")
            return
        }
        guard !settleComplete else {
            logDebug("SLIDE-CHAIN: skip — settle already activated target（fade 期不链式）")
            return
        }
        sessionToken += 1                 // 失效旧 settle/fade 的全部延迟回调
        settleFallbackEngaged = false
        isSettling = false
        settleComplete = false
        // 打断位置继承：读取旧滑动视图 presentation 真值（settle 动画行进中 model frame
        // 已是动画目标、currentOffset 冻结在抬手值，均非屏幕当前位）。必须在取消动画前读取。
        if let s = extraSlideViews.first {
            let presX = s.view.layer?.presentation()?.frame.minX ?? s.view.frame.minX
            carryOffset = presX - s.baseX
        } else {
            carryOffset = currentOffset
        }
        cancelSettleAnimations()
        if (panel?.alphaValue ?? 1) < 1 {
            panel?.alphaValue = 1          // 淡出中被打断 → 恢复全不透明，避免闪帧
        }

        let wm = WindowManager.shared
        guard let sourceInfo = wm.windows[sourceID] else {
            logDebug("SLIDE-CHAIN: abort — source window missing (id=\(sourceID))")
            return
        }
        slideSourceID = sourceID

        let sign = initialProgress > 0 ? 1 : (initialProgress < 0 ? -1 : 0)
        let plan = SlideResolver.plan(sign: sign, leftID: leftID, rightID: rightID)
        let targetInfo = plan.targetID.flatMap { wm.windows[$0] }
        boundary = targetInfo == nil
        if boundary {
            // 边界（目标侧无窗口）不链式（调用方已裁决），此处防御性回落。
            logDebug("SLIDE-CHAIN: boundary, dropping chain")
            cancel()
            return
        }

        // 面板复用：保留 panel/backdrop/sourceView/菜单覆盖条，仅替换目标滑动视图。
        // 源/目标背景图中已有（未激活、窗口未移动），不再维护冗余滑动视图。
        sourceView = nil
        sourceBase = .zero
        for s in extraSlideViews {
            s.view.removeFromSuperview()
        }
        extraSlideViews = []

        if let info = targetInfo {
            let real = localRect(forCG: info.frame)
            let baseX = sign < 0 ? screenRect.width : -real.width
            // 链式目标同样异步回填：边缘锚定，回填到达前不可见，无需同步阻塞。
            let tv = makeImageView(image: nil,
                                   frame: NSRect(x: baseX, y: real.minY, width: real.width, height: real.height))
            panel?.contentView?.addSubview(tv)
            extraSlideViews.append(SlidingImage(view: tv, baseX: baseX, realFrame: real))
            fillAsync(view: tv, windowID: info.id, ownerName: info.ownerName)
        }

        // 菜单覆盖条目标文字层更新为新目标（缓存；无缓存则 commit 瞬显，与现状一致）。
        // 源文字层不变——链式期间真实前置仍是最初源应用（未激活），其菜单即背景截图。
        if AppSettings.shared.menuBarGradientEnabled,
           let targetPID = targetInfo?.ownerPid,
           let strip = MenuBarImageCache.shared.strip(pid: targetPID),
           let targetImage = targetMenuImageView {
            let coverW = targetImage.frame.width
            if coverW > 0 {
                targetImage.image = NSImage(cgImage: strip,
                                            size: NSSize(width: coverW, height: targetImage.frame.height))
            }
        }

        offsetSamples.removeAll()
        lastPeakVelocity = 0
        samplingEnabled = true
        update(progress: initialProgress)

        // 诊断：链式会话骨架。
        bgDiag.sourceID = sourceID
        bgDiag.sourceName = sourceInfo.ownerName
        bgDiag.leftID = leftID
        bgDiag.rightID = rightID
        bgDiag.leftName = leftID.flatMap { wm.windows[$0]?.ownerName } ?? "nil"
        bgDiag.rightName = rightID.flatMap { wm.windows[$0]?.ownerName } ?? "nil"
        bgDiag.targetName = sign >= 0 ? bgDiag.leftName : bgDiag.rightName
        bgDiag.reverseName = sign >= 0 ? bgDiag.rightName : bgDiag.leftName
        logDebug("SLIDE-CHAIN: carry=\(Int(carryOffset)) source=[\(bgDiag.sourceName)] target=[\(bgDiag.targetName)]")
    }

    /// 取消面板内容上所有进行中的动画（settle 滑动 / 淡出 / 菜单文字层），
    /// 避免与链式新会话打架。
    private func cancelSettleAnimations() {
        func cancel(_ v: NSView?) {
            v?.layer?.removeAllAnimations()
            v?.subviews.forEach { cancel($0) }
        }
        cancel(panel?.contentView)
        cancel(menuCoverPanel?.contentView)
    }

    /// 追加 offset 采样：距上个样本 <4ms 则覆盖（防饱和区冗余），否则追加；仅保留
    /// 最近 50ms。随跟踪期钳制取消，offset 全程反映真实位移，速度采样不再被截平。
    private func recordOffsetSample() {
        guard samplingEnabled else { return }
        let now = CACurrentMediaTime()
        let value = Double(currentOffset)
        if let last = offsetSamples.last, now - last.time < 0.004 {
            offsetSamples[offsetSamples.count - 1] = OffsetSample(time: now, offset: value)
        } else {
            offsetSamples.append(OffsetSample(time: now, offset: value))
        }
        while let first = offsetSamples.first, now - first.time > 0.050 {
            offsetSamples.removeFirst()
        }
    }

    /// 释放速度（offset 域，px/s）：对缓冲内最近至多 4 个样本做最小二乘线性回归。
    /// 样本 <3 或时间跨度 <16ms → 返回 0（视为无速度，动量助推为 0）。
    func releaseVelocity() -> CGFloat {
        let samples = Array(offsetSamples.suffix(4))
        guard samples.count >= 3,
              let t0 = samples.first?.time,
              let t1 = samples.last?.time,
              t1 - t0 >= 0.016 else { return 0 }
        let tMean = samples.reduce(0.0) { $0 + $1.time } / Double(samples.count)
        let oMean = samples.reduce(0.0) { $0 + $1.offset } / Double(samples.count)
        var num = 0.0
        var den = 0.0
        for s in samples {
            num += (s.offset - oMean) * (s.time - tMean)
            den += (s.time - tMean) * (s.time - tMean)
        }
        guard den > 1e-9 else { return 0 }
        return CGFloat(num / den)
    }

    /// 记录 C 引擎送达的会话峰值横向速度（progress/sec，带符号）。AppDelegate 在
    /// swipePeakVelocity 事件到达时调用（紧随其后即 gestureEnd）。
    func recordPeakVelocity(_ velocity: CGFloat) {
        lastPeakVelocity = velocity
    }

    /// commit 时登记「待激活目标」：settle 落定前若被非链式方式结束，cancel 会补激活。
    /// 链式接续时新的 commit 会覆盖它（中间步按设计不激活）。
    func markCommitPending(_ target: CGWindowID) {
        pendingActivationTarget = target
        logDebug("SLIDE: pending commit target=\(target)")
    }

    /// 会话峰值速度 → 偏移域速度（px/s）：快甩时 |p| 远超软起步膝点，eased 斜率≈1，
    /// 故 progress/sec × pointsPerProgress ≈ offset px/s（近似误差 <10%）。加速下限
    /// 拦截 settle 边缘微动误判：|峰值| 折算后 < 800 px/s 视为无速度（真实快甩
    /// 2000+ px/s，慢速拖拽 <500 px/s），与关闭动量时行为一致。
    func peakOffsetVelocity() -> CGFloat {
        let minFlickPxPerSec: CGFloat = 800
        let pxPerSec = lastPeakVelocity * pointsPerProgress
        return abs(pxPerSec) >= minFlickPxPerSec ? pxPerSec : 0
    }

    /// 菜单文字层 alpha = 随 progress 顺序淡化（不重叠）：源菜单截图先完全消失
    /// （0→0.7，p≥0.7 时为 0），目标菜单截图在其后才开始渐显（0.72→1）——保证
    /// 「源文字完全不可见后，目标文字才淡入」。折返逆转。目标无缓存时该层为空 →
    /// commit 后瞬显。材质背景恒不透明（遮真实源菜单），文字层为唯一变化面。
    private func applyMenuCover() {
        let p = min(1, max(0, abs(currentOffset) / max(screenRect.width, 1)))
        sourceMenuImageView?.alphaValue = 1 - smoothstep(p, edge0: 0, edge1: 0.7)
        targetMenuImageView?.alphaValue = smoothstep(p, edge0: 0.72, edge1: 1.0)
    }

    private func smoothstep(_ x: CGFloat, edge0: CGFloat, edge1: CGFloat) -> CGFloat {
        let t = min(1, max(0, (x - edge0) / max(edge1 - edge0, 0.0001)))
        return t * t * (3 - 2 * t)
    }

    /// 按 currentOffset 平移源 / 额外滑动视图。统一模型：源静态留背景，仅边界时按
    /// 弹性公式 wall-bump；额外滑动视图（仅目标）从屏幕边缘按 offset 平移、到达
    /// 真实位即停（右滑 baseX<real.minX → min；左滑 baseX>real.minX → max），折返时
    /// offset 回落、钳制自动松开、窗口反向滑出。
    private func applyCurrentOffset() {
        if let sourceView {
            let x = boundary ? sourceBase.minX + elasticWallBumpDisplacement(currentOffset) : sourceBase.minX
            sourceView.setFrameOrigin(NSPoint(x: x, y: sourceBase.minY))
        }
        for s in extraSlideViews {
            let x = s.baseX + currentOffset
            let parked = s.baseX < s.realFrame.minX ? min(x, s.realFrame.minX) : max(x, s.realFrame.minX)
            s.view.setFrameOrigin(NSPoint(x: parked, y: s.realFrame.minY))
        }
        logDebug("SLIDE:DBG update off=\(Int(currentOffset)) src=\(sourceView.map { dbgRect($0.frame) } ?? "nil") extra=\(extraSlideViews.map { dbgRect($0.view.frame) }.joined(separator: " | "))")
    }

    /// 边界 wall-bump 位移：弹性公式 raw/(1+|raw|/40)，clamp ±「最大偏移像素」
    ///（AppSettings.elasticDragMaxDisplacement，与弹性拖拽设置一致）。
    private func elasticWallBumpDisplacement(_ raw: CGFloat) -> CGFloat {
        let damped = raw / (1.0 + abs(raw) / 40.0)
        let maxDisp = CGFloat(AppSettings.shared.elasticDragMaxDisplacement)
        return max(-maxDisp, min(maxDisp, damped))
    }

    /// 释放判定后的收尾动画：commit 为 true 时目标动画到真实位、否则滑回屏外原位。
    /// 动画完成后收起面板并回调 onComplete（受会话 token 保护）。目标滑动视图按绝对
    /// 端点动画（commit→real.minX，回弹→baseX）；源（边界 wall-bump）直接动画回原位。
    /// 停靠态下目标已在 real.minX，commit 动画为零、无跳变。delta 仅留诊断日志。
    func settle(finalOffset: CGFloat, commit: Bool, onComplete: (() -> Void)?) {
        guard isActive else {
            onComplete?()
            return
        }
        isSettling = true
        lastSettleSign = finalOffset < 0 ? -1 : 1
        samplingEnabled = false
        diagSample(label: "settle")
        let targetOffset: CGFloat
        if commit {
            targetOffset = (finalOffset < 0 ? -1 : 1) * screenRect.width
        } else {
            targetOffset = 0
        }
        let delta = targetOffset - currentOffset
        let token = sessionToken
        logDebug("SLIDE: settle finalOffset=\(Int(finalOffset)) current=\(Int(currentOffset)) target=\(Int(targetOffset)) commit=\(commit) delta=\(Int(delta))")
        logDebug("SLIDE:DBG settle src=\(sourceView.map { dbgRect($0.frame) } ?? "nil") extra=\(extraSlideViews.map { dbgRect($0.view.frame) }.joined(separator: " | "))")

        // BGFLASH ③：commit 时预测每个被排除窗口在 teardown 后是否瞬切弹出。
        if commit {
            let dirRight = finalOffset < 0
            bgLastCommitDirRight = dirRight
            let targetReal = dirRight ? bgDiag.rightReal : bgDiag.leftReal
            logDebug("BGFLASH:settle commitDirRight=\(dirRight) target=[\(dirRight ? bgDiag.rightName : bgDiag.leftName)] targetFrame=\(dbgRect(targetReal))")
            logDebug("BGFLASH:PREDICT " + bgFlashVerdicts(commitDirRight: dirRight).joined(separator: " | "))
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = settleDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if let sourceView {
                // 源：非边界恒静态（不动即原位）；边界 wall-bump 释放后回弹到原位。
                sourceView.animator().setFrameOrigin(NSPoint(x: sourceBase.minX, y: sourceBase.minY))
            }
            for s in extraSlideViews {
                let finalX = commit ? s.realFrame.minX : s.baseX
                s.view.animator().setFrameOrigin(NSPoint(x: finalX, y: s.realFrame.minY))
            }
            // 覆盖条保持不透明（遮住真实菜单栏切换）；整体淡出在 finishSettle 进行。
            // 菜单文字层不走此组——提交时须「源先消失、目标后渐显」顺序执行，见下。
            menuCoverPanel?.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            guard let self else { return }
            guard token == self.sessionToken else { return }
            self.finishSettle(commit: commit, onComplete: onComplete)
        }

        // 菜单文字层（独立顺序动画，与滑动动画并行）：提交→源文字先完全消失
        //（~0.10s easeOut），目标文字随后渐显（~0.18s easeInOut），两段串行、
        // 在 settleDuration(0.30s) 内完成、互不重叠；回弹→源/目标文字并行还原
        //（无真实内容切换，恢复静止态即可）。
        if commit {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.10
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                sourceMenuImageView?.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self, token == self.sessionToken else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self.targetMenuImageView?.animator().alphaValue = 1
                } completionHandler: {}
            }
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                sourceMenuImageView?.animator().alphaValue = 1
                targetMenuImageView?.animator().alphaValue = 0
            } completionHandler: {}
        }
    }

    /// 收尾：settle 滑动动画完成后收起面板。
    /// 不再抬面板到 popUpMenu——菜单栏过渡由 level 25 覆盖条负责：commit 时面板
    /// 保持 23、菜单覆盖条保持不透明，onComplete 激活目标（真实菜单栏在覆盖条后
    /// 切换为目标菜单），随后面板 alpha 与菜单覆盖条 alpha 同步淡出——目标窗口
    /// 顶栏随面板渐显、真实目标菜单随覆盖条渐显，两者同节奏，无弹跳。
    /// 回弹无内容切换，仅面板淡出平滑收起。
    private func finishSettle(commit: Bool, onComplete: (() -> Void)?) {
        // 跟手期暂缓的背景图在此落图：滑动动画已走完、窗口静止，大图纹理上传的
        // 40-51ms 主线程阻塞不再丢跟手帧；落图后面板携带冻结桌面快照进入淡出。
        flushPendingBackdrop()
        // settle 落定（token 匹配、未被链式/取消打断）：onComplete 即将激活目标，
        // 消费 pending（正常路径的激活由 onComplete 执行，cancel 不再补激活）。
        pendingActivationTarget = nil
        guard let panel else {
            onComplete?()
            teardownPanel()
            isActive = false
            return
        }
        let token = sessionToken
        settleComplete = true   // 目标已激活/进入 fade：链式应被阻断，后续交给全新会话
        onComplete?()
        diagSample(label: "finishSettle")
        let settleFadeToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, settleFadeToken == self.sessionToken else { return }
            self.diagSample(label: "finishSettle+60ms")
        }
        // 存帧诊断（REVEAL-FRAME）：淡出全程密集采集合成画面并存 PNG 到 /tmp/reveal，
        // 直接查看闪屏帧（3×3 灰度无法捕捉的亚帧/局部瞬变）。首末帧额外采目标/视频
        // 窗口均值。采样在 revealDiagQueue 上串行、alpha 读取也在后台队列（不占主线程），
        // 避免淡出期主线程阻塞本身制造/掩盖闪屏。
        let fadePlan: [(label: String, delay: Double, extra: Bool)]
        if commit {
            // commit 淡出 0.30s：0.02s 起每 50ms 一帧覆盖淡出全程，随后拉开间距观察
            // teardown 后实时桌面是否弹出残留。
            fadePlan = [
                ("c1", 0.02, true), ("c2", 0.07, false), ("c3", 0.12, false),
                ("c4", 0.17, false), ("c5", 0.22, false), ("c6", 0.27, false),
                ("c7", 0.32, false), ("c8", 0.37, true), ("c9", 0.45, false),
                ("c10", 0.55, false), ("c11", 0.70, false), ("c12", 0.90, true)
            ]
        } else {
            // 回弹淡出 0.15s：0.02s 起每 40ms 一帧。
            fadePlan = [
                ("r1", 0.02, true), ("r2", 0.06, false), ("r3", 0.10, false),
                ("r4", 0.14, false), ("r5", 0.18, false), ("r6", 0.24, false),
                ("r7", 0.32, false), ("r8", 0.45, true)
            ]
        }
        let pn = panelWindowNumber
        let tid = debugTargetWindowID
        let rid = debugReverseWindowID
        for (label, delay, extra) in fadePlan {
            scheduleFrame(label, delay: delay, panelWindowNumber: pn,
                          targetID: tid, reverseID: rid, extraWindowMeans: extra)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            // 提交：0.3s easeInOut 让窗口顶栏（面板内容）与真实目标菜单（覆盖条
            // 之下）同步渐显，节奏一致；回弹无窗口/菜单切换，短淡出快速收起。
            ctx.duration = commit ? 0.30 : 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: commit ? .easeInEaseOut : .easeOut)
            panel.animator().alphaValue = 0
            menuCoverPanel?.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            guard token == self.sessionToken else { return }
            if self.settleFallbackEngaged { return }  // 兜底接管中，交由手动淡出拆除
            self.teardownPanel()
            self.isActive = false
        }
        // 兜底：淡出 completionHandler 偶发不触发（主线程被 SCK 截屏/纹理上传阻塞
        // 超淡出时长，面板滞留全屏不透明并吞掉后续手势——日志中 finishSettle 面板
        // 冻结、mean 居高不下即此现象）。0.5s 后会话仍存活且面板未收起则兜底收起，
        // 保证不残留死会话。正常淡出 ~0.12-0.2s 完成、panel 置 nil，兜底自然跳过。
        // 不再直接 orderOut 硬切（不透明面板瞬间消失=黑闪 + 与下一会话预捕竞争制造
        // 自拍背景）：判定用屏幕实时透明度——panel.alphaValue 是动画模型值，停滞时
        // 动画目标已是 0 但视觉仍不透明，模型值不可用。仍可见 → 手动驱动淡出后拆，
        // 已透明 → 直接拆。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            guard token == self.sessionToken else { return }
            let onScreenAlpha = Self.panelOnScreenAlpha(self.panelWindowNumber) ?? 1.0
            switch SettleFallback.action(panelExists: self.panel != nil, panelAlpha: onScreenAlpha) {
            case .noPanel:
                break
            case .teardownNow:
                logDebug("SLIDE: finishSettle fade fallback — panel already transparent, tearing down")
                self.teardownPanel()
                self.isActive = false
            case .refadeThenTeardown:
                logDebug("SLIDE: finishSettle fade fallback — panel stuck visible, manual fade then teardown")
                self.settleFallbackEngaged = true
                let start = ProcessInfo.processInfo.systemUptime
                // 手动驱动 alpha（绕过可能失效的 animator/completionHandler），0.15s 淡出后拆除。
                let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
                    guard let self else { timer.invalidate(); return }
                    guard token == self.sessionToken else { timer.invalidate(); return }
                    guard let panel = self.panel else { timer.invalidate(); return }
                    let t = min(1.0, (ProcessInfo.processInfo.systemUptime - start) / 0.15)
                    panel.alphaValue = 1.0 - t
                    self.menuCoverPanel?.alphaValue = 1.0 - t
                    if t >= 1.0 {
                        timer.invalidate()
                        logDebug("SLIDE: finishSettle fade fallback — manual fade done, tearing down")
                        self.teardownPanel()
                        self.isActive = false
                    }
                }
                // 跟踪触控板期间默认 runloop 模式可能不派发 timer，挂 .common 保证淡出持续。
                RunLoop.main.add(timer, forMode: .common)
                // 二重兜底：手动淡出若也被主线程阻塞，0.3s 后强制拆除，绝不残留全屏不透明面板。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self else { return }
                    guard token == self.sessionToken else { return }
                    guard self.panel != nil else { return }
                    logDebug("SLIDE: finishSettle fade fallback manual fade stall — forcing teardown")
                    self.teardownPanel()
                    self.isActive = false
                }
            }
        }
    }

    /// 立即终止会话（服务停止 / 被其它手势打断 / 边界丢弃）。
    /// - Parameter flushPending: 为 true 时，若存在已 commit 但未激活的目标（tap/纵向
    ///   手势/边界丢弃打断 settle），通过 onFlushPending 补激活它，避免「滑了没切」；
    ///   反向 cancelAndFresh（用户反悔改向）与服务停止传 false（丢弃但不激活）。
    func cancel(flushPending: Bool = true) {
        if let target = pendingActivationTarget {
            pendingActivationTarget = nil
            if flushPending {
                logDebug("SLIDE: FLUSH pending activation target=\(target)")
                onFlushPending?(target)
            } else {
                logDebug("SLIDE: drop pending activation target=\(target) (flushPending=false)")
            }
        }
        sessionToken += 1
        teardownPanel()
        isActive = false
        isSettling = false
        settleComplete = false
        carryOffset = 0
        currentOffset = 0
        lastPeakVelocity = 0
        logDebug("SLIDE: cancelled")
    }

    // MARK: - Backdrop (ScreenCaptureKit)

    /// 异步截取整屏桌面作为背景层（无窗口排除集，接受目标滑入时与背景真实位重影；
    /// 仅排除本面板与菜单覆盖条，防双影/防覆盖条入镜）。截屏到达前的空窗期占位层
    /// 全程透明、显示真实桌面（根治黑闪），失败则保持透明继续显示真实桌面。
    private func captureBackdrop(panelWindowNumber: Int,
                                 coverWindowNumber: Int?, inflight: BackdropPreCapturer.Direction?) {
        let token = sessionToken
        let scr = screenRect
        Task { @MainActor in
            // 在途预捕优先：等它完成即用（比全新 SCK 查询早发起 ~100ms，剩余时间更短）。
            if let inflight,
               let image = await BackdropPreCapturer.shared.awaitImage(inflight, timeout: 0.35) {
                guard token == self.sessionToken else { return }
                self.applyBackdropWhenIdle(image)
                self.applyMenuBarContent(from: image)
                logDebug("SLIDE: backdrop via in-flight pre-capture（跟手期暂缓落图）excluded=\(inflight.excludedCount ?? 0)")
                return
            }
            do {
                var excl = Set<CGWindowID>()
                if let coverWindowNumber { excl.insert(CGWindowID(coverWindowNumber)) }
                // 干净模式：排除源窗口，背景不再携带其真实投影。源截取关闭时源区域
                // 无 sourceView 兜底，须保留源在背景中，否则露出其背后桌面（洞）。
                if AppSettings.shared.sourceShadowCleanEnabled && AppSettings.shared.sourceCaptureEnabled {
                    excl.insert(slideSourceID)
                }
                let result = try await BackdropPreCapturer.captureDesktop(
                    size: scr.size, excluding: excl, panelWindowNumber: panelWindowNumber)
                guard token == self.sessionToken else { return }
                // 背景图交给统一落图入口：跟手期暂存 pending（不平铺、不阻塞主线程），
                // 收尾落图时以不透明直接平铺覆盖透明占位，从「实时桌面」过渡到「背景
                // 快照」，teardown 揭示真实桌面无跳变。
                self.applyBackdropWhenIdle(result.image)
                self.applyMenuBarContent(from: result.image)
                scheduleBackdropFadeSamples(token: token)
                logDebug("SLIDE: backdrop captured \(result.image.width)x\(result.image.height)px excluded=\(result.excluded.count) fadeIn=0.1")
                let excludedNames = result.excluded
                    .map { "\($0.windowID):[\($0.owningApplication?.applicationName ?? "?")]" }
                    .joined(separator: ",")
                logDebug("BGFLASH:capture excluded=[\(excludedNames)] count=\(result.excluded.count)")
            } catch {
                logDebug("SLIDE: backdrop capture failed — \(error.localizedDescription)")
                // 捕获失败：占位层保持透明即显示真实桌面，自然回退，无需再改颜色。
            }
        }
    }

    /// 背景图像视图：animate=false 时直接平铺（预捕就绪、零黑）；animate=true 时以
    /// ~100ms easeOut 从透明淡入覆盖在透明占位之上（空窗期显示真实桌面，无黑闪）。
    private func applyBackdropImage(_ image: CGImage, animate: Bool) {
        guard let backdrop else { return }
        let imageView = NSImageView(frame: backdrop.bounds)
        imageView.image = NSImage(cgImage: image, size: backdrop.bounds.size)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.alphaValue = animate ? 0 : 1
        backdrop.addSubview(imageView)
        backdropImageView = imageView
        if animate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                imageView.animator().alphaValue = 1
            } completionHandler: {}
        }
    }

    /// 背景图到达的统一落图入口：滑动/跟手期（isActive）暂存 pending、不平铺，收尾
    /// （finishSettle）时 flushPendingBackdrop 一次性落图——把 2940×1912 大图纹理上传
    /// 的 40-51ms 主线程阻塞从「滑动跟手期」移到「窗口静止的收尾期」，跟手不再丢帧。
    /// 会话未激活（isActive=false，如 begin 预捕就绪路径）则直接平铺。
    private func applyBackdropWhenIdle(_ image: CGImage) {
        if isActive {
            pendingBackdrop = image
            logDebug("SLIDE: backdrop pending → 收尾落图（跟手期不平铺）")
        } else {
            // 会话已非激活（用户已抬手）：窗口静止，直接平铺并补采样诊断，
            // 不阻塞跟手期主线程。
            logDebug("SLIDE:DIAG backdrop content \(self.sampleBrightness(image))")
            applyBackdropImage(image, animate: true)
        }
    }

    /// 收尾落图：finishSettle 起点调用，把跟手期暂缓的背景图以不透明直接平铺。
    /// 此时滑动动画已走完、窗口静止，主线程 40-51ms 阻塞不再丢跟手帧；落图后面板
    /// 携带冻结桌面快照进入淡出，teardown 揭示真实桌面无跳变。
    private func flushPendingBackdrop() {
        guard let image = pendingBackdrop else { return }
        pendingBackdrop = nil
        // 像素诊断：与落图同机（finishSettle、窗口静止），把 21-31ms 主线程采样
        // 从滑动跟手期移走；采样对象是静态 CGImage，延后结果一致。
        logDebug("SLIDE:DIAG backdrop content \(self.sampleBrightness(image))")
        applyBackdropImage(image, animate: false)
        logDebug("SLIDE: backdrop flushed（跟手期延迟落图）\(image.width)x\(image.height)px")
    }

    /// 从全屏背景图 crop 顶部菜单栏区域 → 高斯模糊（抹掉文字）→ 作为覆盖条材质
    /// 背景，替换初始占位色。仅填一次（图就绪后不再覆盖）。crop 只取菜单文本区
    /// 宽度（0→coverW），避免整条横向缩放失真。
    /// 背景图到达时设置菜单覆盖条内容：① 背景 = 顶部 37pt 强模糊材质（抹净源文字，
    /// 遮住 live 源菜单）；② 源文字层 = 同区域清晰真实像素（与 live 源菜单完全重合，
    /// 随手指渐隐）。源截图与背景取自同一张整屏图，无需额外采集。
    private func applyMenuBarContent(from fullImage: CGImage) {
        let scale = CGFloat(fullImage.height) / max(screenRect.height, 1)
        let menuBarPx = max(Int(WindowManager.menuBarHeightPoints * scale), 1)
        let coverW = menuBackgroundView?.frame.width ?? sourceMenuImageView?.frame.width ?? 0
        guard coverW > 0 else { return }
        let cropW = max(Int(coverW * scale), 1)
        guard let crop = MenuBarImageCache.cropTopStrip(from: fullImage,
                                                        coverWidthPx: cropW,
                                                        menuBarPx: menuBarPx) else { return }
        if let menuBackgroundView, menuBackgroundView.image == nil {
            let input = CIImage(cgImage: crop)
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = input
            filter.radius = 25
            if let blurred = filter.outputImage {
                let ctx = CIContext(options: [.workingColorSpace: NSNull()])
                if let blurredCG = ctx.createCGImage(blurred, from: input.extent) {
                    menuBackgroundView.image = NSImage(cgImage: blurredCG,
                                                       size: NSSize(width: menuBackgroundView.frame.width,
                                                                    height: menuBackgroundView.frame.height))
                }
            }
        }
        if let sourceMenuImageView, sourceMenuImageView.image == nil {
            sourceMenuImageView.image = NSImage(cgImage: crop,
                                                size: NSSize(width: sourceMenuImageView.frame.width,
                                                             height: sourceMenuImageView.frame.height))
        }
        logDebug("SLIDE: menu cover content applied crop=\(cropW)x\(menuBarPx)px")
    }

    // MARK: - 像素级诊断（仅日志，不影响行为）

    /// 3×3 灰度网格 + 均值（0=纯黑，255=纯白）。共享给 panelLum 与揭示诊断。
    private static func grayStats(_ image: CGImage) -> (grid: [Int], mean: Int) {
        let n = 3
        let buf = UnsafeMutableRawPointer.allocate(byteCount: n * n, alignment: 1)
        defer { buf.deallocate() }
        var grid: [Int] = []
        if let ctx = CGContext(data: buf, width: n, height: n,
                               bitsPerComponent: 8, bytesPerRow: n,
                               space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGImageAlphaInfo.none.rawValue) {
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            let bytes = buf.assumingMemoryBound(to: UInt8.self)
            grid = (0..<(n * n)).map { Int(bytes[$0]) }
        }
        let mean = grid.isEmpty ? 0 : grid.reduce(0, +) / grid.count
        return (grid, mean)
    }

    /// 采样 CGImage 亮度：缩放到 3×3 灰度网格，输出网格各点灰度 + 均值。
    private func sampleBrightness(_ image: CGImage) -> String {
        let s = Self.grayStats(image)
        return "grid=[\(s.grid.map { String($0) }.joined(separator: ","))] mean=\(s.mean)"
    }

    /// 记录面板合成输出（用户实际看到的像素）+ panel/背景图 presentation 透明度。
    /// 方案E1：面板图捕获（弃用的 CGWindowListCreateImage，WindowServer 繁忙时可挂 ~1s，
    /// 主线程执行会冻结淡出动画——会话 E 停滞实测根因）移到后台串行队列；主线程只读
    /// 廉价 layer presentation 值。异步闭包捕获会话 token 并校验，防过期会话写回日志。
    private func diagSample(label: String) {
        guard !diagBypassed else { return }
        guard let panel else {
            logDebug("SLIDE:DIAG \(label) no-panel")
            return
        }
        let contentAlpha = (panel.contentView?.layer?.presentation()?.opacity).map { String(format: "%.2f", $0) } ?? "n/a"
        let bgAlpha = (backdropImageView?.layer?.presentation()?.opacity).map { String(format: "%.2f", $0) } ?? "n/a"
        let pn = panel.windowNumber
        let token = sessionToken
        diagQueue.async { [weak self] in
            guard let self, token == self.sessionToken else { return }
            var lum = "n/a"
            if let cg = WindowSwitcher_CaptureWindowImage(CGWindowID(pn))?.takeRetainedValue() {
                lum = self.sampleBrightness(cg)
            } else {
                lum = "capture-nil"
            }
            logDebug("SLIDE:DIAG \(label) contentAlpha=\(contentAlpha) bgImageAlpha=\(bgAlpha) panelLum=\(lum)")
        }
    }

    /// 调度会话关键时刻采样（begin+30/150/400ms），复现「初期干净 vs 后期黑闪」的亮度轨迹。
    private func scheduleDiagSamples() {
        guard !diagBypassed else { return }
        let token = sessionToken
        for (offset, label) in [(0.03, "begin+30ms"), (0.15, "begin+150ms"), (0.40, "begin+400ms")] {
            DispatchQueue.main.asyncAfter(deadline: .now() + offset) { [weak self] in
                guard let self, token == self.sessionToken else { return }
                self.diagSample(label: label)
            }
        }
    }

    /// 调度背景图淡入期间的 presentation 轨迹采样（+30/60/100ms，验证是否真的 0→1 渐变）。
    private func scheduleBackdropFadeSamples(token: Int) {
        guard !diagBypassed else { return }
        for (offset, label) in [(0.03, "fade+30ms"), (0.06, "fade+60ms"), (0.10, "fade+100ms")] {
            DispatchQueue.main.asyncAfter(deadline: .now() + offset) { [weak self] in
                guard let self, token == self.sessionToken else { return }
                let alpha = (self.backdropImageView?.layer?.presentation()?.opacity)
                    .map { String(format: "%.2f", $0) } ?? "n/a"
                logDebug("SLIDE:DIAG \(label) bgImageAlpha=\(alpha)")
            }
        }
    }

    // MARK: - 揭示环节诊断（REVEAL-DIAG，仅日志，不影响行为）

    /// 会话内窗口 ID 快照（诊断用）：源=滑出窗口，目标=被激活窗口（如系统设置），
    /// 反向=反向邻居（如迅雷影音视频窗口）。仅主线程读写在调度点快照给后台队列。
    private var debugSourceWindowID: CGWindowID?
    private var debugTargetWindowID: CGWindowID?
    private var debugReverseWindowID: CGWindowID?

    /// 揭示诊断截图走后台串行队列：淡出期主线程若再被全屏截图阻塞，反而会制造或
    /// 掩盖闪屏帧，故与功能路径隔离。
    private let revealDiagQueue = DispatchQueue(label: "com.windowswitcher.revealdiag", qos: .utility)

    /// 面板合成图采样走独立后台串行队列：弃用的 CGWindowListCreateImage 在 WindowServer
    /// 繁忙时可挂 ~1s（会话 E 停滞实测根因），若主线程执行会冻结淡出动画；与 revealDiagQueue
    /// 分开，避免一次挂起的面板捕获延迟定时 reveal 帧。
    private let diagQueue = DispatchQueue(label: "com.windowswitcher.diag", qos: .utility)

    /// 面板当前在 WindowServer 上的实际透明度（动画 presentation 真值）。后台队列调用。
    private static func panelOnScreenAlpha(_ pn: CGWindowID) -> Double? {
        guard pn != 0 else { return nil }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            if let num = w[kCGWindowNumber as String] as? Int, num == Int(pn) {
                return (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue
            }
        }
        return nil
    }

    /// 全屏合成画面（用户看到）原始 CGImage。后台队列调用。
    private static func captureScreenImage(_ bounds: CGRect) -> CGImage? {
        WindowSwitcher_CaptureScreenImage(bounds)?.takeRetainedValue()
    }

    /// 全屏合成画面（用户看到）的 3×3 灰度统计。后台队列调用。
    private static func captureScreenStats(bounds: CGRect) -> (grid: [Int], mean: Int)? {
        guard let cg = captureScreenImage(bounds) else { return nil }
        return Self.grayStats(cg)
    }

    /// 单窗口内容均值。后台队列调用；窗口被遮挡时返回其 WindowServer 侧缓存内容。
    private static func captureWindowMean(_ windowID: CGWindowID) -> Int? {
        guard let cg = WindowSwitcher_CaptureWindowImage(windowID)?.takeRetainedValue() else { return nil }
        return Self.grayStats(cg).mean
    }

    /// 采集一次揭示诊断样本：面板 alpha + 合成画面 + 目标窗口 + 视频窗口内容。
    private func revealDiagSample(_ label: String, panelWindowNumber: CGWindowID,
                                  targetID: CGWindowID?, reverseID: CGWindowID?) {
        guard !diagBypassed else { return }
        let bounds = screenRect
        let alpha = Self.panelOnScreenAlpha(panelWindowNumber)
        let alphaStr = alpha.map { String(format: "%.2f", $0) } ?? "n/a"
        revealDiagQueue.async {
            let screen = Self.captureScreenStats(bounds: bounds)
            let ss = targetID.flatMap { Self.captureWindowMean($0) }
            let video = reverseID.flatMap { Self.captureWindowMean($0) }
            let screenStr = screen.map { "\($0.mean) grid=[\($0.grid.map { String($0) }.joined(separator: ","))]" } ?? "capture-nil"
            let ssStr = ss.map { "\($0)" } ?? "nil"
            let videoStr = video.map { "\($0)" } ?? "nil"
            logDebug("REVEAL-DIAG \(label) panelAlpha=\(alphaStr) screen=\(screenStr) ss=\(ssStr) video=\(videoStr)")
        }
    }

    /// 延迟调度一次揭示诊断样本（主线程调度，后台采集）。
    private func scheduleRevealDiag(_ label: String, delay: TimeInterval,
                                    panelWindowNumber: CGWindowID,
                                    targetID: CGWindowID?, reverseID: CGWindowID?) {
        guard !diagBypassed else { return }
        let token = sessionToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, token == self.sessionToken else { return }
            self.revealDiagSample(label, panelWindowNumber: panelWindowNumber,
                                  targetID: targetID, reverseID: reverseID)
        }
    }

    // MARK: - 存帧诊断（REVEAL-FRAME，仅诊断不影响行为）

    /// 存帧输出目录（/tmp/reveal）。静态初始化时清空旧帧，保证每次运行的帧文件均为
    /// 本次会话产生；帧文件名含会话代币，同一运行内多次滑动互不覆盖。
    private static let revealDirURL: URL = {
        let dir = URL(fileURLWithPath: "/tmp/reveal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
        return dir
    }()

    /// 将 CGImage 降采样（默认最长边 1280px）后存为 PNG。降采样使编码快、文件小，
    /// 全屏闪白/闪黑/局部瞬变在低分辨率下仍清晰可见，且不拖累采样节奏。
    private static func savePNG(_ image: CGImage, to url: URL, maxDimension: Int = 1280) {
        let w = image.width, h = image.height
        let scale = min(1.0, CGFloat(maxDimension) / CGFloat(max(w, h)))
        let dw = max(1, Int(CGFloat(w) * scale)), dh = max(1, Int(CGFloat(h) * scale))
        guard let ctx = CGContext(data: nil, width: dw, height: dh,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: dw, height: dh))
        guard let small = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: small).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    /// 在揭示队列上延迟采集一帧存盘诊断：合成画面 → 存 PNG → 3×3 灰度统计 → 日志。
    /// 全程在 revealDiagQueue 串行执行（alpha 读取亦在后台），不经主线程，避免阻塞淡出动画。
    private func scheduleFrame(_ label: String, delay: TimeInterval,
                               panelWindowNumber: CGWindowID,
                               targetID: CGWindowID?, reverseID: CGWindowID?,
                               extraWindowMeans: Bool) {
        guard !diagBypassed else { return }
        let token = sessionToken
        let bounds = screenRect
        revealDiagQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, token == self.sessionToken else { return }
            let alpha = Self.panelOnScreenAlpha(panelWindowNumber)
            let alphaStr = alpha.map { String(format: "%.2f", $0) } ?? "n/a"
            guard let cg = Self.captureScreenImage(bounds) else {
                logDebug("REVEAL-FRAME \(label) panelAlpha=\(alphaStr) capture-nil")
                return
            }
            let url = Self.revealDirURL.appendingPathComponent("\(token)_\(label).png")
            Self.savePNG(cg, to: url)
            let s = Self.grayStats(cg)
            var extra = ""
            if extraWindowMeans {
                let ss = targetID.flatMap { Self.captureWindowMean($0) }
                let video = reverseID.flatMap { Self.captureWindowMean($0) }
                extra = " ss=\(ss.map { "\($0)" } ?? "nil") video=\(video.map { "\($0)" } ?? "nil")"
            }
            logDebug("REVEAL-FRAME \(label) panelAlpha=\(alphaStr) mean=\(s.mean) grid=[\(s.grid.map { String($0) }.joined(separator: ","))]\(extra)")
        }
    }

    // MARK: - BGFLASH 诊断

    /// 依据提交方向计算各滑动组/背景窗口在 teardown 后的瞬切判定（统一模型下全部
    /// NO-POP：目标滑满一屏落回自身真实位、源/反向邻居静态留背景、边界 wall-bump 回弹）。
    private func bgFlashVerdicts(commitDirRight: Bool) -> [String] {
        var verdicts: [String] = []
        if bgDiag.reverseName != "nil" {
            verdicts.append("\(bgDiag.reverseName):NO-POP(反向邻居静态留背景)")
        }
        if bgDiag.targetName != "nil" {
            verdicts.append("\(bgDiag.targetName):NO-POP(target 从边缘滑入落回自身真实位)")
        }
        verdicts.append("\(bgDiag.sourceName):NO-POP(源静态留背景\(boundary ? "；边界 wall-bump 释放回弹" : ""))")
        return verdicts
    }

    /// BGFLASH ④：目标激活后调用（面板已收起），重采样桌面并输出瞬切确认。
    func logPostActivationDiagnostics() {
        let desktop = WindowManager.shared.snapshotDesktopWindows()
        let names = desktop
            .map { "[\($0.name)]@(\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width)),\(Int($0.frame.height)))" }
            .joined(separator: " ")
        logDebug("BGFLASH:teardown 0:\(names)")
        let verdicts = bgFlashVerdicts(commitDirRight: bgLastCommitDirRight)
        logDebug("BGFLASH:CONFIRM " + verdicts.joined(separator: " | "))
    }

    // MARK: - Private

    /// 调试用 compact 矩形（面板本地点，CGRect 与 NSRect 同型）：`(x,y,w,h)`。
    private func dbgRect(_ r: NSRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height)))"
    }

    private func makeImageView(image: NSImage?, frame: NSRect, shadow: Bool = true) -> NSImageView {
        let iv = NSImageView(frame: frame)
        if let image {
            iv.image = image
        }
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        if shadow {
            let nsShadow = NSShadow()
            nsShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            nsShadow.shadowBlurRadius = 12
            nsShadow.shadowOffset = NSSize(width: 0, height: -3)
            iv.shadow = nsShadow
        }
        return iv
    }

    /// 异步回填窗口图像到滑动视图：后台队列截取（受益于 trackingBegan 预热的热缓存，
    /// 实测 ~15-50ms），主线程回填。会话代币 guard 丢弃旧会话的迟到结果；视图已从
    /// 面板移除（window==nil）时不回填。
    private func fillAsync(view: NSImageView?, windowID: CGWindowID, ownerName: String) {
        guard let view else { return }
        let wm = WindowManager.shared
        let token = sessionToken
        windowFillQueue.async { [weak self] in
            let image = wm.captureRawImage(for: windowID, ownerName: ownerName)
            DispatchQueue.main.async { [weak self] in
                guard let self, token == self.sessionToken else { return }
                if let image, view.window != nil {
                    view.image = image
                }
            }
        }
    }

    private func teardownPanel() {
        settleFallbackEngaged = false
        isSettling = false
        settleComplete = false
        carryOffset = 0
        panel?.orderOut(nil)
        panel = nil
        backdrop = nil
        backdropImageView = nil
        pendingBackdrop = nil
        panelWindowNumber = 0
        sourceView = nil
        extraSlideViews = []
        sourceBase = .zero
        slideSourceID = 0
        boundary = false
        menuCoverPanel?.orderOut(nil)
        menuCoverPanel = nil
        menuBackgroundView = nil
        sourceMenuImageView = nil
        targetMenuImageView = nil
    }

    /// 屏幕顶部菜单栏覆盖条（level 25，37pt 高，全宽）。三层结构：
    /// ① 材质模糊背景（SCK 截源菜单栏区域高斯模糊，始终不透明遮真实源菜单）；
    /// ② 源菜单文字容器（AX 自绘，alpha 1→0 随手指渐隐）；③ 目标菜单文字容器
    /// （AX 自绘，alpha 0→1 随手指渐显）。commit 后真实菜单栏在覆盖条后切换，
    /// 覆盖条随面板淡出，露出真实目标菜单（与自绘文字位置一致，衔接自然）。
    /// 仅盖菜单文本区（0→最左状态栏图标 x），状态栏图标区透明、全程可见。
    private func createMenuCover(sourcePID: pid_t?, targetPID: pid_t?) {
        let menuBarHeight = WindowManager.menuBarHeightPoints
        let coverFrame = NSRect(x: screenRect.minX, y: screenRect.maxY - menuBarHeight,
                                width: screenRect.width, height: menuBarHeight)
        let statusX = leftmostStatusItemX()
        let coverW = min(coverFrame.width, max(1, statusX))

        let cover = NSPanel(contentRect: coverFrame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        cover.isFloatingPanel = true
        cover.level = NSWindow.Level(rawValue: 25)
        cover.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        cover.backgroundColor = .clear
        cover.isOpaque = false
        cover.hasShadow = false
        cover.ignoresMouseEvents = true
        cover.hidesOnDeactivate = false
        cover.isMovable = false
        cover.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(origin: .zero, size: coverFrame.size))

        // ① 材质背景：占位完全透明（不引入任何额外视觉变化——SCK 模糊材质到达前
        // 真实源菜单透过覆盖条直接可见，与静止态一致）；applyMenuBarContent 异步
        // 到达后替换为强模糊源菜单区（抹净文字、仍无白板感）。
        let bg = NSImageView(frame: NSRect(x: 0, y: 0, width: coverW, height: menuBarHeight))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.clear.cgColor
        bg.imageScaling = .scaleAxesIndependently
        content.addSubview(bg)
        menuBackgroundView = bg

        // ② 源文字层：真实像素（整屏背景图裁剪的清晰源菜单截图），背景图到达时设置。
        let sourceImage = NSImageView(frame: NSRect(x: 0, y: 0, width: coverW, height: menuBarHeight))
        sourceImage.wantsLayer = true
        sourceImage.imageScaling = .scaleAxesIndependently
        content.addSubview(sourceImage)
        sourceMenuImageView = sourceImage

        // ③ 目标文字层：目标菜单区缓存真实像素（会话内该 App 激活过即有）；无缓存
        // → 空层，不随手指渐显，commit 后覆盖条淡出直接揭示真实目标菜单（瞬变）。
        let targetImage = NSImageView(frame: NSRect(x: 0, y: 0, width: coverW, height: menuBarHeight))
        targetImage.wantsLayer = true
        targetImage.imageScaling = .scaleAxesIndependently
        if let targetPID, let strip = MenuBarImageCache.shared.strip(pid: targetPID) {
            targetImage.image = NSImage(cgImage: strip,
                                        size: NSSize(width: coverW, height: menuBarHeight))
            logDebug("SLIDE: menu cover target cached pid=\(targetPID) \(strip.width)x\(strip.height)px")
        } else {
            logDebug("SLIDE: menu cover target no-cache → commit 瞬显")
        }
        content.addSubview(targetImage)
        targetMenuImageView = targetImage

        cover.contentView = content
        cover.orderFrontRegardless()
        menuCoverPanel = cover
        logDebug("SLIDE: menu cover h=\(Int(menuBarHeight)) statusX=\(Int(statusX)) coverW=\(Int(coverW))")
    }

    /// 最左状态栏图标的全局 x（CG 顶部原点坐标；单屏下与 NS 左起点一致）。
    /// 扫描逻辑抽到 MenuBarImageCache.leftmostStatusItemX（采集端共用），此处仅取回+日志。
    private func leftmostStatusItemX() -> CGFloat {
        let result = MenuBarImageCache.leftmostStatusItemX(fallbackScreenWidth: screenRect.width)
        logDebug("SLIDE: status items leftmostX=\(Int(result))")
        return result
    }

    /// 将 CGWindowList bounds（左上原点、y 向下、全局坐标）转成 NS 全局坐标
    /// （左下原点、y 向上）。CG 的 y 原点为主显示器顶部，x 轴与 NS 一致。
    private func nsGlobalRect(fromCG cg: CGRect) -> CGRect {
        let primaryTop = NSScreen.main?.frame.maxY
            ?? NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: cg.minX, y: primaryTop - cg.maxY, width: cg.width, height: cg.height)
    }

    /// 将窗口 CG bounds 换算为面板本地坐标（面板覆盖 screenRect，左下原点）。
    private func localRect(forCG cg: CGRect) -> NSRect {
        let ns = nsGlobalRect(fromCG: cg)
        return NSRect(x: ns.minX - screenRect.minX,
                      y: ns.minY - screenRect.minY,
                      width: ns.width,
                      height: ns.height)
    }
}
