#include <CoreGraphics/CoreGraphics.h>

/// C helper to call CGWindowListCreateImage (deprecated in newer SDKs
/// but still functional at runtime). Swift compilation would flag this
/// as unavailable, but C compilation allows it with a warning.
CGImageRef WindowSwitcher_CaptureWindowImage(CGWindowID windowID) {
    CGImageRef image = CGWindowListCreateImage(
        CGRectNull,
        kCGWindowListOptionIncludingWindow,
        windowID,
        kCGWindowImageBoundsIgnoreFraming
    );
    return image;
}

/// 全屏合成画面截图（用户实际看到的像素：所有屏幕窗口合成，含本 App 面板）。
/// 仅用于揭示环节诊断（REVEAL-DIAG），不参与功能路径。
CGImageRef WindowSwitcher_CaptureScreenImage(CGRect bounds) {
    CGImageRef image = CGWindowListCreateImage(
        bounds,
        kCGWindowListOptionOnScreenOnly,
        kCGNullWindowID,
        kCGWindowImageBoundsIgnoreFraming
    );
    return image;
}
