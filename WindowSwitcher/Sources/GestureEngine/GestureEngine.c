#include "GestureEngine.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <limits.h>
#include <stdatomic.h>
#include <time.h>
#include <dispatch/dispatch.h>

// ──────────────────────────────────────────────────
// Dual-output logging (stderr + optional log file)
// ──────────────────────────────────────────────────

static FILE *logFile = NULL;
static char logPath[PATH_MAX] = "";

// NOTE: ws_log is defined before gesture_engine_set_log_path
// because the setter calls ws_log.
static void ws_log(const char *fmt, ...) {
    va_list args1, args2;
    va_start(args1, fmt);
    va_copy(args2, args1);
    vfprintf(stderr, fmt, args1);
    fflush(stderr);
    if (logFile) {
        vfprintf(logFile, fmt, args2);
        fflush(logFile);
    }
    va_end(args1);
    va_end(args2);
}

void gesture_engine_set_log_path(const char *path) {
    if (path) {
        strncpy(logPath, path, sizeof(logPath) - 1);
        logPath[sizeof(logPath) - 1] = '\0';
    }
    if (logFile) fclose(logFile);
    logFile = fopen(path, "a");
    if (logFile) {
        ws_log("[WS] C engine logging to: %s\n", path);
    } else {
        ws_log("[WS] WARNING: could not open log file: %s\n", path);
    }
}

// Reopen the C engine log file in "w" mode to truncate it. Called when the
// service starts so each run starts from a clean log. Keeps the same file
// path so the FILE* always points at the current log.
void gesture_engine_reset_log(void) {
    if (logPath[0] == '\0') return;
    if (logFile) fclose(logFile);
    logFile = fopen(logPath, "w");
    if (logFile) {
        ws_log("[WS] C engine log reset at: %s\n", logPath);
    } else {
        ws_log("[WS] WARNING: could not reset log file: %s\n", logPath);
    }
}

// ──────────────────────────────────────────────────
// MultitouchSupport.framework — dynamically loaded
// ──────────────────────────────────────────────────

// Contact data byte offsets — verified on macOS 15.3.2 via raw hex dump.
// Struct size: 96 bytes (found by locating repeating frame/timestamp pattern)
// Layout: frame(4)+pad(4)+ts(8)+id(4)+state(4)+type(4)+flags(4)
//         +posX(4)+posY(4)+posZ(4)+extra(56) = 96
#define CONTACT_OFFSET_FRAME      0    // int32_t
#define CONTACT_OFFSET_TIMESTAMP  8    // double
#define CONTACT_OFFSET_IDENTIFIER 16   // int32_t
#define CONTACT_OFFSET_STATE      20   // int32_t
#define CONTACT_OFFSET_TYPE       24   // int32_t
#define CONTACT_OFFSET_FLAGS      28   // int32_t
#define CONTACT_OFFSET_POS_X      32   // float (normalized 0..1)
#define CONTACT_OFFSET_POS_Y      36   // float (normalized 0..1)
#define CONTACT_OFFSET_POS_Z      40   // float
#define CONTACT_STRUCT_SIZE       96

// Callback signatures — macOS 15.3.2 may use either.
// Signature A: (device, data, count, timestamp, frame)
typedef void (*RawContactCallback5)(int deviceIndex, void *data,
                                     int count, double timestamp, int frame);
// Signature B: with refcon (device, data, count, timestamp, frame, refcon)
typedef void (*RawContactCallback6)(int deviceIndex, void *data,
                                     int count, double timestamp, int frame,
                                     void *refcon);

typedef void* (*MTDeviceCreateListFunc)(void);
typedef void* (*MTDeviceCreateDefaultFunc)(void);
typedef int   (*MTDeviceStartFunc)(void *device, int mode);
typedef int   (*MTDeviceStopFunc)(void *device);
typedef int   (*MTRegisterContactFrameCallbackFunc)(void *device,
                                                      RawContactCallback5 callback);
typedef int   (*MTRegisterContactFrameCallbackWithRefconFunc)(void *device,
                                                                RawContactCallback6 callback);
typedef int   (*MTUnregisterContactFrameCallbackFunc)(void *device,
                                                        RawContactCallback5 callback);
typedef int   (*MTUnregisterContactFrameCallbackWithRefconFunc)(void *device,
                                                                  RawContactCallback6 callback);

// ──────────────────────────────────────────────────
// Internal state
// ──────────────────────────────────────────────────
static void                *mtDevice       = NULL;
static void                *mtLibHandle    = NULL;
static volatile bool        engineRunning  = false;
static GestureCallback      userCallback   = NULL;
static pthread_mutex_t      stateLock;
static bool                 stateLockInited = false;

// Stored function pointers
static MTDeviceStartFunc                           pMTDeviceStart    = NULL;
static MTDeviceStopFunc                            pMTDeviceStop     = NULL;
static MTRegisterContactFrameCallbackFunc          pMTRegisterCB5    = NULL;
static MTRegisterContactFrameCallbackWithRefconFunc pMTRegisterCB6   = NULL;
static MTUnregisterContactFrameCallbackFunc        pMTUnregisterCB5  = NULL;
static MTUnregisterContactFrameCallbackWithRefconFunc pMTUnregisterCB6 = NULL;

// Gesture recognition state machine
typedef enum {
    GS_IDLE = 0,
    GS_TRACKING,
    GS_SWIPING,
} GestureState;

static GestureState gState = GS_IDLE;

// Mirrors "a three-finger gesture is in progress" (gState == GS_TRACKING ||
// gState == GS_SWIPING). Written on the MT callback thread under stateLock,
// read atomically from the main-thread scroll monitor, so a plain bool is
// insufficient — keep it atomic to avoid a data race.
static atomic_bool trackingActive = false;

// Settling period: ignore the first 80ms of three-finger contact
// to account for natural finger flattening/centroid drift.
#define SETTLING_DURATION 0.080

// Simultaneous touchdown window: all three fingers must land within this
// duration of the first finger appearing, otherwise treated as rolling touchdown.
// Configurable via gesture_engine_set_touchdown_window(), default 500ms.
static double maxTouchdownWindow = 0.500;

