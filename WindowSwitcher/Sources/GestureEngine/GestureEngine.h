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

#endif
