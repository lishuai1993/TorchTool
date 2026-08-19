import AppKit
import ScreenCaptureKit

/// 三指横滑「跟随手指」滑动过渡切换。
///
/// 会话开始时抓拍源窗口与左右邻窗口（LRU 相邻）快照，以全屏透明 NSPanel
/// 呈现。三个窗口图像保持真实尺寸与纵向位置，横向按 offset 统一平移：
///   offset = progress × pointsPerProgress，pointsPerProgress = ratio × swipeMinDisplacement × 屏宽
///   source.x = sourceBase.x + offset
///   left.x   = sourceBase.x − W + offset（左邻锚定源窗口左侧一屏宽）
///   right.x  = sourceBase.x + W + offset（右邻锚定源窗口右侧一屏宽）
/// 任意 offset 下三窗次序不变，反转 / 改方向由数学自动处理。
///
/// 背景层（方案 B）用 ScreenCaptureKit 截取「排除源/左右邻/本面板后所见的屏幕」，
/// 等价于「把源窗口最小化到 Dock 后桌面剩余堆叠」，不再使用半透明黑压层。
final class SlideTransitionController {
    static let shared = SlideTransitionController()

    /// 释放后的收尾动画时长（秒）。
    private let settleDuration: TimeInterval = 0.30

    private(set) var isActive = false
    /// 当前横向位移（像素，右为正，clamp 在 ±屏宽）。供释放判定使用。
    private(set) var currentOffset: CGFloat = 0
    /// 模式（共享 SlideMode）：目标被完全覆盖 → staticSource（源恒静态，仅目标滑入）；
    /// 目标部分可见 → reveal（源 + 遮挡者滑出）。边界（目标侧无窗口）时目标为 nil，
    /// 源随手指滑动产生 wall-bump，释放回弹。

    private var sourceIsStatic = false
    private var mode: SlideMode = .staticSource
    /// 源窗口所在屏幕宽度（点）。
    var screenWidth: CGFloat { screenRect.width }

    private var panel: NSPanel?
    private var backdrop: NSView?
    /// 背景图像视图（像素诊断：采样其 presentation 透明度验证淡入是否真的渐变）。
    private var backdropImageView: NSImageView?
    /// 当前面板窗口号（像素诊断：采样面板合成输出；teardown 置 0）。
    private var panelWindowNumber: CGWindowID = 0
    private var sourceView: NSImageView?
    /// 除源窗口外的滑动视图（buried：目标图像锚定 ±屏宽滑入；reveal：遮挡者图像
    /// 锚定真实位滑出）。统一按 offset 平移。
    private struct SlidingImage {
        let view: NSImageView
        let baseX: CGFloat
        let realFrame: NSRect
    }
    private var extraSlideViews: [SlidingImage] = []

    /// 源窗口在面板本地坐标系中 offset=0 时的基准 frame。
    private var sourceBase: NSRect = .zero

    private var screenRect: NSRect = .zero
    private var pointsPerProgress: CGFloat = 1

    /// 会话代币：begin 时自增，动画/截屏完成回调仅在 token 匹配时才生效，
    /// 防止旧会话的延迟回调污染新会话。
    private var sessionToken = 0

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
        var modeLabel = ""
        var targetName = ""
        var reverseName = ""
        /// reveal 模式的遮挡者（真实 frame，面板本地坐标）。
        var occluders: [(name: String, real: NSRect)] = []
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
        guard let sourceInfo = wm.windows[sourceID],
              let sourceImage = wm.captureRawImage(for: sourceID, ownerName: sourceInfo.ownerName) else {
            logDebug("SLIDE: abort — source capture failed (id=\(sourceID))")
            return
        }

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

        // 方向/模式判别与排除集合：sign>=0 → 目标=left、反向=right；sign<0 相反。
        // 与 trackingBegan 预捕共用 SlideModeResolver，保证预捕预测与实际计算一致
        //（take 校验参数一致性，不一致则回退全新捕获）。
        let sign = initialProgress > 0 ? 1 : (initialProgress < 0 ? -1 : 0)
        let plan = SlideModeResolver.plan(wm: wm, sourceID: sourceID, leftID: leftID, rightID: rightID, sign: sign)
        mode = plan.mode
        sourceIsStatic = plan.sourceIsStatic
        let targetInfo = plan.targetID.flatMap { wm.windows[$0] }

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

