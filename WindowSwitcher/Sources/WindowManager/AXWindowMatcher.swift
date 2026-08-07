import AppKit
import CoreGraphics

/// Snapshot of a single Accessibility API window element.
struct AXWindowSnapshot {
    let element: AXUIElement
    let title: String
    let frame: CGRect
}

/// Pure AX window enumeration and matching logic extracted from WindowManager.
/// All methods that need WindowManager state (windows dict, appZOrder) take it
/// as explicit parameters so the matching algorithms are testable and auditable
/// independently of the window-list lifecycle.
final class AXWindowMatcher {
    static let shared = AXWindowMatcher()

    // MARK: - AX enumeration

    /// Enumerate all AX windows for a given pid, returning title + frame for each.
    func enumerateAXWindows(forPid pid: pid_t) -> [AXWindowSnapshot] {
        let app = AXUIElementCreateApplication(pid)
        var list: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &list)
        guard r == .success, let axWindows = list as? [AXUIElement] else { return [] }

        var result: [AXWindowSnapshot] = []
        for axWin in axWindows {
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &t)
            let title = (t as? String) ?? ""

            var pos: CFTypeRef?, size: CFTypeRef?
            var frame = CGRect.zero
            AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &pos)
            AXUIElementCopyAttributeValue(axWin, kAXSizeAttribute as CFString, &size)
            if let pv = pos { AXValueGetValue(pv as! AXValue, .cgPoint, &frame.origin) }
            if let sv = size { AXValueGetValue(sv as! AXValue, .cgSize, &frame.size) }

            result.append(AXWindowSnapshot(element: axWin, title: title, frame: frame))
        }
        return result
    }

    // MARK: - Frame matching

    /// Whether two rects describe the same on-screen window frame (with tolerance).
    static func frameMatches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 10) -> Bool {
        abs(a.origin.x - b.origin.x) < tolerance &&
        abs(a.origin.y - b.origin.y) < tolerance &&
        abs(a.size.width - b.size.width) < tolerance &&
        abs(a.size.height - b.size.height) < tolerance
    }

    // MARK: - CGWindowID matching

    /// Matches an AX focused window (by title + frame) to a known CGWindowID
    /// in the current window snapshot.
    func matchAXToCGWindowID(
        pid: pid_t, title: String, frame: CGRect,
        windows: [CGWindowID: WindowInfo],
        appZOrder: [pid_t: [(id: CGWindowID, frame: CGRect)]]
    ) -> CGWindowID? {
        let fMatch: (CGRect, CGRect) -> Bool = { Self.frameMatches($0, $1) }

        // Step 1: frame match
        let candidates = windows.filter { $0.value.ownerPid == pid && fMatch($0.value.frame, frame) }

        if candidates.isEmpty {
            if !title.isEmpty, let m = windows.first(where: {
                $0.value.ownerPid == pid && $0.value.windowTitle == title
            }) {
                logDebug("AXFocusChange: match by title only (no frame match)")
                return m.key
            }
            return nil
        }

        if candidates.count == 1 {
            return candidates.first!.key
        }

        // Step 2: multiple same-frame CG windows → title match.
        let zOrder = appZOrder[pid] ?? []
        let sameFrameCG = zOrder.filter { fMatch($0.frame, frame) }

        var sameFrameAXTitles: [String] = []
        let snapshots = enumerateAXWindows(forPid: pid)
        for s in snapshots {
            if fMatch(s.frame, frame) {
                sameFrameAXTitles.append(s.title)
            }
        }

        logDebug("AXFocusChange: sameFrameAX=\(sameFrameAXTitles.count) sameFrameCG=\(sameFrameCG.count)")

        if !title.isEmpty, let m = sameFrameCG.first(where: { w in
            let cgTitle = windows[CGWindowID(w.id)]?.windowTitle ?? ""
            return cgTitle == title || title.hasPrefix(cgTitle) || cgTitle.hasPrefix(title)
        }) {
            logDebug("AXFocusChange: title match → CG id=\(m.id)")
            return CGWindowID(m.id)
        }

        // Step 3: fallbacks
        if !title.isEmpty, let m = candidates.first(where: {
            $0.value.windowTitle == title || title.hasPrefix($0.value.windowTitle) || $0.value.windowTitle.hasPrefix(title)
        }) {
            logDebug("AXFocusChange: fallback title match")
            return m.key
        }
        logDebug("AXFocusChange: fallback first frame match")
        return candidates.first!.key
    }

    // MARK: - AX window selection

    /// Selects the AX window corresponding to `targetID` among the app's AX windows.
    func selectAXWindow(
        for targetID: CGWindowID,
        pid: pid_t,
        frame: CGRect,
        title: String,
        axWindows: [(index: Int, title: String, frame: CGRect)],
        appZOrder: [pid_t: [(id: CGWindowID, frame: CGRect)]]
    ) -> (index: Int, title: String)? {
        let fMatch: (CGRect, CGRect) -> Bool = { Self.frameMatches($0, $1) }

        let sameFrame = axWindows
            .filter { fMatch($0.frame, frame) }
            .map { (index: $0.index, title: $0.title) }
        if !sameFrame.isEmpty {
            if sameFrame.count == 1 {
                return sameFrame[0]
            }
            let zOrder = appZOrder[pid] ?? []
            let sameFrameCG = zOrder.filter { fMatch($0.frame, frame) }
            if let rank = sameFrameCG.firstIndex(where: { $0.id == targetID }),
               rank < sameFrame.count {
                return sameFrame[rank]
            }
            if !title.isEmpty, let t = sameFrame.first(where: { $0.title == title }) {
                return t
            }
            return sameFrame[0]
        }
        if !title.isEmpty, let t = axWindows.first(where: { $0.title == title }) {
            return (index: t.index, title: t.title)
        }
        return axWindows.first.map { (index: $0.index, title: $0.title) }
    }

    // MARK: - Title backfill

    /// Fills real window titles from the Accessibility API into apps whose
    /// CGWindowList title is empty (e.g. Chrome).
    func backfillTitles(
        _ dict: inout [CGWindowID: WindowInfo],
        appZOrder: [pid_t: [(id: CGWindowID, frame: CGRect)]]
    ) {
        let fMatch: (CGRect, CGRect) -> Bool = { Self.frameMatches($0, $1) }
        let emptyPids = Set(dict.values.filter { $0.windowTitle.isEmpty }.map { $0.ownerPid })
        guard !emptyPids.isEmpty else { return }

        for pid in emptyPids {
            let snapshots = enumerateAXWindows(forPid: pid)
            guard !snapshots.isEmpty else { continue }

            var axInfo: [(index: Int, title: String, frame: CGRect)] = []
            for (idx, s) in snapshots.enumerated() {
                axInfo.append((idx, s.title, s.frame))
            }

            let zOrder = appZOrder[pid] ?? []
            for key in dict.keys where dict[key]?.ownerPid == pid && (dict[key]?.windowTitle.isEmpty ?? true) {
                guard let info = dict[key] else { continue }
                let sameFrameAX = axInfo.filter { fMatch($0.frame, info.frame) }
                var newTitle = ""
                if sameFrameAX.count == 1 {
                    newTitle = sameFrameAX[0].title
                } else if sameFrameAX.count > 1 {
                    let sameFrameCG = zOrder.filter { fMatch($0.frame, info.frame) }
                    if let rank = sameFrameCG.firstIndex(where: { $0.id == info.id }),
                       rank < sameFrameAX.count {
                        newTitle = sameFrameAX[rank].title
                    } else {
                        newTitle = sameFrameAX[0].title
                    }
                }
                if !newTitle.isEmpty {
                    dict[key] = info.withTitle(newTitle)
                }
            }
        }
    }

    // MARK: - Diagnostics

    /// Post-activation diagnostic: verify the app's focused AX window matches
    /// the AX element we raised.
    func scheduleMappingCheck(pid: pid_t, expectedTitle: String, windowID: CGWindowID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let app = AXUIElementCreateApplication(pid)
            var f: CFTypeRef?
            let r = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &f)
            guard r == .success, let fw = f else { return }
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(fw as! AXUIElement, kAXTitleAttribute as CFString, &t)
            let focused = (t as? String) ?? ""
            if focused != expectedTitle {
                logDebug("MAPPING-MISMATCH: window=\(windowID) expected=\"\(expectedTitle)\" focused=\"\(focused)\"")
            } else {
                logDebug("MAPPING-OK: window=\(windowID) focused=\"\(focused)\"")
            }
        }
    }
}
