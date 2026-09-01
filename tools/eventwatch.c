// eventwatch — what really reaches the system.
//
// Two passive taps: one at the HID level (where the driver posts) and one at the
// session level (what apps see). If an event shows up in the first one but not in
// the second, the window server drops it, and that is a very different diagnosis
// from "the driver never sent it".
//
// It needs no permission to send events — it only listens.
//
// clang -O2 -o eventwatch eventwatch.c -framework CoreGraphics -framework CoreFoundation
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t gHid[64], gSes[64];
static double gT0;
static int gPrinted = 0;

static double now_s(void){ return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC)/1e9; }

static const char *tname(CGEventType t){
    switch(t){
        case kCGEventMouseMoved:       return "MouseMoved";
        case kCGEventLeftMouseDown:    return "LeftDown";
        case kCGEventLeftMouseUp:      return "LeftUp";
        case kCGEventLeftMouseDragged: return "LeftDragged";
        case kCGEventRightMouseDown:   return "RightDown";
        case kCGEventRightMouseUp:     return "RightUp";
        case kCGEventRightMouseDragged:return "RightDragged";
        case kCGEventOtherMouseDown:   return "OtherDown";
        case kCGEventOtherMouseUp:     return "OtherUp";
        case kCGEventOtherMouseDragged:return "OtherDragged";
        case kCGEventTabletPointer:    return "TabletPointer";
        case kCGEventTabletProximity:  return "TabletProximity";
        default:                       return "?";
    }
}

static CGEventRef tap(CGEventTapProxy proxy, CGEventType type, CGEventRef e, void *ctx){
    (void)proxy;
    int hid = (ctx != NULL);
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        printf("  !! the system turned the tap off, turning it back on\n"); fflush(stdout);
        return e;
    }
    if (type < 64) { if (hid) gHid[type]++; else gSes[type]++; }

    int64_t sub = CGEventGetIntegerValueField(e, kCGMouseEventSubtype);
    // Print only tablet events, and only now and then, so the output stays readable.
    if (sub == 0 && type != kCGEventTabletProximity) return e;

    uint64_t n = (type < 64) ? (hid ? gHid[type] : gSes[type]) : 0;
    if (n > 3 && n % 60 != 0) return e;
    if (gPrinted++ > 400) return e;

    CGPoint p = CGEventGetLocation(e);
    printf("%6.2f %s %-16s (%7.1f,%7.1f) sub=%lld", now_s()-gT0, hid?"HID":"SES",
           tname(type), p.x, p.y, (long long)sub);
    if (sub == 2) {
        printf("  ENTER=%lld pointer-type=%lld mask=0x%llX dev=%lld",
            (long long)CGEventGetIntegerValueField(e, kCGTabletProximityEventEnterProximity),
            (long long)CGEventGetIntegerValueField(e, kCGTabletProximityEventPointerType),
            (unsigned long long)CGEventGetIntegerValueField(e, kCGTabletProximityEventCapabilityMask),
            (long long)CGEventGetIntegerValueField(e, kCGTabletProximityEventDeviceID));
    } else {
        printf("  pressure=%.3f tabletXY=(%lld,%lld) tp=%.3f dev=%lld click=%lld",
            CGEventGetDoubleValueField(e, kCGMouseEventPressure),
            (long long)CGEventGetIntegerValueField(e, kCGTabletEventPointX),
            (long long)CGEventGetIntegerValueField(e, kCGTabletEventPointY),
            CGEventGetDoubleValueField(e, kCGTabletEventPointPressure),
            (long long)CGEventGetIntegerValueField(e, kCGTabletEventDeviceID),
            (long long)CGEventGetIntegerValueField(e, kCGMouseEventClickState));
    }
    printf("\n"); fflush(stdout);
    return e;
}

static CFMachPortRef make(CGEventTapLocation loc, void *ctx){
    CGEventMask mask = CGEventMaskBit(kCGEventMouseMoved)
        | CGEventMaskBit(kCGEventLeftMouseDown)  | CGEventMaskBit(kCGEventLeftMouseUp)
        | CGEventMaskBit(kCGEventLeftMouseDragged)
        | CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp)
        | CGEventMaskBit(kCGEventRightMouseDragged)
        | CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp)
        | CGEventMaskBit(kCGEventOtherMouseDragged)
        | CGEventMaskBit(kCGEventTabletPointer)  | CGEventMaskBit(kCGEventTabletProximity);
    CFMachPortRef t = CGEventTapCreate(loc, kCGTailAppendEventTap,
                                       kCGEventTapOptionListenOnly, mask, tap, ctx);
    if (!t) return NULL;
    CFRunLoopAddSource(CFRunLoopGetCurrent(),
        CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0), kCFRunLoopDefaultMode);
    CGEventTapEnable(t, true);
    return t;
}

int main(int argc, char **argv){
    double secs = (argc > 1) ? atof(argv[1]) : 25.0;
    CFMachPortRef hid = make(kCGHIDEventTap, (void *)1);
    CFMachPortRef ses = make(kCGSessionEventTap, NULL);
    printf("HID tap: %s   session tap: %s\n", hid?"yes":"NO", ses?"yes":"NO");
    if (!hid && !ses) { printf("Neither tap could be created.\n"); return 1; }

    printf("\n>>> MOVE THE PEN FOR %.0f SECONDS <<<\n\n", secs);
    fflush(stdout);
    gT0 = now_s();
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, secs, false);

    printf("\n--- how much of what got through ---\n");
    printf("%-18s %8s %8s\n", "event", "HID", "session");
    for (int t = 0; t < 64; t++)
        if (gHid[t] || gSes[t])
            printf("%-18s %8llu %8llu\n", tname((CGEventType)t), gHid[t], gSes[t]);
    return 0;
}