        // 背景层：先放不透明黑做占位。SCK 截屏到达前必须盖住真实窗口——
        // 源窗口已从 SCK 排除但真实窗口仍停在原位，半透明占位会让滑动起点
        // 出现源窗口残像；不透明占位在 ~75ms 捕获延迟窗口内彻底遮挡。
        let bg = NSView(frame: content.bounds)
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.cgColor
        content.addSubview(bg)
        backdrop = bg

        // 源窗口图像：按真实屏幕帧摆放（居中、保留真实 y 与尺寸）。
        sourceBase = localRect(forCG: sourceInfo.frame)
        let sv = makeImageView(image: sourceImage, frame: sourceBase)
        content.addSubview(sv)
        sourceView = sv

        // 排除集 = 源 + 实际渲染的滑动窗口（reveal 遮挡者 / buried 目标）。若某遮挡者
        // 抓拍失败则不排除、保留在背景（不出现空洞）→ 与预捕计划的 excludedIDs 不一致，
        // take 判定不匹配、回退全新捕获（抓拍失败属罕见边缘，代价可接受）。
        var excludedIDs = [sourceID]
        var revealOccluders: [(name: String, real: NSRect)] = []
        if mode == .reveal {
            // REVEAL：目标部分可见 —— 目标留在背景真实位（不排除、不渲染滑动视图）；
            // 源 + 目标上方遮挡者（不含反向邻居）以真实位为基准沿跟手方向滑出。
            // 遮挡者视图置于源视图之下（源是最前置窗口）；slideOccluders 已按 back→front
            // 排序，前部遮挡者靠上、后部靠下，符合真实 z 序。
            for occ in plan.slideOccluders {
                guard let image = wm.captureRawImage(for: occ.id, ownerName: occ.name) else {
                    logDebug("SLIDE: reveal occluder capture failed id=\(occ.id) name=[\(occ.name)]")
                    continue
                }
                let real = localRect(forCG: occ.frame)
                let ov = makeImageView(image: image, frame: real)
                content.addSubview(ov, positioned: .below, relativeTo: sv)
                extraSlideViews.append(SlidingImage(view: ov, baseX: real.minX, realFrame: real))
                revealOccluders.append((name: occ.name, real: real))
                excludedIDs.append(occ.id)
            }
        } else {
            // BURIED：目标被完全覆盖 —— 目标图像从对侧滑入真实位（滑动对象=目标）；
            // 源一律静止（staticSource），反向邻居恒静态留背景。
            // 边界（目标侧无窗口，targetInfo=nil）：无目标视图，源随手指滑动产生
            // wall-bump 反馈，释放回弹到原位。
            if let info = targetInfo,
               let image = wm.captureRawImage(for: info.id, ownerName: info.ownerName) {
                let real = localRect(forCG: info.frame)
                let baseX = real.minX + (sign < 0 ? screenRect.width : -screenRect.width)
                let tv = makeImageView(image: image,
                                       frame: NSRect(x: baseX, y: real.minY, width: real.width, height: real.height))
                content.addSubview(tv)
                extraSlideViews.append(SlidingImage(view: tv, baseX: baseX, realFrame: real))
                excludedIDs.append(info.id)
            }
        }

        panel.contentView = content

        // 背景预捕消费（一次消费即清空会话）：图已就绪 → 面板弹出前平铺（零黑，
        // 根治非全屏源黑闪）；图在途 → 异步路径短等该 Direction；无匹配 → 全新捕获。
        var inflight: BackdropPreCapturer.Direction?
        var needAsyncBackdrop = true
        switch BackdropPreCapturer.shared.take(
            sourceID: sourceID, leftID: leftID, rightID: rightID,
            screenSize: screenRect.size, sign: sign,
            mode: mode, excludedIDs: excludedIDs) {
        case .ready(let image):
            applyBackdropImage(image, animate: false)
            logDebug("SLIDE: backdrop pre-captured → 直接平铺（零黑）mode=\(mode.rawValue)")
            needAsyncBackdrop = false
        case .inflight(let dir):
            inflight = dir
        case .none:
            break
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
        isActive = true

        // 首帧位移在面板可见前应用：淡入时即带正确的小位移，避免「淡入后从 0 瞬移」弹射。
        update(progress: initialProgress)

        // 淡入，缓解会话开始时的首帧跳变。
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.06
            panel.animator().alphaValue = 1
        }

