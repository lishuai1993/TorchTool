#ifndef GESTURE_ENGINE_H
#define GESTURE_ENGINE_H

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    GestureNone = 0,
    GestureThreeFingerTap,
    GestureThreeFingerSwipeLeft,
    GestureThreeFingerSwipeRight,
    GestureSwipeUpdate,   // ongoing swipe, progress in [0,1]
} GestureType;

typedef void (*GestureCallback)(GestureType type, float progress);

int gesture_engine_start(GestureCallback callback);
int gesture_engine_start_safe(void);  // starts device without registering callback
void gesture_engine_stop(void);
bool gesture_engine_is_running(void);

// Set log file path for C engine debug output (written in addition to stderr).
void gesture_engine_set_log_path(const char *path);

// Configure sensitivity thresholds before calling gesture_engine_start.
// Values are in normalized coordinates [0,1] and seconds.
void gesture_engine_set_sensitivity(float tapDuration, float tapDisp,
                                     float swipeDisp, float swipeDur);

#endif
