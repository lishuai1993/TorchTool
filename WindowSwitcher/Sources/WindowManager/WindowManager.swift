import AppKit
import CoreGraphics

final class WindowManager: @unchecked Sendable {
    static let shared = WindowManager()

    let orderingEngine = LRUOrderingEngine()
    let activationHistory = ActivationHistory()
    let activationSuppressor = ActivationSuppressor()
    let axFocusObserver = AXFocusObserver()
    private let axMatcher = AXWindowMatcher.shared
    private let thumbCapturer = ThumbnailCapturer.shared

    /// 顶栏外观条高度（点）。仅用于「激活/非激活顶栏」交叉溶解的覆盖条裁剪，
    /// 覆盖标准标题栏 + 统一工具栏区域；自定义顶栏可目测微调。
    static let titleBarHeightPoints: CGFloat = 36

    /// 真实菜单栏高度（点）。实测非刘海屏/刘海屏 MacBook 均为 37pt（非
    /// NSStatusBar.system.thickness 的 22）。菜单栏覆盖条（level 25）用它定位与定高。
    static let menuBarHeightPoints: CGFloat = 37

    /// 窗口顶栏外观缓存（激活/非激活，裁剪自捕获图的顶部条，内存小）。
    /// captureRawImage 捕获源/目标时按 frontmost 状态填充；滑动过渡 begin() 读取
    /// 对立外观做顶栏渐暗/渐亮交叉溶解。随 refreshWindows 清理失效窗口。
    struct WindowAppearances {
        var active: CGImage?
        var inactive: CGImage?
    }
    private(set) var appearanceCache: [CGWindowID: WindowAppearances] = [:]

    /// Current snapshot of visible windows, keyed by CGWindowID.
    var windows: [CGWindowID: WindowInfo] = [:]

    /// Windows in LRU order (convenience for display reconstruction).
    var orderedWindows: [WindowInfo] {
        orderingEngine.orderedIDs.compactMap { windows[$0] }
    }

    /// Current frontmost window ID.
    private(set) var frontmostWindowID: CGWindowID?

    /// IDs ever seen by sync, to distinguish a genuinely new window from a
    /// re-detection of a window that merely dropped out of the on-screen
    /// snapshot (minimized / occluded / other Space).
    private var knownWindowIDs: Set<CGWindowID> = []

    private var scrollMonitor: Any?
    private var interactionMonitor: Any?

    /// Cmd+` event tap. NSEvent.addGlobalMonitorForEvents does not deliver
    /// Cmd+` — WindowServer consumes it for the app switcher first — so a
    /// listen-only CGEventTap at the session level is used instead.
    /// `fileprivate` so the file-scoped C callback can re-enable it.
    fileprivate var keyEventTap: CFMachPort?
    private var keyEventTapSource: CFRunLoopSource?
    /// Diagnostic counter to confirm the tap actually receives key events.
    private var keyEventCount = 0
    /// Tap registration retry budget. CGEvent.tapCreate can transiently return
    /// nil at app launch even when AXIsProcessTrusted() is true, so retry a few
    /// times with a short delay.
    private var keyEventTapRetries = 0
    private let keyEventTapMaxRetries = 5

    /// Cmd+` debounce state: the flag marks a pending key-down so the key-up
    /// (window cycle settled) can query immediately; the work item is the
    /// debounced fallback in case no key-up arrives.
    private var cmdBacktickPending = false
    private var cmdBacktickWorkItem: DispatchWorkItem?

    /// Scroll-gesture state machine. A single trackpad scroll gesture
    /// (began → … → ended) promotes the frontmost window to the LRU head
    /// exactly once; the dedup flag is re-armed on the next gesture.
    private var scrollGestureActive = false
    private var scrollDidTriggerReorder = false
    private var lastScrollReorderTime: TimeInterval = 0

    /// 延迟滚动重排状态：三指横滑自身的 scrollWheel 可能先于 C 引擎确认三指
    /// 跟踪到达（事件二竞态）。滚动守卫通过后先挂起 ~250ms，若期间滑动会话
    /// 开始 / 跟踪确认，延迟任务触发时取消，避免滑动自身污染 LRU。
    private var pendingScrollReorderWorkItem: DispatchWorkItem?
    private var pendingScrollReorderFrontID: CGWindowID?

    /// 最近一次滑动会话开始时刻（systemUptime）。延迟重排触发时若在 ~500ms 内
    /// 有会话开始（即便已快速结束、gesturePhase 已回落），判定该 scroll 为滑动
    /// 产物，取消重排。
    var lastSlideSessionStartAt: TimeInterval = 0

    /// Timestamp (systemUptime) of the last three-finger gesture end. Residual
    /// scrollWheel events arrive ~200-400ms after a three-finger swipe; the
    /// scroll monitor ignores them for a short immunity window.
    var lastGestureEndAt: TimeInterval = 0

    /// Callback invoked when a window receives substantial interaction.
    var onInteraction: ((CGWindowID) -> Void)?

    /// Callback invoked on trackpad scroll/swipe events.
    var onTrackpadActivity: (() -> Void)?

    /// The current gesture/interaction phase, driven by AppDelegate.
    /// Scroll events are treated as gesture artifacts (and do NOT trigger
    /// windowDidInteract) only while quickSwitching or elasticDragging.
    var gesturePhase: GesturePhase = .idle

