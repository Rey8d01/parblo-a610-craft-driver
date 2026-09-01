// clickwatch — prints the click count and the tablet button mask of every
// mouse press the system delivers. Passive tap, listens only.
//
// clang -O2 -o clickwatch clickwatch.c -framework CoreGraphics -framework CoreFoundation
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdio.h>

static double gT0;
static double now_s(void) { return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1e9; }

static const char *tname(CGEventType t) {
    switch (t) {
        case kCGEventLeftMouseDown:   return "LeftDown ";
        case kCGEventLeftMouseUp:     return "LeftUp   ";
        case kCGEventRightMouseDown:  return "RightDown";
        case kCGEventRightMouseUp:    return "RightUp  ";
        case kCGEventOtherMouseDown:  return "OtherDown";
        case kCGEventOtherMouseUp:    return "OtherUp  ";
        case kCGEventLeftMouseDragged:  return "LeftDrag ";
        case kCGEventRightMouseDragged: return "RightDrag";
        case kCGEventOtherMouseDragged: return "OtherDrag";
        case kCGEventTabletProximity: return "Proximity";
        default:                      return "?        ";
    }
}

static CGEventRef cb(CGEventTapProxy p, CGEventType t, CGEventRef e, void *ctx) {
    (void)p; (void)ctx;
    if (t == kCGEventTapDisabledByTimeout || t == kCGEventTapDisabledByUserInput) return e;
    int64_t sub   = CGEventGetIntegerValueField(e, kCGMouseEventSubtype);
    int64_t click = CGEventGetIntegerValueField(e, kCGMouseEventClickState);
    int64_t mask  = CGEventGetIntegerValueField(e, kCGTabletEventPointButtons);
    // Drags arrive at ~120 Hz. Only the ones where the mask changed say anything.
    static int64_t lastDragMask = -1;
    int isDrag = (t == kCGEventLeftMouseDragged || t == kCGEventRightMouseDragged
                  || t == kCGEventOtherMouseDragged);
    if (isDrag) {
        if (mask == lastDragMask) return e;
        lastDragMask = mask;
    } else {
        lastDragMask = -1;
    }
    if (t == kCGEventTabletProximity) {
        int64_t enter = CGEventGetIntegerValueField(e, kCGTabletProximityEventEnterProximity);
        int64_t kind  = CGEventGetIntegerValueField(e, kCGTabletProximityEventPointerType);
        printf("%7.3f  Proximity  %s  pointerType=%lld (%s)\n", now_s() - gT0,
               enter ? "IN " : "OUT", kind,
               kind == 3 ? "ЛАСТИК" : kind == 1 ? "перо" : "?");
        fflush(stdout);
        return e;
    }
    CGPoint at = CGEventGetLocation(e);
    printf("%7.3f  %s  clickState=%lld  tabletButtons=0x%llx  at=(%.0f,%.0f)  subtype=%lld%s\n",
           now_s() - gT0, tname(t), click, mask, at.x, at.y, sub,
           sub == 1 ? " (tablet)" : "");
    fflush(stdout);
    return e;
}

int main(void) {
    gT0 = now_s();
    CGEventMask m = CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp)
                  | CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp)
                  | CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp)
                  | CGEventMaskBit(kCGEventLeftMouseDragged)
                  | CGEventMaskBit(kCGEventRightMouseDragged)
                  | CGEventMaskBit(kCGEventOtherMouseDragged)
                  | CGEventMaskBit(kCGEventTabletProximity);
    CFMachPortRef tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                                        kCGEventTapOptionListenOnly, m, cb, NULL);
    if (!tap) { fprintf(stderr, "tap not created: needs Accessibility for this process\n"); return 1; }
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);
    printf("listening\n"); fflush(stdout);
    CFRunLoopRun();
    return 0;
}
