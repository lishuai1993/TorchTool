#ifndef WINDOW_CAPTURE_H
#define WINDOW_CAPTURE_H

#include <CoreGraphics/CoreGraphics.h>

CGImageRef WindowSwitcher_CaptureWindowImage(CGWindowID windowID);
CGImageRef WindowSwitcher_CaptureScreenImage(CGRect bounds);

#endif