// Tracking data
static double  touchStartTime      = 0;
static double  touchdownStartTime  = 0;  // timestamp of first finger contact
static double  settlingEndTime     = 0;
static float   touchStartCentroidX = 0;
static float   touchStartCentroidY = 0;
static float   settledCentroidX    = 0;
static float   settledCentroidY    = 0;
static float   lastCentroidX       = 0;
static float   lastCentroidY       = 0;
static float   maxPostSettleDisp   = 0;  // max displacement after settling
static int     activeFingerCount   = 0;
// 严格三指限定：本触摸会话期间是否出现过 >3 指（实触 fingerCount>3，或含悬停槽
// totalContacts>3）。置位后本会话禁止进入 TRACKING，直到全部手指离板（IDLE 清零）。
static bool    touchdownExceededThree = false;
static bool    swipeActionFired    = false;
static bool    isHorizontalSwipe   = false; // true for LEFT/RIGHT, false for UP/DOWN
static int     lastFrame           = 0;   // for detecting callback interruption

// 会话峰值横向速度（progress/sec，带符号，取 |值| 最大者）。帧级时间基来自 MT
// 帧时间戳，规避 Swift 主线程批处理导致的退化时间戳。每次 IDLE→TRACKING 重置，
// 在 gestureEnd 前一刻以 GestureSwipePeakVelocity 发射给上层（方案A 动量助推）。
static float  sessionPeakVel     = 0;
static float  lastVelProgress    = 0;
static double lastVelTimestamp   = 0;
// 会话内 |progress| 最大值（带符号）：符号即主甩动方向，用于过滤折返/回摆阶段
// 的相反方向瞬时速度（详见 updatePeakVelocity）。
static float  sessionMaxProgress = 0;

// 抬手前即时速度（progress/sec，带符号）：最近 3 帧 instVel 的滑动平均，反映抬手
// 瞬间的真实速度方向/大小。与 sessionPeakVel（会话峰值，仅诊断）不同——慢速拖拽
// 中会话峰值会很大，但抬手前速度在停顿/反向时趋零或反向，正是路径A方向保护的依据。
// 每帧在 updatePeakVelocity 中更新，抬手帧读取；IDLE→TRACKING 重置。
static float  releaseInstVel     = 0;
static float  instVelBuffer[3]   = {0, 0, 0};
static int    instVelCount       = 0;
static int    instVelIdx         = 0;

// Per-frame finger count tracking (reset on engine start).
static int     prevFingerCount     = 0;
static int     lastFingerCount     = 0;

// Sensitivity
static float   tapMaxDurationSec   = 0.350;  // 350ms from first touch
static float   tapMaxDisplacement  = 0.04;   // 4% after settling
static float   swipeMinDisplacement = 0.08;
static float   swipeMinDuration    = 0.02;  // 晋升门槛=SETTLING_DURATION+swipeMinDuration=100ms，快甩在微抬(3→2)前完成晋升

// Diagnostics
static volatile int callbackCallCount = 0;
static volatile int callbackErrorCount = 0;
static int gestureSessionID = 0;  // increments each IDLE→TRACKING, for correlating C/Swift logs

// ──────────────────────────────────────────────────
// Frame-starvation watchdog
// ──────────────────────────────────────────────────
// MT 在三指同时抬手（3→0 直变）后可能停止投递 contact 帧，回调缺口检测（GS_SWIPING
// 内 `frame - lastFrame > 30`）只在收到下一帧时才执行，无新帧则引擎永久停在
// GS_SWIPING + fingerCount=3 → gestureEnd 永不触发 → Swift 侧 2.5s 看门狗才兜底，
// 观感为「手指已离板窗口静止约 2.5s 后回退」。此定时器每 50ms 检查：引擎仍在滑动期
// 且超过 FRAME_STARVATION_TIMEOUT 没有新帧，则复刻回调缺口结束序列（发射
// releaseVelocity + gestureEnd），由上层 finishSlideSession 判定提交/回弹，甩动动量
// 得以保留（这正是 C 定时器相对纯 Swift 超时的价值）。
static dispatch_queue_t frameStarvationQueue = NULL;
static dispatch_source_t frameStarvationTimer = NULL;
static double lastFrameTime = 0;         // 最后收到的 MT 帧的单调钟时刻
static double lastContactTimestamp = 0;  // 最后收到的 MT 帧的帧级时间戳（MT 时钟域，用于快甩会话期判别）
static const double FRAME_STARVATION_TIMEOUT = 0.2;   // 200ms 无帧即视为饿死
static const double FRAME_STARVATION_TICK = 0.05;     // 50ms 轮询周期
static const double TRACKING_FAST_FLICK_WINDOW = 0.5; // TRACKING 兜底仅对「起手 500ms 内极快滑动停顿」生效，慢速拖拽停顿不误触

static double ws_monotonic_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static void frameStarvationCheck(void *unused) {
    (void)unused;
    pthread_mutex_lock(&stateLock);
    double now = ws_monotonic_now();
    if ((now - lastFrameTime) > FRAME_STARVATION_TIMEOUT) {
        if (gState == GS_SWIPING) {
            ws_log("[WS-DBG] PEAK: session=%d peak=%.3f maxProgress=%.3f\n",
                   gestureSessionID, sessionPeakVel, sessionMaxProgress);
            userCallback(GestureSwipePeakVelocity, sessionPeakVel);
            userCallback(GestureReleaseVelocity, releaseInstVel);
            userCallback(GestureEnd, 0);
            ws_log("[WS-DBG] STATE: SWIPING -> IDLE [session=%d] (frame starvation, %.0fms no frame) GestureEnd fired\n",
                   gestureSessionID, (now - lastFrameTime) * 1000);
            gState = GS_IDLE;
            atomic_store(&trackingActive, false);
            swipeActionFired = false;
            isHorizontalSwipe = false;
        } else if (gState == GS_TRACKING
                   && sessionMaxProgress != 0
                   && (lastContactTimestamp - touchStartTime) < TRACKING_FAST_FLICK_WINDOW) {
            // 快甩盲区兜底：TRACKING 期已投递过 swipeUpdate（sessionMaxProgress!=0，排除点按/静置/沉降期），
            // 但 200ms 无新帧——极快滑动中手指微抬(3→2)使 MT 停投递，晋升评估永不执行（门槛差几毫秒）。
            // 复刻正常抬手端序（GS_TRACKING fingerCount<2 路径同款），保住甩动动量并让上层正常收尾；
            // 500ms 判别器确保只兜极快滑动停顿，慢速弹性拖拽后静置不误触。
            ws_log("[WS-DBG] PEAK: session=%d peak=%.3f maxProgress=%.3f\n",
                   gestureSessionID, sessionPeakVel, sessionMaxProgress);
            userCallback(GestureSwipePeakVelocity, sessionPeakVel);
            userCallback(GestureReleaseVelocity, releaseInstVel);
            userCallback(GestureEnd, 0);
            ws_log("[WS-DBG] STATE: TRACKING -> IDLE [session=%d] (frame starvation, %.0fms no frame) GestureEnd fired\n",
                   gestureSessionID, (now - lastFrameTime) * 1000);
            gState = GS_IDLE;
            atomic_store(&trackingActive, false);
            swipeActionFired = false;
            isHorizontalSwipe = false;
        }
    }
    pthread_mutex_unlock(&stateLock);
}