    /// Per-app z-ordered window list (CGWindowID + frame) from the most recent
    /// refresh, in CGWindowList order (frontmost first). Used to correlate a
    /// target CGWindowID to the matching AX element by z-order rank, since
    /// AX kAXWindows order mirrors the window-server z-order.
    private(set) var appZOrder: [pid_t: [(id: CGWindowID, frame: CGRect)]] = [:]

    /// Delegate thumbnail capture to the extracted capturer.
    func captureRawImage(for windowID: CGWindowID, ownerName: String = "?") -> NSImage? {
        let image = thumbCapturer.captureRawImage(for: windowID, ownerName: ownerName)
        recordAppearance(windowID: windowID, image: image)
        return image
    }

    /// 记录该窗口当前外观的顶栏条到缓存（源=激活、其余=非激活）。
    /// 仅裁剪顶部条（内存小），供滑动过渡做顶栏渐暗/渐亮交叉溶解。
    private func recordAppearance(windowID: CGWindowID, image: NSImage?) {
        guard let image,
              let info = windows[windowID],
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let scale = CGFloat(cg.height) / max(info.frame.height, 1)
        let stripPx = max(Int(WindowManager.titleBarHeightPoints * scale), 1)
        guard let strip = cg.cropping(to: CGRect(x: 0, y: 0,
                                                 width: CGFloat(cg.width), height: CGFloat(stripPx))) else { return }
        var entry = appearanceCache[windowID] ?? WindowAppearances()
        if windowID == frontmostWindowID {
            entry.active = strip
        } else {
            entry.inactive = strip
        }
        appearanceCache[windowID] = entry
    }

    /// 读取某窗口的顶栏外观条（点尺寸），供滑动过渡覆盖层使用。缓存缺失返回 nil，
    /// 调用方回退亮度合成。
    func appearanceStrip(windowID: CGWindowID, active: Bool) -> NSImage? {
        guard let entry = appearanceCache[windowID],
              let cg = active ? entry.active : entry.inactive else { return nil }
        let scale = CGFloat(cg.height) / max(WindowManager.titleBarHeightPoints, 1)
        let wPt = CGFloat(cg.width) / scale
        return NSImage(cgImage: cg, size: NSSize(width: wPt, height: WindowManager.titleBarHeightPoints))
    }
    func preloadThumbnails(count: Int) { thumbCapturer.preloadThumbnails(count: count) }
    func setThumbnail(_ image: NSImage, for windowID: CGWindowID) {
        thumbCapturer.setThumbnail(image, for: windowID)
    }
    func clearThumbnailCache() { thumbCapturer.clearCache() }

    /// Guard flag to prevent event tap / activation notification from
    /// reordering the list during programmatic window activation.
    private var isActivating = false

    private init() {
        activationHistory.onAppActivated = { [weak self] pid in
            guard let self, !self.isActivating else { return }
            // Never observe our own process. When WindowSwitcher becomes
            // frontmost (e.g. the immersive overlay is shown), keep the previous
            // app's observer armed so window switches are still captured when
            // the user returns — otherwise the observer is hijacked to a pid
            // that produces no events and same-app switches go undetected.
            if pid == NSRunningApplication.current.processIdentifier {
                logDebug("ActivationHistory: ignoring self activation pid=\(pid)")
                return
            }
            // Suppress the notification caused by our own programmatic
            // app.activate() (delivered asynchronously after isActivating reset).
            if self.activationSuppressor.shouldSuppress(pid: pid) {
                logDebug("ActivationHistory: suppressed programmatic activation pid=\(pid)")
                // The suppressed PID is the app we just activated — re-arm the
                // observer to it so subsequent same-app window switches are
                // captured. Without this the observer stays on whatever app was
                // observed last (often WindowSwitcher itself) and goes blind.
                self.axFocusObserver.startObserving(pid: pid)
                return
            }
            // Real user activation (Cmd+Tab, Dock click) — record focus
            // but do NOT reorder. Only substantial interaction (click/type)
            // triggers windowDidInteract → reorder.
            if let topWindowID = self.orderingEngine.orderedIDs.first(where: { id in
                self.windows[id]?.ownerPid == pid
            }) {
                self.orderingEngine.windowDidFocus(topWindowID)
            }
            // Refresh the frontmost-window cache so the event tap's
            // windowDidInteract reorders the window the user is ACTUALLY in.
            // Validate against the canonical window list to avoid storing an ID
            // from a stale snapshot that may have been filtered out by parseWindow.
            if let front = self.frontmostWindow(for: pid), windows[front] != nil {
                self.frontmostWindowID = front
            } else if frontmostWindowID == nil || windows[frontmostWindowID!] == nil {
                self.frontmostWindowID = orderingEngine.orderedIDs.first
            }
            // Start observing same-app focused-window changes for the new app.
            self.axFocusObserver.startObserving(pid: pid)
        }

        axFocusObserver.onFocusChanged = { [weak self] pid in
            self?.handleAXFocusChange(pid: pid)
        }
    }

    // MARK: - Window enumeration

