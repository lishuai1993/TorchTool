#ifndef GESTURE_ENGINE_H
#define GESTURE_ENGINE_H

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    GestureNone = 0,
    GestureThreeFingerTap,
    GestureThreeFingerSwipeLeft,
    GestureThreeFingerSwipeRight,
    GestureThreeFingerSwipeUp,
    GestureThreeFingerSwipeDown,
    GestureSwipeUpdate,   // ongoing swipe, signed progress (right=+, left=-)
    GestureTrackingBegan, // 3 fingers landed; tracking session started (pre-capture hook)
    GestureEnd,           // fingers lifted, gesture finished
} GestureType;

typedef void (*GestureCallback)(GestureType type, float progress);

int gesture_engine_start(GestureCallback callback);
int gesture_engine_start_safe(void);  // starts device without registering callback
void gesture_engine_stop(void);
bool gesture_engine_is_running(void);

// Whether a three-finger gesture is currently being tracked (GS_TRACKING or
// GS_SWIPING). Scroll events arriving while true are the gesture's own
// artifacts (a three-finger swipe generates scrollWheel as the fingers move)
// and must NOT trigger a window reorder. Read synchronously from the Swift
// scroll monitor; safe to call from any thread.
bool gesture_engine_is_tracking(void);

// Number of contact-frame callbacks received since the engine started.
// Used as a heartbeat to detect when the MT contact stream has stalled.
int gesture_engine_callback_count(void);

// Set log file path for C engine debug output (written in addition to stderr).
void gesture_engine_set_log_path(const char *path);

// Truncate the C engine log file (reopens in "w" mode). Called on service start
// so each run starts from a clean log.
void gesture_engine_reset_log(void);

// Configure sensitivity thresholds before calling gesture_engine_start.
// Values are in normalized coordinates [0,1] and seconds.
void gesture_engine_set_sensitivity(float tapDuration, float tapDisp,
                                     float swipeDisp, float swipeDur);
void gesture_engine_set_touchdown_window(double windowSec);

#endif