static void frameStarvationTimerStart(void) {
    if (frameStarvationTimer) return;
    frameStarvationQueue = dispatch_queue_create("com.windowswitcher.gesture.starvation", NULL);
    frameStarvationTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                  frameStarvationQueue);
    dispatch_source_set_timer(frameStarvationTimer,
                              dispatch_time(DISPATCH_TIME_NOW, FRAME_STARVATION_TICK * NSEC_PER_SEC),
                              FRAME_STARVATION_TICK * NSEC_PER_SEC,
                              FRAME_STARVATION_TICK * 0.2 * NSEC_PER_SEC);  // 10ms leeway
    dispatch_source_set_event_handler_f(frameStarvationTimer, frameStarvationCheck);
    dispatch_resume(frameStarvationTimer);
}

static void frameStarvationTimerStop(void) {
    if (frameStarvationTimer) {
        dispatch_source_cancel(frameStarvationTimer);
        dispatch_release(frameStarvationTimer);
        frameStarvationTimer = NULL;
    }
    if (frameStarvationQueue) {
        dispatch_release(frameStarvationQueue);
        frameStarvationQueue = NULL;
    }
}

// ──────────────────────────────────────────────────
// Helpers: read fields from raw contact data
// ──────────────────────────────────────────────────

static int32_t contact_read_int32(const uint8_t *base, int offset) {
    int32_t val;
    memcpy(&val, base + offset, sizeof(val));
    return val;
}

static float contact_read_float(const uint8_t *base, int offset) {
    float val;
    memcpy(&val, base + offset, sizeof(val));
    return val;
}

// ──────────────────────────────────────────────────
// Signal handler — DISABLED for debugging, to see real crash location
// ──────────────────────────────────────────────────

static void install_signal_handlers(void) {
    // Temporarily disabled to find root cause of SIGSEGV at 0x20
    // struct sigaction sa;
    // memset(&sa, 0, sizeof(sa));
    // sa.sa_sigaction = crash_signal_handler;
    // sa.sa_flags = SA_SIGINFO;
    // sigaction(SIGABRT, &sa, NULL);
    // sigaction(SIGBUS, &sa, NULL);
    // sigaction(SIGSEGV, &sa, NULL);
}

// ──────────────────────────────────────────────────
// Forward declarations — separate callbacks per signature
// ──────────────────────────────────────────────────

static void contactFrameCallback5(int deviceIndex, void *data,
                                   int count, double timestamp, int frame);
static void contactFrameCallback6(int deviceIndex, void *data,
                                   int count, double timestamp, int frame,
                                   void *refcon);

// Shared callback logic
static void processContactData(int deviceIndex, void *data,
                                int count, double timestamp, int frame);

// ──────────────────────────────────────────────────
// Public API
// ──────────────────────────────────────────────────

void gesture_engine_set_sensitivity(float tapDuration, float tapDisp,
                                     float swipeDisp, float swipeDur) {
    tapMaxDurationSec   = tapDuration;
    tapMaxDisplacement  = tapDisp;
    swipeMinDisplacement = swipeDisp;
    swipeMinDuration    = swipeDur;
}

void gesture_engine_set_touchdown_window(double windowSec) {
    if (windowSec < 0.001) windowSec = 0.001;
    maxTouchdownWindow = windowSec;
}

int gesture_engine_start_safe(void) {
    if (engineRunning) return 1;

    mtLibHandle = dlopen(
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
        RTLD_LAZY);
    if (!mtLibHandle) {
        ws_log("[WS] dlopen MultitouchSupport failed: %s\n", dlerror());
        return -1;
    }

    MTDeviceCreateListFunc MTDeviceCreateList =
        (MTDeviceCreateListFunc)dlsym(mtLibHandle, "MTDeviceCreateList");
    pMTDeviceStart = (MTDeviceStartFunc)dlsym(mtLibHandle, "MTDeviceStart");
    pMTDeviceStop  = (MTDeviceStopFunc)dlsym(mtLibHandle, "MTDeviceStop");

    if (!MTDeviceCreateList || !pMTDeviceStart) {
        ws_log("[WS] dlsym failed (safe mode)\n");
        dlclose(mtLibHandle);
        mtLibHandle = NULL;
        return -2;
    }

    mtDevice = MTDeviceCreateList();
    if (!mtDevice) {
        ws_log("[WS] no multitouch device found\n");
        dlclose(mtLibHandle);
        mtLibHandle = NULL;
        return -3;
    }

    if (!stateLockInited) {
        pthread_mutex_init(&stateLock, NULL);
        stateLockInited = true;
    }
    pMTDeviceStart(mtDevice, 0);
    engineRunning = true;
    ws_log("[WS] Gesture engine started (safe mode, no callback)\n");
    return 0;
}

