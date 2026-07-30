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