    /// Refresh the window list from the system.
    func refreshWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements,
        ]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else {
            logDebug("WindowManager: CGWindowListCopyWindowInfo returned nil")
            return []
        }

        var newWindows: [CGWindowID: WindowInfo] = [:]
        var orderedIDs: [CGWindowID] = []

        for dict in list {
            guard let info = parseWindow(dict) else { continue }
            newWindows[info.id] = info
            orderedIDs.append(info.id)
        }

        // Cache the per-app z-order snapshot (frontmost first) for correlating
        // a target CGWindowID to its AX element by rank.
        var zOrderByPid: [pid_t: [(id: CGWindowID, frame: CGRect)]] = [:]
        for id in orderedIDs {
            guard let info = newWindows[id] else { continue }
            zOrderByPid[info.ownerPid, default: []].append((id, info.frame))
        }
        appZOrder = zOrderByPid

        // Backfill real titles from AX for apps whose CGWindowList title is
        // empty (e.g. Chrome), correlated by frame / z-order rank.
        axMatcher.backfillTitles(&newWindows, appZOrder: appZOrder)

        let oldWindows = windows
        windows = newWindows
        appearanceCache = appearanceCache.filter { newWindows[$0.key] != nil }
        logSyncChangeDiagnostics(oldIDs: orderingEngine.orderedIDs, newIDs: orderedIDs,
                                 oldWindows: oldWindows, newWindows: newWindows,
                                 newOrder: orderedIDs)

        // Detect same-app "removed + added" pairs: a window rebuilt under a new
        // CGWindowID (e.g. a terminal tab change). The rebuild must inherit the
        // old window's LRU position rather than being prepended to the head.
        let oldSet = Set(orderingEngine.orderedIDs)
        let newSet = Set(orderedIDs)
        var rebuildMap: [CGWindowID: CGWindowID] = [:]
        for removedID in oldSet.subtracting(newSet) {
            guard let oldInfo = oldWindows[removedID] else { continue }
            if let addedID = newSet.subtracting(oldSet).first(where: { id in
                guard let info = newWindows[id] else { return false }
                return info.ownerPid == oldInfo.ownerPid
                    && WindowManager.frameMatches(info.frame, oldInfo.frame, tolerance: 80)
            }) {
                rebuildMap[addedID] = removedID
            }
        }
        if !rebuildMap.isEmpty {
            logDebug("SYNC-DIAG: rebuild pairs detected (inheriting LRU position): "
                     + rebuildMap.map { "\($0.value)→\($0.key)" }.joined(separator: ", "))
        }
        orderingEngine.sync(windowIDs: orderedIDs, rebuildMap: rebuildMap)

        // Populate window name lookup for LRU diagnostics
        for (id, info) in newWindows {
            let title = info.windowTitle.isEmpty ? "" : " — \(info.windowTitle)"
            orderingEngine.windowNames[id] = "\(info.ownerName)\(title)"
        }

        // Update frontmost if stale — but don't clobber a fresher value set
        // by handleAXFocusChange or activateWindow between refreshes.
        if let front = orderedIDs.first {
            if frontmostWindowID == nil || windows[frontmostWindowID!] == nil {
                frontmostWindowID = front
            }
            orderingEngine.windowDidFocus(front)
        }

        logDebug("WindowManager: refreshed \(orderedIDs.count) windows")
        return orderedIDs.compactMap { newWindows[$0] }
    }

    /// BGFLASH 诊断专用：只读快照当前屏上窗口（CGWindowList 前→后顺序），
    /// 复用 parseWindow 的过滤（排除自身 pid、排除 bundle、w/h≥100）。
    /// 不触碰 LRU/ordering、不触发任何同步，**禁止**在滑动会话期间调用
    /// refreshWindows（会重排 LRU），用本函数取桌面快照。
    func snapshotDesktopWindows() -> [(id: CGWindowID, name: String, frame: CGRect)] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else {
            return []
        }
        var result: [(id: CGWindowID, name: String, frame: CGRect)] = []
        for dict in list {
            guard let info = parseWindow(dict) else { continue }
            result.append((info.id, info.ownerName, info.frame))
        }
        return result
    }

    /// 2.3 遮挡计算：目标窗口上方（z 序在前）且与目标 frame 相交的普通窗口。
    /// 过滤 layer==0、alpha>0.5（parseWindow 已排除自身 pid/排除 bundle/w<h<100）。
    /// 返回前→后顺序，供滑动过渡判定「目标被完全覆盖（buried）或部分可见（reveal）」。
    /// 只读，不触碰 LRU/ordering，禁止在滑动会话期间用于任何重排。
    func occluders(aboveTarget targetID: CGWindowID, frame: CGRect)
        -> [(id: CGWindowID, name: String, frame: CGRect)] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else {
            return []
        }
        var result: [(id: CGWindowID, name: String, frame: CGRect)] = []
        var passedTarget = false
        for dict in list {
            guard let info = parseWindow(dict) else { continue }
            if info.id == targetID { passedTarget = true; continue }
            if passedTarget { break }  // 目标之后的窗口不再遮挡它
            guard let layer = dict[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = dict[kCGWindowAlpha as String] as? Double, alpha > 0.5
            else { continue }
            if info.frame.intersects(frame) {
                result.append((info.id, info.ownerName, info.frame))
            }
        }
        return result
    }

    func activateWindow(_ windowID: CGWindowID) {
        isActivating = true
        defer { isActivating = false }

        guard let info = windows[windowID] else {
            logDebug("WindowManager: activateWindow - window \(windowID) not found")
            return
        }

        // Step 1: Resolve the application
        let app: NSRunningApplication?
        if let bid = info.ownerBundleID, !bid.isEmpty,
           let a = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            app = a
        } else {
            app = NSRunningApplication(processIdentifier: info.ownerPid)
        }
        guard let app = app else {
            logDebug("WindowManager: activateWindow - app not found for \(info.ownerName)")
            return
        }
        let needsActivate = !app.isActive
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        logDebug("ACTIVATE-DIAG: [\(info.ownerName)] pid=\(app.processIdentifier) bid=\(app.bundleIdentifier ?? "nil") isActive=\(app.isActive) needsActivate=\(needsActivate) frontmostBefore=\(frontmostBefore) window=\(windowID)")

        // Step 2: Raise the specific window via Accessibility API.
        // Do this BEFORE activation so the app comes to front already showing
        // the correct window, avoiding a flash of a different window first.
        let snapshots = axMatcher.enumerateAXWindows(forPid: info.ownerPid)
        if !snapshots.isEmpty {
            logDebug("AX: \(info.ownerName) has \(snapshots.count) AX windows, target=[\(info.windowTitle)] frame=\(info.frame)")

            // Build index-keyed info for selectAXWindow
            var axWindowsInfo: [(index: Int, title: String, frame: CGRect)] = []
            for (idx, s) in snapshots.enumerated() {
                logDebug("AX:   [\(idx)][\(s.title)] frame=\(s.frame)")
                axWindowsInfo.append((idx, s.title, s.frame))
            }

            // Select the AX element that corresponds to the EXACT target window:
            // frame group first, then z-order rank within the group.
            let selected = axMatcher.selectAXWindow(
                for: windowID,
                pid: info.ownerPid,
                frame: info.frame,
                title: info.windowTitle,
                axWindows: axWindowsInfo,
                appZOrder: appZOrder
            )

            if let sel = selected, sel.index >= 0 && sel.index < snapshots.count {
                AXUIElementPerformAction(snapshots[sel.index].element, kAXRaiseAction as CFString)
                logDebug("AX: raised [\(info.ownerName)] idx=\(sel.index) title=\"\(sel.title)\"")
                axMatcher.scheduleMappingCheck(pid: info.ownerPid, expectedTitle: sel.title, windowID: windowID)
            } else {
                logDebug("AX: NO MATCH for [\(info.ownerName) — \(info.windowTitle)]")
            }
        } else {
            logDebug("AX: failed to get windows for \(info.ownerName)")
        }

        // Step 3: Activate the application if not already frontmost.
        // Done AFTER raising so the correct window is shown immediately,
        // avoiding a flash of a different window appearing first.
        if needsActivate {
            logDebug("ACTIVATE-DIAG: calling app.activate() for [\(info.ownerName)] pid=\(app.processIdentifier)")
            activationSuppressor.recordActivation(pid: app.processIdentifier)
            let activateResult = app.activate()
            logDebug("ACTIVATE-DIAG: app.activate() returned \(activateResult) for [\(info.ownerName)]")
            // Ground-truth: did the app actually become frontmost?
            let pid = app.processIdentifier
            let name = info.ownerName
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let frontmostAfter = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                let activeNow = NSRunningApplication(processIdentifier: pid)?.isActive ?? false
                logDebug("ACTIVATE-DIAG: after 300ms frontmost=\(frontmostAfter) [\(name)] isActiveNow=\(activeNow)")
            }
        } else {
            logDebug("ACTIVATE-DIAG: skipping app.activate() (already active or needsActivate=false) for [\(info.ownerName)]")
        }

        frontmostWindowID = windowID
        let idxBefore = orderingEngine.index(of: windowID)
        orderingEngine.userDidSelectWindow(windowID)
        logDebug("ACTIVATE-DONE: window=\(info.ownerName) — \(info.windowTitle) idx=\(idxBefore.map(String.init(describing:)) ?? "nil") cursorAfter=\(orderingEngine.orderedIDs.firstIndex(of: windowID).map(String.init(describing:)) ?? "nil") orderedIDs[0]=\(orderingEngine.windowNames[orderingEngine.orderedIDs.first!] ?? "?") isActivating=\(isActivating)")
    }

    // MARK: - Interaction monitoring

    func startInteractionMonitoring() -> Bool {
        activationHistory.start()

        // Reset scroll-gesture state in case monitoring was stopped mid-gesture.
        scrollGestureActive = false
        scrollDidTriggerReorder = false
        lastScrollReorderTime = 0

        // Scroll monitor: trackpad activity watchdog + MRU-gated reorder.
        // Gate: interaction is only meaningful for a window that is NOT already
        // the LRU head (most-recently-active). For such a window, the first
        // effective vertical scroll event — slow or fast — is treated as a real
        // user interaction and promotes it to the LRU head. Once it is at the
        // head, promotion is idempotent, so further interactions short-circuit.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return }
            self.onTrackpadActivity?()

            // Skip the inertial (momentum) phase: it is a physical continuation
            // of the previous gesture, not a fresh user input.
            guard event.momentumPhase.isEmpty else { return }

            // Track the scroll-gesture lifecycle to deduplicate one gesture.
            switch event.phase {
            case .began:
                self.scrollGestureActive = true
                self.scrollDidTriggerReorder = false
            case .ended, .cancelled:
                self.scrollGestureActive = false
            case .changed:
                if !self.scrollGestureActive {
                    self.scrollGestureActive = true
                    self.scrollDidTriggerReorder = false
                }
            default: break
            }

            // Block: three-finger gesture in progress (its scrollWheel is the
            // gesture's own artifact, not a real user interaction) / programmatic
            // activation / no known front window. Query the C engine synchronously
            // so the swipe's scroll is blocked from the touchdown frame — no race
            // with the Swift-side gesturePhase, which updates asynchronously.
            guard !self.gesturePhase.interceptsScroll,
                  !gesture_engine_is_tracking(),
                  !self.isActivating,
                  let frontID = self.frontmostWindowID else { return }

            // MRU gate: if the frontmost window is already the LRU head, any
            // reorder would be a no-op — short-circuit before processing.
            if frontID == self.orderingEngine.orderedIDs.first { return }

            // Residual-swipe guard: within ~600ms after a three-finger gesture
            // ends, the system delivers leftover scrollWheel events from that
            // swipe (observed arriving at 410-490ms). Treat them as artifacts
            // and never reorder. Beyond the window any-direction scroll is a
            // real user interaction — vertical page scroll, or horizontal
            // page-turn (e.g. 微信读书 双指左右滑动翻页) — and triggers a reorder.
            if ProcessInfo.processInfo.systemUptime - self.lastGestureEndAt < 0.6 {
                return
            }

            // Deduplicate: one gesture triggers exactly one reorder. The time
            // window also backs up phase-less devices (e.g. external mouse
            // wheels), where .began/.ended never fire, so a fresh scroll after
            // a pause re-arms the trigger.
            let now = ProcessInfo.processInfo.systemUptime
            if self.scrollDidTriggerReorder {
                guard now - self.lastScrollReorderTime > 0.5 else { return }
                self.scrollDidTriggerReorder = false
            }

            // 延迟提交重排：三指横滑自身的 scrollWheel 可能先于 C 引擎确认跟踪
            // 到达（事件二竞态）。守卫通过后挂起 ~250ms，延迟任务触发时若检测到
            // 滑动已开始 / 跟踪确认 / 前窗已变化，则取消，避免滑动自身污染 LRU。
            self.schedulePendingScrollReorder(frontID: frontID)
        }

        // Interaction monitor: clicks on windows trigger reorder. Gated the same
        // way as scroll — a click on an already-MRU window is a no-op.
        interactionMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self,
                  let frontID = self.frontmostWindowID,
                  !self.isActivating,
                  frontID != self.orderingEngine.orderedIDs.first else { return }
            self.orderingEngine.windowDidInteract(frontID)
            self.onInteraction?(frontID)
        }

        // Cmd+` global key monitor: the only reliable trigger for same-app
        // window switches. kAXFocusedWindowChangedNotification stops being
        // delivered after the first switch per observer registration (Chrome)
        // or never fires (Obsidian), so a key event drives an explicit AX
        // re-query instead of relying on the notification.
        registerKeyEventTap()

        logDebug("WindowManager: NSEvent monitors registered OK")
        return true
    }

    /// 挂起滚动触发的 LRU 重排（延迟 ~250ms）。触发时若检测到三指手势已开始 /
    /// 跟踪确认 / 前窗已变化 / 仍处手势残流免疫窗，则判定该 scroll 为滑动产物，
    /// 取消重排，避免滑动自身污染 LRU。
    private func schedulePendingScrollReorder(frontID: CGWindowID) {
        guard pendingScrollReorderWorkItem == nil else { return }  // 已有待处理，防重复
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingScrollReorderWorkItem = nil
            let scheduledID = self.pendingScrollReorderFrontID
            self.pendingScrollReorderFrontID = nil

            // 滑动自身 scroll：C 引擎已确认跟踪 / Swift 手势阶段拦截 / 最近 500ms
            // 内有会话开始（即便已快速结束、phase 已回落）→ 一律取消。
            if gesture_engine_is_tracking()
                || self.gesturePhase.interceptsScroll
                || ProcessInfo.processInfo.systemUptime - self.lastSlideSessionStartAt < 0.5 {
                return
            }
            // 前窗已变化（被点击/滑动接管）→ 原重排已过时；MRU 门短路亦跳过。
            guard let scheduledID, scheduledID == self.frontmostWindowID,
                  !self.isActivating,
                  scheduledID != self.orderingEngine.orderedIDs.first else { return }
            // 手势残流免疫窗内同样不重排。
            if ProcessInfo.processInfo.systemUptime - self.lastGestureEndAt < 0.6 { return }

            let fireNow = ProcessInfo.processInfo.systemUptime
            self.scrollDidTriggerReorder = true
            self.lastScrollReorderTime = fireNow
            logDebug("SCROLL-MON: → windowDidInteract(\(scheduledID)) name=\(self.orderingEngine.windowNames[scheduledID] ?? "?")")
            self.orderingEngine.windowDidInteract(scheduledID)
            self.onInteraction?(scheduledID)
        }
        pendingScrollReorderWorkItem = item
        pendingScrollReorderFrontID = frontID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    /// 取消待处理的滚动重排（滑动会话开始时调用）。
    func cancelPendingScrollReorder() {
        pendingScrollReorderWorkItem?.cancel()
        pendingScrollReorderWorkItem = nil
        pendingScrollReorderFrontID = nil
    }

    /// 记录滑动会话开始时刻并取消待处理滚动重排（AppDelegate 会话开启时调用）。
    func noteSlideSessionBegan() {
        lastSlideSessionStartAt = ProcessInfo.processInfo.systemUptime
        cancelPendingScrollReorder()
    }

    /// 三指落地（trackingBegan）时启动双方向背景预捕。先刷新窗口列表：滑动会话
    /// begin（beginSlideSessionIfNeeded）同样先 refreshWindows 再取源/左右邻，预捕若不
    /// 刷新，两次刷新之间发生的窗口重建/增删会让 take 参数不匹配、回退全新捕获
    ///（正是首次滑动黑闪的根因）。刷新会同步 LRU，但本函数在会话 begin 前调用
    ///（trackingBegan，尚无滑动会话），不违反「滑动会话期间禁刷新」约束。
    /// 门控（滑动过渡开启等）由 AppDelegate 负责。
    func beginBackdropPreCapture() {
        _ = refreshWindows()
        guard let sourceID = frontmostWindowID,
              let idx = orderingEngine.index(of: sourceID),
              let sourceInfo = windows[sourceID],
              orderingEngine.orderedIDs.count > 1 else { return }
        let ids = orderingEngine.orderedIDs
        let leftID = idx > 0 ? ids[idx - 1] : nil
        let rightID = idx + 1 < ids.count ? ids[idx + 1] : nil
        guard let screen = SlideGeometry.screen(containingCGFrame: sourceInfo.frame, screens: NSScreen.screens) else {
            logDebug("SLIDE: pre-capture abort — no screen for source")
            return
        }
        let leftName = leftID.flatMap { orderingEngine.windowNames[$0] } ?? "nil"
        let rightName = rightID.flatMap { orderingEngine.windowNames[$0] } ?? "nil"
        logDebug("SLIDE: pre-capture begin source=[\(sourceInfo.ownerName)] left=\(leftName) right=\(rightName) screen=\(Int(screen.frame.width))x\(Int(screen.frame.height))")
        BackdropPreCapturer.shared.start(sourceID: sourceID, leftID: leftID, rightID: rightID,
                                         screenSize: screen.frame.size)
    }

    func stopInteractionMonitoring() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        if let m = interactionMonitor { NSEvent.removeMonitor(m); interactionMonitor = nil }
        if let tap = keyEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = keyEventTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
                keyEventTapSource = nil
            }
            keyEventTap = nil
        }
        cmdBacktickWorkItem?.cancel()
        cmdBacktickWorkItem = nil
        cmdBacktickPending = false
        axFocusObserver.stopObserving()
        activationHistory.stop()
        logDebug("WindowManager: interaction monitoring stopped")
    }

    // MARK: - AX delegates (thin wrappers for external callers)

    func enumerateAXWindows(forPid pid: pid_t) -> [AXWindowSnapshot] {
        axMatcher.enumerateAXWindows(forPid: pid)
    }

    static func frameMatches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 10) -> Bool {
        AXWindowMatcher.frameMatches(a, b, tolerance: tolerance)
    }

    // MARK: - Private

    /// Called by AXFocusObserver when the focused AX window changes within the
    /// same app. Queries the AX focused window's title & frame, matches it to
    /// a known CGWindowID, and updates frontmostWindowID + LRU ordering.
    private func handleAXFocusChange(pid: pid_t) {
        guard !isActivating else {
            logDebug("AXFocusChange: suppressed (isActivating)")
            return
        }

        let app = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard r == .success, let fw = focusedWindow else {
            logDebug("AXFocusChange: no focused window for pid=\(pid), err=\(r.rawValue)")
            return
        }
        let axWindow = fw as! AXUIElement

        var axTitleVal: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &axTitleVal)
        let axTitle = (axTitleVal as? String) ?? ""

        var axPos: CFTypeRef?, axSize: CFTypeRef?
        var axFrame = CGRect.zero
        AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &axPos)
        AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &axSize)
        if let pv = axPos { AXValueGetValue(pv as! AXValue, .cgPoint, &axFrame.origin) }
        if let sv = axSize { AXValueGetValue(sv as! AXValue, .cgSize, &axFrame.size) }

        logDebug("AXFocusChange: pid=\(pid) title=\"\(axTitle)\" frame=\(axFrame)")

        guard let matchedID = axMatcher.matchAXToCGWindowID(pid: pid, title: axTitle, frame: axFrame, windows: windows, appZOrder: appZOrder) else {
            logDebug("AXFocusChange: NO MATCH for pid=\(pid) title=\"\(axTitle)\"")
            return
        }

        guard matchedID != frontmostWindowID else {
            logDebug("AXFocusChange: same window \(matchedID), no-op")
            return
        }

        let oldID = frontmostWindowID
        frontmostWindowID = matchedID
        orderingEngine.windowDidInteract(matchedID)
        onInteraction?(matchedID)
        let oldName = oldID.flatMap { orderingEngine.windowNames[$0] } ?? "?"
        let newName = orderingEngine.windowNames[matchedID] ?? "?"
        logDebug("AXFocusChange: frontmostWindowID \(String(describing: oldID))(\(oldName)) → \(matchedID)(\(newName))")
    }

    /// Event-driven re-query of the AX focused window, driven by a Cmd+` key
    /// event. Same-app window switches are invisible to app-activation and to
    /// the scroll/click monitors (frontmostWindowID goes stale), and AX
    /// notifications are unreliable (Chrome fires once per observer
    /// registration, Obsidian never), so the key event triggers an explicit
    /// query. Retries once when the switch has not yet reached AX.
    func recheckFocusedWindow(pid: pid_t) {
        guard pid != NSRunningApplication.current.processIdentifier else { return }
        logDebug("KEYMON: Cmd+` → recheckFocusedWindow pid=\(pid)")
        let before = frontmostWindowID
        handleAXFocusChange(pid: pid)
        if frontmostWindowID == before {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.handleAXFocusChange(pid: pid)
            }
        }
    }

    /// Returns the topmost on-screen window of an app from a fresh snapshot.
    private func frontmostWindow(for pid: pid_t) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for dict in list {
            guard let ownerPID = dict[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let layer = dict[kCGWindowLayer as String] as? Int, layer == 0,
                  let num = dict[kCGWindowNumber as String] as? Int
            else { continue }
            return CGWindowID(num)
        }
        return nil
    }

    private func parseWindow(_ dict: [String: Any]) -> WindowInfo? {
        guard let windowID = dict[kCGWindowNumber as String] as? Int,
              let ownerPID = dict[kCGWindowOwnerPID as String] as? pid_t,
              let ownerName = dict[kCGWindowOwnerName as String] as? String,
              let bounds = dict[kCGWindowBounds as String] as? [String: Any]
        else { return nil }

        if ownerPID == ProcessInfo.processInfo.processIdentifier {
            return nil
        }

        let bundleID = NSRunningApplication(
            processIdentifier: ownerPID
        )?.bundleIdentifier

        if let bid = bundleID, Constants.excludedAppBundleIDs.contains(bid) {
            return nil
        }

        guard let x = bounds["X"] as? CGFloat,
              let y = bounds["Y"] as? CGFloat,
              let w = bounds["Width"] as? CGFloat,
              let h = bounds["Height"] as? CGFloat,
              w >= 100, h >= 100
        else { return nil }

        let frame = CGRect(x: x, y: y, width: w, height: h)

        return WindowInfo(
            id: CGWindowID(windowID),
            ownerPid: ownerPID,
            ownerName: ownerName,
            ownerBundleID: bundleID,
            windowTitle: (dict[kCGWindowName as String] as? String) ?? "",
            frame: frame
        )
    }

    // MARK: - Sync change diagnostics

    /// Records WHY windows were removed/added by sync. The on-screen snapshot
    /// (.optionOnScreenOnly) drops windows that are minimized, on another
    /// Space, occluded, or off-screen — sync then sees a spurious
    /// "removed 1 + added 1" and prepends the reappearing window to the LRU
    /// head. This logs each removed/added window with its inferred cause so the
    /// root cause can be confirmed instead of guessed.
    private func logSyncChangeDiagnostics(oldIDs: [CGWindowID], newIDs: [CGWindowID],
                                          oldWindows: [CGWindowID: WindowInfo],
                                          newWindows: [CGWindowID: WindowInfo],
                                          newOrder: [CGWindowID]) {
        let oldSet = Set(oldIDs)
        let newSet = Set(newIDs)
        let removed = oldSet.subtracting(newSet)
        let added = newSet.subtracting(oldSet)
        if removed.isEmpty && added.isEmpty && oldIDs == newIDs {
            knownWindowIDs.formUnion(newSet)
            return
        }

        // Fetch the FULL window list (no on-screen filter) once, to determine
        // why removed windows dropped out. Only runs when a change is detected.
        let fullList = (CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
                        as? [[String: Any]]) ?? []
        var fullByID: [CGWindowID: [String: Any]] = [:]
        for dict in fullList {
            if let num = dict[kCGWindowNumber as String] as? Int {
                fullByID[CGWindowID(num)] = dict
            }
        }

        logDebug("SYNC-DIAG: === change: removed=\(removed.count) added=\(added.count) orderChanged=\(oldIDs != newIDs) ===")

        for id in removed.sorted() {
            let old = oldWindows[id]
            let name = old?.ownerName ?? orderingEngine.windowNames[id] ?? "?"
            let title = old?.windowTitle ?? "?"
            let cause = removedCause(for: id, dict: fullByID[id], oldInfo: old,
                                     newWindows: newWindows, added: added)
            logDebug("SYNC-DIAG:   REMOVED id=\(id) name=\(name) title=\"\(title)\" cause=\(cause)")
        }

        for id in added.sorted() {
            let info = newWindows[id]
            let name = info?.ownerName ?? "?"
            let title = info?.windowTitle ?? "?"
            let everSeen = knownWindowIDs.contains(id)
            let isFront = newOrder.first == id
            let category: String
            if everSeen {
                category = "re-detection (id seen before → off-screen drop/reappear, NOT new)"
            } else if isFront {
                category = "genuinely new frontmost window"
            } else {
                category = "genuinely new non-frontmost window"
            }
            logDebug("SYNC-DIAG:   ADDED id=\(id) name=\(name) title=\"\(title)\" everSeen=\(everSeen) isFront=\(isFront) → \(category)")
        }

        let orderStr = newOrder.enumerated().map { idx, id in
            let nm = newWindows[id]?.ownerName ?? orderingEngine.windowNames[id] ?? "?"
            return "[\(idx)]\(nm)"
        }.joined(separator: " → ")
        logDebug("SYNC-DIAG:   new order: \(orderStr)")

        knownWindowIDs.formUnion(newSet)
    }

    /// Infers why a removed window left the on-screen snapshot, using the full
    /// (unfiltered) window list as ground truth.
    private func removedCause(for id: CGWindowID, dict: [String: Any]?, oldInfo: WindowInfo?,
                              newWindows: [CGWindowID: WindowInfo], added: Set<CGWindowID>) -> String {
        guard let dict = dict else {
            // Not in the full list at all → closed, or rebuilt under a new ID.
            // A rebuild produces a matching ADDED window (same app, same frame).
            let rebuilt = added.contains { addedID in
                guard let info = newWindows[addedID], let old = oldInfo else { return false }
                return info.ownerPid == old.ownerPid
                    && WindowManager.frameMatches(info.frame, old.frame, tolerance: 80)
            }
            return rebuilt
                ? "NOT in full list → likely REBUILT under new ID (same-app same-frame in added)"
                : "NOT in full list → window CLOSED"
        }

        if let raw = dict[kCGWindowIsOnscreen as String] {
            let onscreen = (raw as? Bool) ?? ((raw as? NSNumber)?.boolValue ?? true)
            if !onscreen {
                return "in full list but offscreen → MINIMIZED / occluded / other Space"
            }
        }
        if let layer = dict[kCGWindowLayer as String] as? Int, layer != 0 {
            return "in full list, onscreen, layer=\(layer)≠0 → non-normal window layer"
        }
        if let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
           pid == ProcessInfo.processInfo.processIdentifier {
            return "in full list, onscreen, layer=0, ownerPID==self → own window"
        }
        if let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
           let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           Constants.excludedAppBundleIDs.contains(bid) {
            return "in full list, onscreen, layer=0, excluded bundleID=\(bid)"
        }
        if let bounds = dict[kCGWindowBounds as String] as? [String: Any],
           let w = bounds["Width"] as? CGFloat, let h = bounds["Height"] as? CGFloat,
           w < 100 || h < 100 {
            return "in full list, onscreen, layer=0, size \(w)×\(h)<100 → size filter"
        }
        return "in full list, onscreen, layer=0, normal → parseWindow should accept, VOLATILE snapshot / unknown"
    }

    /// Registers the Cmd+` event tap, trying the session location first and
    /// the annotated session location as a fallback. Retries a few times after
    /// a short delay — at app launch CGEvent.tapCreate can transiently return
    /// nil even when AXIsProcessTrusted() is already true.
    private func registerKeyEventTap() {
        guard keyEventTap == nil else { return }
        let listenAccess = CGPreflightListenEventAccess()
        logDebug("WindowManager: Input Monitoring preflight listenAccess=\(listenAccess)")
        let keyMask = CGEventMask((1 << CGEventType.keyDown.rawValue)
                                | (1 << CGEventType.keyUp.rawValue))
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let locations: [(CGEventTapLocation, String)] = [
            (.cgSessionEventTap, "session"),
            (.cgAnnotatedSessionEventTap, "annotated"),
        ]
        for (location, name) in locations {
            if let tap = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: keyMask,
                callback: windowManagerKeyTapCallback,
                userInfo: userInfo
            ) {
                keyEventTap = tap
                let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
                keyEventTapSource = src
                CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                logDebug("WindowManager: Cmd+` CGEventTap registered (loc=\(name), retry=\(keyEventTapRetries)), trusted=\(AXIsProcessTrusted()) listenAccess=\(listenAccess)")
                return
            }
        }
        logDebug("WindowManager: Cmd+` CGEventTap FAILED (loc=session+annotated, retry=\(keyEventTapRetries)), trusted=\(AXIsProcessTrusted()) listenAccess=\(listenAccess)")
        keyEventTapRetries += 1
        guard keyEventTapRetries <= keyEventTapMaxRetries else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.registerKeyEventTap()
        }
    }

    /// Event tap callback handler: tracks Cmd+` presses to drive a delayed AX
    /// focus re-check after the window cycle settles. Runs on the main thread.
    /// `fileprivate` so the file-scoped C callback can invoke it.
    fileprivate func handleKeyEvent(type: CGEventType, event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // Diagnostic: confirm the tap actually receives key events (the old
        // NSEvent global monitor received none — KEYMON never fired).
        keyEventCount += 1
        if keyEventCount <= 3 || keyEventCount % 100 == 0 {
            logDebug("KEYTAP: received \(keyEventCount) key events (keyCode=\(keyCode))")
        }

        let isBacktick = keyCode == 50
        if isBacktick {
            logDebug("KEYTAP: backtick \(type == .keyDown ? "down" : "up") flags=\(event.flags.rawValue)")
        }

        if type == .keyDown && isBacktick && event.flags.contains(.maskCommand) {
            // Cmd+` pressed: mark pending and debounce the auto-repeat so the
            // final window (after the cycle settles) is queried.
            cmdBacktickPending = true
            cmdBacktickWorkItem?.cancel()
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.cmdBacktickPending = false
                guard let pid else { return }
                self.recheckFocusedWindow(pid: pid)
            }
            cmdBacktickWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
        } else if type == .keyUp && isBacktick && cmdBacktickPending {
            // Key released → the window cycle has settled; query now.
            cmdBacktickPending = false
            cmdBacktickWorkItem?.cancel()
            cmdBacktickWorkItem = nil
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard let pid else { return }
            recheckFocusedWindow(pid: pid)
        }
    }
}

/// C bridge for the Cmd+` event tap. The tap source is added to the main
/// CFRunLoop, so this runs on the main thread and can touch instance state.
private func windowManagerKeyTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let mgr = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = mgr.keyEventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }
    mgr.handleKeyEvent(type: type, event: event)
    return Unmanaged.passUnretained(event)
}