int gesture_engine_start(GestureCallback callback) {
    // If engine was already running, stop first
    if (engineRunning) {
        ws_log("[WS] stopping previous engine instance...\n");
        frameStarvationTimerStop();
        if (mtDevice && pMTUnregisterCB5) {
            pMTUnregisterCB5(mtDevice, contactFrameCallback5);
        }
        if (mtDevice && pMTUnregisterCB6) {
            pMTUnregisterCB6(mtDevice, contactFrameCallback6);
        }
        if (mtDevice && pMTDeviceStop) {
            pMTDeviceStop(mtDevice);
        }
        mtDevice = NULL;
        engineRunning = false;
        userCallback = NULL;
    }

    install_signal_handlers();

    // Load framework if not already loaded
    if (!mtLibHandle) {
        mtLibHandle = dlopen(
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
            RTLD_LAZY);
        if (!mtLibHandle) {
            ws_log("[WS] dlopen failed: %s\n", dlerror());
            return -1;
        }
    }

    // Resolve all symbols
    MTDeviceCreateDefaultFunc MTDeviceCreateDefault =
        (MTDeviceCreateDefaultFunc)dlsym(mtLibHandle, "MTDeviceCreateDefault");
    MTDeviceCreateListFunc MTDeviceCreateList =
        (MTDeviceCreateListFunc)dlsym(mtLibHandle, "MTDeviceCreateList");
    pMTDeviceStart  = (MTDeviceStartFunc)dlsym(mtLibHandle, "MTDeviceStart");
    pMTDeviceStop   = (MTDeviceStopFunc)dlsym(mtLibHandle, "MTDeviceStop");
    pMTRegisterCB5  = (MTRegisterContactFrameCallbackFunc)dlsym(mtLibHandle,
                          "MTRegisterContactFrameCallback");
    pMTRegisterCB6  = (MTRegisterContactFrameCallbackWithRefconFunc)dlsym(mtLibHandle,
                          "MTRegisterContactFrameCallbackWithRefcon");
    pMTUnregisterCB5 = (MTUnregisterContactFrameCallbackFunc)dlsym(mtLibHandle,
                          "MTUnregisterContactFrameCallback");
    pMTUnregisterCB6 = (MTUnregisterContactFrameCallbackWithRefconFunc)dlsym(mtLibHandle,
                          "MTUnregisterContactFrameCallbackWithRefcon");

    ws_log("[WS] Symbol resolution:\n");
    ws_log("[WS]   MTDeviceCreateDefault    => %p\n", (void*)MTDeviceCreateDefault);
    ws_log("[WS]   MTDeviceCreateList       => %p\n", (void*)MTDeviceCreateList);
    ws_log("[WS]   MTDeviceStart            => %p\n", (void*)pMTDeviceStart);
    ws_log("[WS]   MTDeviceStop             => %p\n", (void*)pMTDeviceStop);
    ws_log("[WS]   MTRegisterContactFrameCallback          => %p\n", (void*)pMTRegisterCB5);
    ws_log("[WS]   MTRegisterContactFrameCallbackWithRefcon => %p\n", (void*)pMTRegisterCB6);
    ws_log("[WS]   MTUnregisterContactFrameCallback          => %p\n", (void*)pMTUnregisterCB5);
    ws_log("[WS]   MTUnregisterContactFrameCallbackWithRefcon => %p\n", (void*)pMTUnregisterCB6);

    // Create device
    if (MTDeviceCreateDefault) {
        mtDevice = MTDeviceCreateDefault();
        ws_log("[WS] MTDeviceCreateDefault => %p\n", mtDevice);
    }
    if (!mtDevice && MTDeviceCreateList) {
        mtDevice = MTDeviceCreateList();
        ws_log("[WS] MTDeviceCreateList => %p\n", mtDevice);
    }
    if (!mtDevice) {
        ws_log("[WS] no multitouch device found\n");
        return -3;
    }

    if (!stateLockInited) {
        pthread_mutex_init(&stateLock, NULL);
        stateLockInited = true;
    }
    userCallback = callback;
    callbackCallCount = 0;
    callbackErrorCount = 0;
    // Reset gesture state machine. Static variables survive stop/start
    // cycles — clear them defensively so stale values don't break detection.
    gState = GS_IDLE;
    atomic_store(&trackingActive, false);
    gestureSessionID = 0;
    prevFingerCount = 0;
    lastFingerCount = 0;
    touchdownStartTime = 0;
    touchStartTime = 0;
    settlingEndTime = 0;
    swipeActionFired = false;
    isHorizontalSwipe = false;
    touchdownExceededThree = false;
    lastFrame = 0;

    // ── Strategy: stop device, register callback, then start device ──
    // Some macOS versions need the device to be freshly started after
    // callback registration for frame delivery to begin.

    // Step 1: Stop the device (idempotent if already stopped)
    if (pMTDeviceStop) {
        int stopResult = pMTDeviceStop(mtDevice);
        ws_log("[WS] MTDeviceStop => %d (0x%x)\n", stopResult, stopResult);
    }

    // Step 2: Register callback — try WithRefcon (6-param) first, fall back to 5-param
    // Return value: 1 = success, 0 = failure, negative = error
    int regResult = -1;
    bool callbackRegistered = false;
    if (pMTRegisterCB6) {
        ws_log("[WS] Registering 6-param callback (WithRefcon)...\n");
        regResult = pMTRegisterCB6(mtDevice, contactFrameCallback6);
        ws_log("[WS] MTRegisterContactFrameCallbackWithRefcon => %d (0x%x)\n",
                regResult, regResult);
        if (regResult == 1) callbackRegistered = true;
    }
    if (!callbackRegistered && pMTRegisterCB5) {
        ws_log("[WS] 6-param unavailable, registering 5-param callback...\n");
        regResult = pMTRegisterCB5(mtDevice, contactFrameCallback5);
        ws_log("[WS] MTRegisterContactFrameCallback => %d (0x%x)\n",
                regResult, regResult);
        if (regResult == 1) callbackRegistered = true;
    }

    // Step 3: Start the device
    int startResult = -1;
    if (pMTDeviceStart) {
        ws_log("[WS] Calling MTDeviceStart(mtDevice, 0)...\n");
        startResult = pMTDeviceStart(mtDevice, 0);
        ws_log("[WS] MTDeviceStart => %d (0x%x)\n", startResult, startResult);

        // If mode 0 fails with "not permitted" (-536870187), the device
        // might already be active — that's OK as long as callback is registered.
        if (startResult != 0 && startResult != -536870187) {
            // Try mode 1
            ws_log("[WS] Mode 0 failed, trying mode 1...\n");
            startResult = pMTDeviceStart(mtDevice, 1);
            ws_log("[WS] MTDeviceStart(mode=1) => %d (0x%x)\n",
                    startResult, startResult);
        }
    }

    engineRunning = true;
    lastFrameTime = ws_monotonic_now();
    frameStarvationTimerStart();
    ws_log("[WS] Gesture engine started (reg=%d, start=%d). "
            "Waiting for callbacks...\n", regResult, startResult);
    return 0;
}