        if needAsyncBackdrop {
            captureBackdrop(excluding: excludedIDs, panelWindowNumber: panel.windowNumber, inflight: inflight)
        }
        scheduleDiagSamples()

        let leftName = leftID.flatMap { wm.windows[$0]?.ownerName } ?? "nil"
        let rightName = rightID.flatMap { wm.windows[$0]?.ownerName } ?? "nil"
        let leftReal = leftID.flatMap { id in wm.windows[id].map { info in localRect(forCG: info.frame) } } ?? .zero
        let rightReal = rightID.flatMap { id in wm.windows[id].map { info in localRect(forCG: info.frame) } } ?? .zero
        logDebug("SLIDE: begin source=[\(sourceInfo.ownerName)] left=\(leftName) right=\(rightName) screen=\(Int(screenRect.width))x\(Int(screenRect.height)) ratio=\(String(format: "%.2f", ratio)) disp=\(String(format: "%.2f", disp)) mode=\(mode.rawValue) occl=\(plan.occluders.map { $0.name }.joined(separator: ","))")
        logDebug("SLIDE:DBG begin cg source=\(dbgRect(sourceInfo.frame)) left=\(leftID.flatMap { id in wm.windows[id].map { dbgRect($0.frame) } } ?? "nil") right=\(rightID.flatMap { id in wm.windows[id].map { dbgRect($0.frame) } } ?? "nil")")
        logDebug("SLIDE:DBG begin base source=\(dbgRect(sourceBase)) extra=\(extraSlideViews.map { dbgRect($0.view.frame) }.joined(separator: " | "))")

