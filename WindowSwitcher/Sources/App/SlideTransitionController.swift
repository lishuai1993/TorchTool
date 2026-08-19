import AppKit
import ScreenCaptureKit
import CoreImage
import CoreImage.CIFilterBuiltins

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

    /// 顶栏外观覆盖视图（源=非激活外观渐显→渐暗；目标=激活外观渐显→渐亮）。
    /// 每个覆盖视图是滑动窗口图像的子视图，随窗口移动；alpha 由 progress 驱动。
    private var titleOverlays: [NSImageView] = []

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
        // 源顶栏随手指渐暗：上叠「非激活外观」顶栏条（缓存优先，缺则亮度合成）。
        attachTitleOverlay(to: sv, windowID: sourceID, currentCapture: sourceImage, want: .inactive)

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
                // 目标顶栏随手指渐亮：上叠「激活外观」顶栏条。
                attachTitleOverlay(to: tv, windowID: info.id, currentCapture: image, want: .active)
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
            // 预捕图就绪即同步喂菜单覆盖条：材质（模糊）+ 源文字（清晰裁剪）都取自
            // 同一张整屏图，避免预捕路径下覆盖条停留在占位透明态、源菜单不随手指渐隐。
            applyMenuBarContent(from: image)
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

        // 顶部菜单栏覆盖条（level 25）：材质背景 + AX 自绘源/目标菜单文字随手指交叉淡化。
        let sourcePID = sourceInfo.ownerPid
        let targetPID = plan.targetID.flatMap { wm.windows[$0]?.ownerPid }
        createMenuCover(sourcePID: sourcePID, targetPID: targetPID)

        // 首帧位移在面板可见前应用：淡入时即带正确的小位移，避免「淡入后从 0 瞬移」弹射。
        update(progress: initialProgress)

        // 淡入，缓解会话开始时的首帧跳变。
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.06
            panel.animator().alphaValue = 1
        }

        if needAsyncBackdrop {
            captureBackdrop(excluding: excludedIDs, panelWindowNumber: panel.windowNumber,
                            coverWindowNumber: menuCoverPanel?.windowNumber, inflight: inflight)
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
        applyTitleOverlays()
        applyMenuCover()
    }

    /// 顶栏外观覆盖层 alpha = 归一化位移（随手指渐暗/渐亮，折返逆转）。
    private func applyTitleOverlays() {
        guard !titleOverlays.isEmpty else { return }
        let tp = min(1, max(0, abs(currentOffset) / max(screenRect.width, 1)))
        for ov in titleOverlays { ov.alphaValue = tp }
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
            // 顶栏覆盖层：提交→补满（渐暗/渐亮到位）；回弹→归零（源顶栏/菜单还原）。
            for ov in titleOverlays {
                ov.animator().alphaValue = commit ? 1 : 0
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
    /// 回弹无内容切换，仅面板淡出平滑收起（顺带把 reveal 遮挡者的「原位重现」
    /// 由瞬切变成渐显）。
    private func finishSettle(commit: Bool, onComplete: (() -> Void)?) {
        guard let panel else {
            onComplete?()
            teardownPanel()
            isActive = false
            return
        }
        let token = sessionToken
        onComplete?()
        diagSample(label: "finishSettle")
        let settleFadeToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, settleFadeToken == self.sessionToken else { return }
            self.diagSample(label: "finishSettle+60ms")
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
                                 coverWindowNumber: Int?, inflight: BackdropPreCapturer.Direction?) {
        let token = sessionToken
        let scr = screenRect
        Task { @MainActor in
            // 在途预捕优先：等它完成即用（比全新 SCK 查询早发起 ~100ms，剩余时间更短）。
            if let inflight,
               let image = await BackdropPreCapturer.shared.awaitImage(inflight, timeout: 0.35) {
                guard token == self.sessionToken else { return }
                self.applyBackdropImage(image, animate: true)
                self.applyMenuBarContent(from: image)
                logDebug("SLIDE: backdrop via in-flight pre-capture（淡入）excluded=\(inflight.excludedCount ?? 0)")
                logDebug("SLIDE:DIAG backdrop content \(self.sampleBrightness(image))")
                return
            }
            do {
                var excl = Set(windowIDs)
                if let coverWindowNumber { excl.insert(CGWindowID(coverWindowNumber)) }
                let result = try await BackdropPreCapturer.captureDesktop(
                    size: scr.size, excluding: excl, panelWindowNumber: panelWindowNumber)
                guard token == self.sessionToken else { return }
                // 方案 A：背景图以 ~100ms easeOut 淡入替换硬切。不透明黑占位保留在
                // 底层（防源残像），图像视图淡入覆盖其上，消除「黑 → 桌面」硬切闪跳。
                self.applyBackdropImage(result.image, animate: true)
                self.applyMenuBarContent(from: result.image)
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
        titleOverlays = []
        sourceBase = .zero
        sourceIsStatic = false
        mode = .staticSource
        menuCoverPanel?.orderOut(nil)
        menuCoverPanel = nil
        menuBackgroundView = nil
        sourceMenuImageView = nil
        targetMenuImageView = nil
    }

    /// 顶栏覆盖层要模拟的外观。源=非激活（随手指渐暗）；目标=激活（随手指渐亮）。
    private enum TitleAppearance {
        case active
        case inactive
    }

    /// 上叠顶栏外观覆盖视图：缓存外观条优先（真外观，交叉溶解保真度高），缺失则用
    /// 亮度合成回退（目标≈调亮、源≈调暗去饱和）。overlay 初始 alpha=0，随手指
    /// progress 渐显（applyTitleOverlays 驱动）。
    private func attachTitleOverlay(to parentView: NSImageView, windowID: CGWindowID,
                                    currentCapture: NSImage?, want: TitleAppearance) {
        let strip = WindowManager.shared.appearanceStrip(windowID: windowID, active: want == .active)
            ?? synthesizedTitleStrip(from: currentCapture, want: want, width: parentView.frame.width)
        guard let strip else {
            logDebug("SLIDE: title overlay skip win=\(windowID) want=\(want == .active ? "active" : "inactive")")
            return
        }
        let h = strip.size.height
        let ov = NSImageView(frame: NSRect(x: 0, y: parentView.frame.height - h,
                                           width: parentView.frame.width, height: h))
        ov.image = strip
        ov.imageScaling = .scaleAxesIndependently
        ov.wantsLayer = true
        ov.alphaValue = 0
        parentView.addSubview(ov)
        titleOverlays.append(ov)
    }

    /// 亮度合成顶栏条（外观缓存缺失时的回退）：截取当前捕获图的顶部条，目标=调亮、
    /// 源=调暗 + 去饱和（近似非激活灰）。非精确外观，仅保渐变节奏。
    private func synthesizedTitleStrip(from image: NSImage?, want: TitleAppearance, width: CGFloat) -> NSImage? {
        guard let image,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let h = min(image.size.height, WindowManager.titleBarHeightPoints)
        let scale = CGFloat(cg.height) / max(image.size.height, 1)
        let stripPx = max(Int(h * scale), 1)
        guard let stripCg = cg.cropping(to: CGRect(x: 0, y: 0,
                                                   width: CGFloat(cg.width), height: CGFloat(stripPx))) else { return nil }
        let filter = CIFilter.colorControls()
        filter.inputImage = CIImage(cgImage: stripCg)
        filter.saturation = want == .active ? 1.05 : 0.15
        filter.brightness = want == .active ? 0.16 : -0.22
        guard let out = filter.outputImage else { return nil }
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        guard let result = ctx.createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: width, height: h))
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