void gesture_engine_stop(void) {
    // 先停定时器再清 userCallback，避免定时器触发时 userCallback 已为 NULL。
    frameStarvationTimerStop();
    engineRunning = false;
    userCallback = NULL;
    // Clear the tracking flag too: if stopped mid-gesture it would otherwise
    // linger as true and block all scroll reorders until the next start.
    atomic_store(&trackingActive, false);

    if (mtDevice) {
        if (pMTUnregisterCB5) {
            pMTUnregisterCB5(mtDevice, contactFrameCallback5);
        }
        if (pMTUnregisterCB6) {
            pMTUnregisterCB6(mtDevice, contactFrameCallback6);
        }
        if (pMTDeviceStop) {
            pMTDeviceStop(mtDevice);
        }
        mtDevice = NULL;
    }

    // NOTE: stateLock is intentionally left initialized. Destroying it here
    // races with a contact-frame callback already past its engineRunning check
    // that is about to lock stateLock — use-after-destroy on restart.

    pMTDeviceStart  = NULL;
    pMTDeviceStop   = NULL;
    pMTRegisterCB5  = NULL;
    pMTRegisterCB6  = NULL;
    pMTUnregisterCB5 = NULL;
    pMTUnregisterCB6 = NULL;

    ws_log("[WS] Gesture engine stopped (total callbacks received: %d, errors: %d)\n",
            callbackCallCount, callbackErrorCount);
}

bool gesture_engine_is_running(void) {
    return engineRunning;
}

bool gesture_engine_is_tracking(void) {
    return atomic_load(&trackingActive);
}

int gesture_engine_callback_count(void) {
    return callbackCallCount;
}

// ──────────────────────────────────────────────────
// Callback variants — one per signature
// ──────────────────────────────────────────────────

static void contactFrameCallback5(int deviceIndex, void *data,
                                   int count, double timestamp, int frame) {
    callbackCallCount++;
    processContactData(deviceIndex, data, count, timestamp, frame);
}

static void contactFrameCallback6(int deviceIndex, void *data,
                                   int count, double timestamp, int frame,
                                   void *refcon) {
    callbackCallCount++;
    if (count >= 3) {
        ws_log("[WS] CB6: count=%d frame=%d\n", count, frame);
    }
    processContactData(deviceIndex, data, count, timestamp, frame);
}

// ──────────────────────────────────────────────────
// Shared callback logic — gesture recognition
// ──────────────────────────────────────────────────

// 连续快甩诊断：swipeUpdate 轨迹（15ms 限流 ≈60Hz，还原方向/峰值/折返，防刷屏）。
// timestamp 为 MT 帧时间戳（单调递增），session 为 gestureSessionID。
static void logSwipeUpdateDiag(double timestamp, int session, float progress,
                               float dispX, float settledX) {
    static double lastLog = 0;
    if (timestamp - lastLog < 0.015) return;
    lastLog = timestamp;
    ws_log("[WS-DBG] SESSION[%d] swipeUpdate p=%.3f dispX=%.4f settledX=%.4f\n",
           session, progress, dispX, settledX);
}

// 会话峰值横向速度（progress/sec，带符号）：用 MT 帧时间戳计算逐帧瞬时速度，取
// |值| 最大者。甩动中段的峰值方向=甩动方向，规避「抬手最后 50ms 速度」的三种
// 失真（主线程批处理时间基退化/折返反号/抬手前停顿）。首个采样帧仅记录不做速度
// 计算（lastVelTimestamp==0），从第二帧起连续计算。
//
// 方向过滤：峰值只计入与主甩动方向一致的瞬时速度。sessionMaxProgress 记录会话内
// |progress| 最大值（带符号），其符号即主方向；折返/回摆阶段的 instVel 与主方向
// 相反，一律排除——否则 boost 与 offset 反向相消会把 effective 拉回阈值以下造成
// 误回弹（实测 19:41:41.377：offset=-1297 但峰值捕获 +88.5/s 回摆速度 → 回弹）。
static void updatePeakVelocity(double timestamp, float progress) {
    if (fabsf(progress) > fabsf(sessionMaxProgress)) sessionMaxProgress = progress;
    if (lastVelTimestamp > 0) {
        double dt = timestamp - lastVelTimestamp;
        if (dt > 0.001) {
            float instVel = (float)((progress - lastVelProgress) / dt);
            // 抬手前即时速度均值：保留真实符号（不过滤方向），供路径A方向保护使用。
            instVelBuffer[instVelIdx] = instVel;
            instVelIdx = (instVelIdx + 1) % 3;
            if (instVelCount < 3) instVelCount++;
            if (instVelCount > 0) {
                float sum = 0;
                for (int i = 0; i < instVelCount; i++) sum += instVelBuffer[i];
                releaseInstVel = sum / instVelCount;
            }
            // 峰值仅计入与主甩动方向一致的瞬时速度（折返/回摆阶段反向帧排除）。
            if (sessionMaxProgress == 0 || instVel * sessionMaxProgress > 0) {
                if (fabsf(instVel) > fabsf(sessionPeakVel)) sessionPeakVel = instVel;
            }
        }
    }
    lastVelProgress = progress;
    lastVelTimestamp = timestamp;
}