        // BGFLASH ①：会话骨架、方向/目标/反向邻居判定、桌面全量快照（前→后）。
        bgDiag.sourceID = sourceID
        bgDiag.leftID = leftID
        bgDiag.rightID = rightID
        bgDiag.sourceName = sourceInfo.ownerName
        bgDiag.leftName = leftName
        bgDiag.rightName = rightName
        bgDiag.modeLabel = mode.rawValue
        bgDiag.sourceReal = sourceBase
        bgDiag.leftReal = leftReal
        bgDiag.rightReal = rightReal
        bgDiag.targetName = sign >= 0 ? leftName : rightName
        bgDiag.reverseName = sign >= 0 ? rightName : leftName
        bgDiag.occluders = revealOccluders
        logDebug("BGFLASH:begin source=[\(bgDiag.sourceName)]@\(dbgRect(sourceInfo.frame)) left=[\(bgDiag.leftName)]@\(leftReal != .zero ? dbgRect(leftReal) : "nil") right=[\(bgDiag.rightName)]@\(rightReal != .zero ? dbgRect(rightReal) : "nil") mode=\(bgDiag.modeLabel) dir=\(sign >= 0 ? "left" : "right") target=[\(bgDiag.targetName)] reverse=[\(bgDiag.reverseName)] occl=[\(bgDiag.occluders.map { "\($0.name)@\(dbgRect($0.real))" }.joined(separator: ","))]")
        let ground = WindowManager.shared.snapshotDesktopWindows()
            .map { "[\($0.name)]@(\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width)),\(Int($0.frame.height)))" }
            .joined(separator: " ")
        logDebug("BGFLASH:ground \(ground)")
        logDebug("BGFLASH:excluded 不入背景：\(bgDiag.modeLabel == "reveal" ? "源+遮挡者" : "源+目标")（反向邻居恒静态留背景）excluded=\(excludedIDs.count)")
    }

    /// 按最新 progress 平移窗口图像。offset = SlideOffset.eased(progress)，
    /// 严格跟手、全程连续无瞬移：任何一帧的位置都由当前 progress 经软起步曲线
    /// 推导，clamp 在 ±屏宽。静态源模式下源窗口不移动。
    func update(progress: CGFloat) {
        guard isActive else { return }
        currentOffset = SlideOffset.eased(progress: progress,
                                          pointsPerProgress: pointsPerProgress,
                                          screenWidth: screenRect.width)
        applyCurrentOffset()
    }

    /// 按 currentOffset 平移源 / 额外滑动视图。
    private func applyCurrentOffset() {
        guard let sourceView else { return }
        if !sourceIsStatic {
            sourceView.setFrameOrigin(NSPoint(x: sourceBase.minX + currentOffset, y: sourceBase.minY))
        }
        for s in extraSlideViews {
            s.view.setFrameOrigin(NSPoint(x: s.baseX + currentOffset, y: s.realFrame.minY))
        }
        logDebug("SLIDE:DBG update off=\(Int(currentOffset)) src=\(dbgRect(sourceView.frame)) extra=\(extraSlideViews.map { dbgRect($0.view.frame) }.joined(separator: " | "))")
    }

    /// 释放判定后的收尾动画：commit 为 true 时沿当前 offset 方向滑满一屏，
    /// 否则滑回原位。动画完成后收起面板并回调 onComplete（受会话 token 保护）。
    /// delta = targetOffset − currentOffset，因 currentOffset 已被 clamp 且 target 为其
    /// 端点（±屏宽或 0），天然 > 0，不存在「已在满屏却 delta=0 直切」的情况。
    func settle(finalOffset: CGFloat, commit: Bool, onComplete: (() -> Void)?) {
        guard isActive, let sourceView else {
            onComplete?()
            return
        }
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
        logDebug("SLIDE:DBG settle src=\(dbgRect(sourceView.frame)) extra=\(extraSlideViews.map { dbgRect($0.view.frame) }.joined(separator: " | "))")

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
            if !sourceIsStatic {
                sourceView.animator().setFrameOrigin(NSPoint(x: sourceView.frame.minX + delta, y: sourceView.frame.minY))
            }
            for s in extraSlideViews {
                s.view.animator().setFrameOrigin(NSPoint(x: s.view.frame.minX + delta, y: s.view.frame.minY))
            }
        } completionHandler: { [weak self] in
            guard let self else { return }
            guard token == self.sessionToken else { return }
            self.finishSettle(commit: commit, onComplete: onComplete)
        }
    }

    /// 收尾：settle 滑动动画完成后收起面板。
    /// commit 时先把面板层级提到菜单栏之上（盖住真实菜单栏，使其内容切换不可见），
    /// 再回调激活目标（新菜单栏在面板下完成切换），最后面板 alpha 淡出——旧菜单栏
    /// （背景图中源 App 的菜单）随面板渐隐、真实新菜单栏渐显，消除「新菜单栏突然
    /// 出现」。回弹无内容切换，仅面板淡出平滑收起（顺带把 reveal 遮挡者的「原位
    /// 重现」由瞬切变成渐显）。
    private func finishSettle(commit: Bool, onComplete: (() -> Void)?) {
        guard let panel else {
            onComplete?()
            teardownPanel()
            isActive = false
            return
        }
        let token = sessionToken
        if commit {
            panel.level = .popUpMenu
            panel.orderFrontRegardless()
        }
        onComplete?()
        diagSample(label: "finishSettle")
        let settleFadeToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, settleFadeToken == self.sessionToken else { return }
            self.diagSample(label: "finishSettle+60ms")
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            guard token == self.sessionToken else { return }
            self.teardownPanel()
            self.isActive = false
        }
        // 兜底：淡出 completionHandler 偶发不触发（主线程被 SCK 截屏/纹理上传阻塞
        // 超淡出时长，面板滞留全屏不透明并吞掉后续手势——日志中 finishSettle 面板
        // 冻结、mean 居高不下即此现象）。0.5s 后会话仍存活且面板未收起则强制收起，
        // 保证不残留死会话。正常淡出 ~0.12-0.2s 完成、panel 置 nil，兜底自然跳过。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            guard token == self.sessionToken else { return }
            guard self.panel != nil else { return }
            logDebug("SLIDE: finishSettle fade fallback — forcing teardown (stall detected)")
            self.teardownPanel()
            self.isActive = false
        }
    }

    /// 立即终止会话（服务停止 / 被其它手势打断），不触发任何激活。
    func cancel() {
        sessionToken += 1
        teardownPanel()
        isActive = false
        currentOffset = 0
        logDebug("SLIDE: cancelled")
    }

    // MARK: - Backdrop (ScreenCaptureKit)

    /// 异步截取「排除源/左右邻/本面板后所见屏幕」作为背景层，等价于源窗口
    /// 最小化后桌面的剩余堆叠。截屏到达前以不透明黑层占位（杜绝源窗口残像），
    /// 失败则回退为近乎透明黑，让真实桌面可见。
    private func captureBackdrop(excluding windowIDs: [CGWindowID], panelWindowNumber: Int,
                                 inflight: BackdropPreCapturer.Direction?) {
        let token = sessionToken
        let scr = screenRect
        Task { @MainActor in
            // 在途预捕优先：等它完成即用（比全新 SCK 查询早发起 ~100ms，剩余时间更短）。
            if let inflight,
               let image = await BackdropPreCapturer.shared.awaitImage(inflight, timeout: 0.35) {
                guard token == self.sessionToken else { return }
                self.applyBackdropImage(image, animate: true)
                logDebug("SLIDE: backdrop via in-flight pre-capture（淡入）excluded=\(inflight.excludedCount ?? 0)")
                logDebug("SLIDE:DIAG backdrop content \(self.sampleBrightness(image))")
                return
            }
            do {
                let result = try await BackdropPreCapturer.captureDesktop(
                    size: scr.size, excluding: Set(windowIDs), panelWindowNumber: panelWindowNumber)
                guard token == self.sessionToken else { return }
                // 方案 A：背景图以 ~100ms easeOut 淡入替换硬切。不透明黑占位保留在
                // 底层（防源残像），图像视图淡入覆盖其上，消除「黑 → 桌面」硬切闪跳。
                self.applyBackdropImage(result.image, animate: true)
                // 像素诊断①：SCK 背景帧内容亮度（mean≈0 → 后期返回黑帧，坐实假设①）。
                logDebug("SLIDE:DIAG backdrop content \(self.sampleBrightness(result.image))")
                scheduleBackdropFadeSamples(token: token)
                logDebug("SLIDE: backdrop captured \(result.image.width)x\(result.image.height)px excluded=\(result.excluded.count) fadeIn=0.1")
                let excludedNames = result.excluded
                    .map { "\($0.windowID):[\($0.owningApplication?.applicationName ?? "?")]" }
                    .joined(separator: ",")
                logDebug("BGFLASH:capture excluded=[\(excludedNames)] count=\(result.excluded.count)")
            } catch {
                logDebug("SLIDE: backdrop capture failed — \(error.localizedDescription)")
                // 捕获失败：回退为近乎透明黑，让真实桌面在滑动中可见（而非不透明占位永久黑屏）。
                backdrop?.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
            }
        }
    }

    /// 背景图像视图：animate=false 时直接平铺（预捕就绪、零黑）；animate=true 时以
    /// ~100ms easeOut 从透明淡入覆盖在不透明黑占位之上（黑占位保留、防源残像）。
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

    // MARK: - 像素级诊断（仅日志，不影响行为）

    /// 采样 CGImage 亮度：缩放到 3×3 灰度网格，输出网格各点灰度 + 均值（0=纯黑，255=纯白）。
    private func sampleBrightness(_ image: CGImage) -> String {
        let n = 3
        let buf = UnsafeMutableRawPointer.allocate(byteCount: n * n, alignment: 1)
        defer { buf.deallocate() }
        guard let ctx = CGContext(data: buf, width: n, height: n,
                                  bitsPerComponent: 8, bytesPerRow: n,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return "ctx-fail"
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        let bytes = buf.assumingMemoryBound(to: UInt8.self)
        let vals = (0..<(n * n)).map { Int(bytes[$0]) }
        let mean = vals.reduce(0, +) / max(vals.count, 1)
        return "grid=[\(vals.map { String($0) }.joined(separator: ","))] mean=\(mean)"
    }

    /// 记录面板合成输出（用户实际看到的像素）+ panel/背景图 presentation 透明度。
    private func diagSample(label: String) {
        guard let panel else {
            logDebug("SLIDE:DIAG \(label) no-panel")
            return
        }
        let contentAlpha = (panel.contentView?.layer?.presentation()?.opacity).map { String(format: "%.2f", $0) } ?? "n/a"
        let bgAlpha = (backdropImageView?.layer?.presentation()?.opacity).map { String(format: "%.2f", $0) } ?? "n/a"
        var lum = "n/a"
        if let cg = WindowSwitcher_CaptureWindowImage(CGWindowID(panel.windowNumber))?.takeRetainedValue() {
            lum = sampleBrightness(cg)
        } else {
            lum = "capture-nil"
        }
        logDebug("SLIDE:DIAG \(label) contentAlpha=\(contentAlpha) bgImageAlpha=\(bgAlpha) panelLum=\(lum)")
    }

    /// 调度会话关键时刻采样（begin+30/150/400ms），复现「初期干净 vs 后期黑闪」的亮度轨迹。
    private func scheduleDiagSamples() {
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
        for (offset, label) in [(0.03, "fade+30ms"), (0.06, "fade+60ms"), (0.10, "fade+100ms")] {
            DispatchQueue.main.asyncAfter(deadline: .now() + offset) { [weak self] in
                guard let self, token == self.sessionToken else { return }
                let alpha = (self.backdropImageView?.layer?.presentation()?.opacity)
                    .map { String(format: "%.2f", $0) } ?? "n/a"
                logDebug("SLIDE:DIAG \(label) bgImageAlpha=\(alpha)")
            }
        }
    }

    // MARK: - BGFLASH 诊断

    /// 窗口是否被覆盖窗口完全包含（面板本地坐标，与坐标系原点无关）。
    private func isCovered(_ window: NSRect, by cover: NSRect) -> Bool {
        window.minX >= cover.minX && window.maxX <= cover.maxX
            && window.minY >= cover.minY && window.maxY <= cover.maxY
    }

    /// 窗口未被覆盖的暴露边描述（像素 + 方位）。
    private func exposedDescription(_ window: NSRect, by cover: NSRect) -> String {
        var parts: [String] = []
        if window.minX < cover.minX { parts.append("\(Int(cover.minX - window.minX))px(left)") }
        if window.maxX > cover.maxX { parts.append("\(Int(window.maxX - cover.maxX))px(right)") }
        if window.minY < cover.minY { parts.append("\(Int(cover.minY - window.minY))px(bottom)") }
        if window.maxY > cover.maxY { parts.append("\(Int(window.maxY - cover.maxY))px(top)") }
        return parts.isEmpty ? "none" : parts.joined(separator: ",")
    }

    /// 依据提交方向计算各滑动组/背景窗口在 teardown 后的瞬切判定。
    /// commitDirRight=true 表示右滑（目标=right），false 左滑（目标=left）。
    private func bgFlashVerdicts(commitDirRight: Bool) -> [String] {
        let targetReal = commitDirRight ? bgDiag.rightReal : bgDiag.leftReal
        let targetName = commitDirRight ? bgDiag.rightName : bgDiag.leftName
        var verdicts: [String] = []

        func check(_ name: String, staticMode: Bool, real: NSRect, why: String) {
            if staticMode {
                verdicts.append("\(name):NO-POP(\(why))")
                return
            }
            if isCovered(real, by: targetReal) {
                verdicts.append("\(name):NO-POP(被目标 \(targetName) 完全覆盖)")
            } else {
                verdicts.append("\(name):WILL-POP(\(why) exposed=\(exposedDescription(real, by: targetReal)))")
            }
        }

        // 反向邻居恒静态留背景，任何模式都不滑动、不排除。
        if bgDiag.reverseName != "nil" {
            verdicts.append("\(bgDiag.reverseName):NO-POP(反向邻居静态留背景)")
        }

        if bgDiag.modeLabel == "reveal" {
            verdicts.append("\(targetName):NO-POP(reveal 目标留背景真实位)")
            check(bgDiag.sourceName, staticMode: false, real: bgDiag.sourceReal, why: "reveal 源滑出")
            for occ in bgDiag.occluders {
                check(occ.name, staticMode: false, real: occ.real, why: "reveal 遮挡者滑出(不滑回,已接受)")
            }
        } else {
            if targetName != "nil" {
                verdicts.append("\(targetName):NO-POP(target 滑满一屏落回自身真实位)")
            }
            // buried 恒 staticSource（源不动）；边界 wall-bump 源滑动但释放回弹，同样无 POP。
            check(bgDiag.sourceName, staticMode: true, real: bgDiag.sourceReal,
                  why: "staticSource 源不动（边界 wall-bump 回弹）")
        }
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

    private func makeImageView(image: NSImage, frame: NSRect) -> NSImageView {
        let iv = NSImageView(frame: frame)
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        iv.shadow = shadow
        return iv
    }

    private func teardownPanel() {
        panel?.orderOut(nil)
        panel = nil
        backdrop = nil
        backdropImageView = nil
        panelWindowNumber = 0
        sourceView = nil
        extraSlideViews = []
        sourceBase = .zero
        sourceIsStatic = false
        mode = .staticSource
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