static void processContactData(int deviceIndex, void *data,
                                int count, double timestamp, int frame) {
    (void)deviceIndex;

    // Guard the userCallback/engineRunning read so a stop/start from the main
    // thread can't tear it mid-restart. The state machine below re-locks.
    pthread_mutex_lock(&stateLock);
    bool streamAlive = engineRunning && (userCallback != NULL);
    // 任何送达的帧都重置帧饥饿时钟——定时器只在长时间无帧时兜底。
    lastFrameTime = ws_monotonic_now();
    lastContactTimestamp = timestamp;   // MT 帧时间戳域，供 TRACKING 帧饥饿兜底的快甩会话期判别
    pthread_mutex_unlock(&stateLock);
    if (!streamAlive) {
        // Rate-limited: log only once per 120 frames when stream is dead
        static int deadStreamLogCounter = 0;
        if (++deadStreamLogCounter % 120 == 1) {
            ws_log("[WS-DBG] processContactData: stream NOT alive (engineRunning=%d callback=%p)\n",
                   engineRunning, (void*)userCallback);
        }
        return;
    }
    if (count <= 0 || !data) return;

    const uint8_t *contacts = (const uint8_t *)data;

    // Rate-limited heartbeat log — proves callbacks are arriving
    static int heartbeatCounter = 0;
    if (++heartbeatCounter % 120 == 1) {
        ws_log("[WS-DBG] processContactData: ALIVE frame=%d count=%d\n", frame, count);
    }

    // Count active fingers and compute centroid
    int fingerCount = 0;
    float sumX = 0, sumY = 0;
    for (int i = 0; i < count && i < 20; i++) {
        const uint8_t *c = contacts + i * CONTACT_STRUCT_SIZE;
        int32_t state = contact_read_int32(c, CONTACT_OFFSET_STATE);
        // State >= 4 = actual touch (st=1/2/3 are hover/proximity ghosts).
        if (state >= 4) {
            float x = contact_read_float(c, CONTACT_OFFSET_POS_X);
            float y = contact_read_float(c, CONTACT_OFFSET_POS_Y);
            sumX += x;
            sumY += y;
            fingerCount++;
        }
    }

    // Log when finger count changes, with raw contact fields to distinguish
    // hover (proximity) from actual touch.
    if (fingerCount != lastFingerCount) {
        ws_log("[WS-DBG] fingerCount: %d -> %d (totalContacts=%d)\n",
               lastFingerCount, fingerCount, count);
        // Dump raw fields for every contact slot to see hover vs touch values.
        ws_log("[WS-DBG]   RAW: ");
        for (int i = 0; i < count && i < 10; i++) {
            const uint8_t *rc = contacts + i * CONTACT_STRUCT_SIZE;
            int32_t st  = contact_read_int32(rc, CONTACT_OFFSET_STATE);
            int32_t ty  = contact_read_int32(rc, CONTACT_OFFSET_TYPE);
            int32_t fl  = contact_read_int32(rc, CONTACT_OFFSET_FLAGS);
            float   pz  = contact_read_float(rc, CONTACT_OFFSET_POS_Z);
            float   px  = contact_read_float(rc, CONTACT_OFFSET_POS_X);
            float   py  = contact_read_float(rc, CONTACT_OFFSET_POS_Y);
            ws_log("[%d]st=%d,ty=%d,fl=%d,z=%.4f,x=%.3f,y=%.3f%s",
                   i, st, ty, fl, pz, px, py,
                   (i + 1 < count ? " " : ""));
        }
        ws_log("\n");
        lastFingerCount = fingerCount;
    }

    float centroidX = (fingerCount > 0) ? sumX / (float)fingerCount : 0;
    float centroidY = (fingerCount > 0) ? sumY / (float)fingerCount : 0;

    pthread_mutex_lock(&stateLock);

    switch (gState) {
    case GS_IDLE:
        // Track when the first finger appears (0→>0 transition).
        if (fingerCount > 0 && prevFingerCount == 0) {
            touchdownStartTime = timestamp;
        }
        // Reset window when all fingers lift.
        if (fingerCount == 0) {
            touchdownStartTime = 0;
            touchdownExceededThree = false;
        }
        // 严格三指限定：只要本触摸会话出现过 >3 指（实触 fingerCount>3，或含悬停
        // 槽 totalContacts>3），立即标记，本次会话彻底不进入 TRACKING——系统四指
        // 手势（四指轻扫/拇指捏合等）与三指手势在设计上明确区分，应用绝不污染它们。
        if (fingerCount > 3 || count > 3) {
            touchdownExceededThree = true;
        }

        if (fingerCount == 3 && !touchdownExceededThree) {
            // If no 0→>0 transition was observed (engine just started, or
            // touchdownStartTime was reset), treat this frame as simultaneous.
            if (touchdownStartTime == 0) {
                touchdownStartTime = timestamp;
            }
            double sinceFirst = timestamp - touchdownStartTime;
            if (sinceFirst <= maxTouchdownWindow) {
                // Valid: all three fingers arrived within the touchdown window.
                gState = GS_TRACKING;
                atomic_store(&trackingActive, true);
                gestureSessionID++;
                userCallback(GestureTrackingBegan, 0);
                sessionPeakVel = 0;
                lastVelProgress = 0;
                lastVelTimestamp = 0;
                sessionMaxProgress = 0;
                releaseInstVel = 0;
                instVelCount = 0;
                instVelIdx = 0;
                touchStartTime = timestamp;
                settlingEndTime = timestamp + SETTLING_DURATION;
                touchStartCentroidX = centroidX;
                touchStartCentroidY = centroidY;
                settledCentroidX = centroidX;
                settledCentroidY = centroidY;
                lastCentroidX = centroidX;
                lastCentroidY = centroidY;
                maxPostSettleDisp = 0;
                activeFingerCount = fingerCount;
                ws_log("[WS-DBG] STATE: IDLE -> TRACKING [session=%d] "
                       "(touchdown %.0fms, prevFinger=%d)\n",
                       gestureSessionID, sinceFirst * 1000, prevFingerCount);
            } else {
                // Rolling touchdown: took too long for all 3 to arrive,
                // or fingers were already resting on trackpad.
                ws_log("[WS-DBG] GESTURE: REJECTED rolling touchdown "
                       "(%.0fms > %.0fms window, prevFinger=%d)\n",
                       sinceFirst * 1000, maxTouchdownWindow * 1000,
                       prevFingerCount);
            }
        }
        break;

    case GS_TRACKING: {
        // 严格三指守卫：TRACKING 期第4指才落下（Pattern B——IDLE 门帧第4指仍是悬停
        // st=3，进入 TRACKING 后 1-3 帧才转实触）。此时尚未触发滑动（swipe 需 200ms+，
        // 第4指 10-30ms 即注册），发 GestureEnd 安全——Swift 侧 slideTransition 未激活，
        // finishSlideSession 不会被调用，不会发生窗口切换。
        if (fingerCount > 3) {
            userCallback(GestureEnd, 0);
            ws_log("[WS-DBG] STATE: TRACKING -> IDLE [session=%d] (4th finger down, fingerCount=%d) GestureEnd fired\n",
                   gestureSessionID, fingerCount);
            gState = GS_IDLE;
            atomic_store(&trackingActive, false);
            swipeActionFired = false;
            isHorizontalSwipe = false;
            touchdownExceededThree = true;
            break;
        }

        double elapsed = timestamp - touchStartTime;
        bool inSettling = (timestamp < settlingEndTime);

        if (fingerCount < 2) {
            // Fingers lifted — log final trajectory for analysis.
            {
                float finalDX = lastCentroidX - settledCentroidX;
                float finalDY = lastCentroidY - settledCentroidY;
                float ratio = (fabsf(finalDY) > 0.0001f) ? fabsf(finalDX) / fabsf(finalDY) : 99.0f;
                ws_log("[WS-DBG] TRAJECTORY: lift [session=%d] "
                       "dX=%.4f dY=%.4f |dX/dY|=%.2f maxDisp=%.4f elapsed=%.0fms\n",
                       gestureSessionID, finalDX, finalDY, ratio,
                       maxPostSettleDisp, elapsed * 1000);
            }
            double settleElapsed = timestamp - (settlingEndTime - SETTLING_DURATION);
            // Use post-settle displacement for tap detection
            if (elapsed <= tapMaxDurationSec && maxPostSettleDisp < tapMaxDisplacement) {
                userCallback(GestureThreeFingerTap, 0);
                ws_log("[WS-DBG] GESTURE: Three-finger tap [session=%d] (%.0fms, postSettleDisp=%.4f)\n",
                       gestureSessionID, elapsed * 1000, maxPostSettleDisp);
            } else {
                ws_log("[WS-DBG] PEAK: session=%d peak=%.3f maxProgress=%.3f\n",
                       gestureSessionID, sessionPeakVel, sessionMaxProgress);
                userCallback(GestureSwipePeakVelocity, sessionPeakVel);
                userCallback(GestureReleaseVelocity, releaseInstVel);
                userCallback(GestureEnd, 0);
                if (elapsed > tapMaxDurationSec) {
                    ws_log("[WS-DBG] STATE: TRACKING -> IDLE [session=%d] (lift after %.0fms > %.0fms) GestureEnd fired\n",
                           gestureSessionID, elapsed * 1000, tapMaxDurationSec * 1000);
                } else {
                    ws_log("[WS-DBG] STATE: TRACKING -> IDLE [session=%d] (postSettleDisp=%.4f >= %.4f) GestureEnd fired\n",
                           gestureSessionID, maxPostSettleDisp, tapMaxDisplacement);
                }
            }
            gState = GS_IDLE;
            atomic_store(&trackingActive, false);
            swipeActionFired = false;
            isHorizontalSwipe = false;
        } else if (inSettling) {
            // Still in settling period — update settled centroid, don't detect swipes
            settledCentroidX = centroidX;
            settledCentroidY = centroidY;
        } else {
            // Post-settling — check for swipe from settled position
            float dispX = centroidX - settledCentroidX;
            float dispY = centroidY - settledCentroidY;
            float totalDisp = sqrtf(dispX * dispX + dispY * dispY);
            if (totalDisp > maxPostSettleDisp) maxPostSettleDisp = totalDisp;

            // Debug: log displacement values when there's significant vertical movement
            // (rate-limited: once per 30 frames)
            static int dbgFrame = 0;
            if (fabsf(dispY) > swipeMinDisplacement * 0.2f || fabsf(dispX) > swipeMinDisplacement * 0.2f) {
                if (++dbgFrame % 30 == 1) {
                    ws_log("[WS-DBG] TRACK postSettle: dispX=%.4f dispY=%.4f |dX|=%.4f |dY|=%.4f "
                           "swipeMinDisp=%.4f elapsed=%.0fms\n",
                           dispX, dispY, fabsf(dispX), fabsf(dispY),
                           swipeMinDisplacement, (timestamp - settlingEndTime) * 1000);
                }
            }

            // Direction detection (post-settling).
            //
            // Vertical (UP/DOWN): 1.5x ratio + 1.5x min displacement, fired
            // immediately on the first qualifying frame. Semantics are now
            // unambiguous (three-finger = window operation), so the former
            // 3.0x ratio + 60ms confirmation period — a differentiator for
            // when three-finger also scrolled pages — is no longer needed;
            // diagonal swipes satisfy this relaxed ratio only on genuinely
            // vertical trajectories.
            //
            // Horizontal (LEFT/RIGHT): 2.0x ratio + immediate fire so elastic
            // drag feedback stays responsive.
            //
            // SwipeUpdate: fires for partial horizontal progress to drive
            // elastic drag, guarded by |dX| > |dY| to skip vertical swipes.

            if (elapsed >= SETTLING_DURATION + swipeMinDuration) {
                if (dispY > swipeMinDisplacement * 1.5f && fabsf(dispY) > fabsf(dispX) * 1.5f) {
                    gState = GS_SWIPING;
                    swipeActionFired = true;
                    isHorizontalSwipe = false;
                    userCallback(GestureThreeFingerSwipeUp, 1.0);
                    ws_log("[WS-DBG] GESTURE: swipe UP [session=%d] dX=%.4f dY=%.4f |dX/dY|=%.2f\n",
                           gestureSessionID, dispX, dispY,
                           fabsf(dispY) > 0.0001f ? fabsf(dispX) / fabsf(dispY) : 99.0f);
                } else if (dispY < -swipeMinDisplacement * 1.5f && fabsf(dispY) > fabsf(dispX) * 1.5f) {
                    gState = GS_SWIPING;
                    swipeActionFired = true;
                    isHorizontalSwipe = false;
                    userCallback(GestureThreeFingerSwipeDown, 1.0);
                    ws_log("[WS-DBG] GESTURE: swipe DOWN [session=%d] dX=%.4f dY=%.4f |dX/dY|=%.2f\n",
                           gestureSessionID, dispX, dispY,
                           fabsf(dispY) > 0.0001f ? fabsf(dispX) / fabsf(dispY) : 99.0f);
                }
            }

            if (gState == GS_TRACKING) {
                if (fabsf(dispX) >= swipeMinDisplacement && fabsf(dispX) > fabsf(dispY) * 2.0f
                    && elapsed >= SETTLING_DURATION + swipeMinDuration) {
                    gState = GS_SWIPING;
                    swipeActionFired = true;
                    float ratio = fabsf(dispY) > 0.0001f ? fabsf(dispX) / fabsf(dispY) : 99.0f;
                    isHorizontalSwipe = true;
                    if (dispX > 0) {
                        userCallback(GestureThreeFingerSwipeRight, 1.0);
                        ws_log("[WS-DBG] GESTURE: swipe RIGHT [session=%d] dX=%.4f dY=%.4f |dX/dY|=%.2f\n",
                               gestureSessionID, dispX, dispY, ratio);
                    } else {
                        userCallback(GestureThreeFingerSwipeLeft, 1.0);
                        ws_log("[WS-DBG] GESTURE: swipe LEFT [session=%d] dX=%.4f dY=%.4f |dX/dY|=%.2f\n",
                               gestureSessionID, dispX, dispY, ratio);
                    }
                    touchStartCentroidX = centroidX;
                    touchStartCentroidY = centroidY;
                } else if (fabsf(dispX) > swipeMinDisplacement * 0.3 && fabsf(dispX) > fabsf(dispY)) {
                    // 跟踪期 progress 不钳制：反映真实位移（offset 随手指全量跟手），
                    // 并为上层甩动动量提供真实的释放速度采样。弹性拖拽路径内部自带钳制，
                    // 不依赖此处的 ±1 上限。
                    float progress = dispX / swipeMinDisplacement;
                    logSwipeUpdateDiag(timestamp, gestureSessionID, progress, dispX, settledCentroidX);
                    updatePeakVelocity(timestamp, progress);
                    userCallback(GestureSwipeUpdate, progress);
                }
            }
        }
        lastCentroidX = centroidX;
        lastCentroidY = centroidY;
        break;
    }

    case GS_SWIPING:
        // 严格三指守卫：滑动期第4指落下（漏网之鱼），立即发完整结束序列终止会话。
        // 已进入 SWIPING 说明滑动动作可能已触发过，发 releaseVelocity+GestureEnd 让
        // 上层走正常收尾判定（提交/回弹），不再继续跟手；置位 touchdownExceededThree
        // 阻止剩余 3 指在本次触摸持续期间再次进入 TRACKING。
        if (fingerCount > 3) {
            ws_log("[WS-DBG] PEAK: session=%d peak=%.3f maxProgress=%.3f\n",
                   gestureSessionID, sessionPeakVel, sessionMaxProgress);
            userCallback(GestureSwipePeakVelocity, sessionPeakVel);
            userCallback(GestureReleaseVelocity, releaseInstVel);
            userCallback(GestureEnd, 0);
            ws_log("[WS-DBG] STATE: SWIPING -> IDLE [session=%d] (4th finger down, fingerCount=%d) GestureEnd fired\n",
                   gestureSessionID, fingerCount);
            gState = GS_IDLE;
            atomic_store(&trackingActive, false);
            swipeActionFired = false;
            isHorizontalSwipe = false;
            touchdownExceededThree = true;
            break;
        }
        // Detect callback interruption: if the system frame counter jumped,
        // callbacks were suspended and fingers likely lifted during the gap.
        if (frame - lastFrame > 30) {
            ws_log("[WS-DBG] PEAK: session=%d peak=%.3f maxProgress=%.3f\n",
                   gestureSessionID, sessionPeakVel, sessionMaxProgress);
            userCallback(GestureSwipePeakVelocity, sessionPeakVel);
            userCallback(GestureReleaseVelocity, releaseInstVel);
            userCallback(GestureEnd, 0);
            ws_log("[WS-DBG] STATE: SWIPING -> IDLE [session=%d] (callback gap, frame %d->%d) GestureEnd fired\n",
                   gestureSessionID, lastFrame, frame);
            gState = GS_IDLE;
            atomic_store(&trackingActive, false);
            swipeActionFired = false;
            isHorizontalSwipe = false;
        } else if (fingerCount < 3) {
            ws_log("[WS-DBG] PEAK: session=%d peak=%.3f maxProgress=%.3f\n",
                   gestureSessionID, sessionPeakVel, sessionMaxProgress);
            userCallback(GestureSwipePeakVelocity, sessionPeakVel);
            userCallback(GestureReleaseVelocity, releaseInstVel);
            userCallback(GestureEnd, 0);
            {
                float finalDX = centroidX - settledCentroidX;
                float finalDY = centroidY - settledCentroidY;
                float ratio = (fabsf(finalDY) > 0.0001f) ? fabsf(finalDX) / fabsf(finalDY) : 99.0f;
                ws_log("[WS-DBG] TRAJECTORY: swipe-end [session=%d] dX=%.4f dY=%.4f |dX/dY|=%.2f\n",
                       gestureSessionID, finalDX, finalDY, ratio);
            }
            ws_log("[WS-DBG] STATE: SWIPING -> IDLE [session=%d] (lift, fingerCount=%d) GestureEnd fired\n",
                   gestureSessionID, fingerCount);
            gState = GS_IDLE;
            atomic_store(&trackingActive, false);
            swipeActionFired = false;
            isHorizontalSwipe = false;
        } else if (isHorizontalSwipe) {
            float dispX = centroidX - settledCentroidX;
            float progress = dispX / swipeMinDisplacement;
            logSwipeUpdateDiag(timestamp, gestureSessionID, progress, dispX, settledCentroidX);
            updatePeakVelocity(timestamp, progress);
            userCallback(GestureSwipeUpdate, progress);
        }
        break;
    }

    lastFrame = frame;
    prevFingerCount = fingerCount;
    pthread_mutex_unlock(&stateLock);
}
