// seizetest — step zero. One run answers three questions at once:
//   1. does full mode hold (pen arrives on IF0, IF1 stays silent),
//   2. does kIOHIDOptionsTypeSeizeDevice go through,
//   3. does the system stop handling the tablet after the seize.
//
// The devices are taken directly through IOServiceGetMatchingServices — without
// IOHIDManagerOpen, which would otherwise open them itself and make the seize useless.
//
// clang -O2 -o seizetest seizetest.c -framework IOKit -framework CoreFoundation -framework CoreGraphics
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <stdio.h>
#include <stdlib.h>

#define VID 0x5543
#define PID 0x0081

static uint8_t  gBuf0[64], gBuf1[64];
static uint64_t gN7 = 0, gN10 = 0, gN1 = 0;
static uint64_t gTap = 0;

// ---- init: read string descriptor 100 -----------------------------------
static int init_full_mode(void) {
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    int v = VID, p = PID;
    CFNumberRef nv = CFNumberCreate(0, kCFNumberIntType, &v);
    CFNumberRef np = CFNumberCreate(0, kCFNumberIntType, &p);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), nv);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), np);
    CFRelease(nv); CFRelease(np);

    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (!svc) return -1;

    IOCFPlugInInterface **plug = NULL; SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
            kIOCFPlugInInterfaceID, &plug, &score) != kIOReturnSuccess || !plug) {
        IOObjectRelease(svc); return -2; }
    IOObjectRelease(svc);

    IOUSBDeviceInterface **dev = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (!dev) return -2;

    IOReturn k = (*dev)->USBDeviceOpen(dev);
    if (k != kIOReturnSuccess) k = (*dev)->USBDeviceOpenSeize(dev);
    if (k != kIOReturnSuccess) { (*dev)->Release(dev); return -3; }

    uint8_t buf[12] = {0};
    IOUSBDevRequest r = {
        .bmRequestType = USBmakebmRequestType(kUSBIn, kUSBStandard, kUSBDevice),
        .bRequest = kUSBRqGetDescriptor, .wValue = (kUSBStringDesc << 8) | 100,
        .wIndex = 0x0409, .wLength = 12, .pData = buf, .wLenDone = 0 };
    k = (*dev)->DeviceRequest(dev, &r);
    (*dev)->USBDeviceClose(dev); (*dev)->Release(dev);
    if (k != kIOReturnSuccess) return -4;

    printf("String descriptor 100: X=%u Y=%u P=%u %u LPI\n",
           buf[2]|(buf[3]<<8), buf[4]|(buf[5]<<8), buf[8]|(buf[9]<<8), buf[10]|(buf[11]<<8));
    return 0;
}

// ---- find the HID interface without IOHIDManagerOpen ---------------------
static IOHIDDeviceRef find_iface(int page, int usage) {
    CFMutableDictionaryRef m = IOServiceMatching("IOHIDDevice");
    int v = VID, p = PID;
    const char *keys[4] = { kIOHIDVendorIDKey, kIOHIDProductIDKey,
                            kIOHIDPrimaryUsagePageKey, kIOHIDPrimaryUsageKey };
    int vals[4] = { v, p, page, usage };
    for (int i = 0; i < 4; i++) {
        CFNumberRef n = CFNumberCreate(0, kCFNumberIntType, &vals[i]);
        CFStringRef s = CFStringCreateWithCString(0, keys[i], kCFStringEncodingUTF8);
        CFDictionarySetValue(m, s, n);
        CFRelease(n); CFRelease(s);
    }
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (!svc) return NULL;
    IOHIDDeviceRef d = IOHIDDeviceCreate(kCFAllocatorDefault, svc);
    IOObjectRelease(svc);
    return d;
}

static void onReport(void *ctx, IOReturn res, void *sender, IOHIDReportType type,
                     uint32_t rid, uint8_t *rep, CFIndex len) {
    (void)ctx;(void)res;(void)sender;(void)type;
    if (len <= 0) return;
    uint8_t *p = rep; CFIndex n = len;
    if (n > 0 && p[0] == (uint8_t)rid) { p++; n--; }

    if (rid == 7 && n >= 7) {
        if (gN7++ % 40 == 0)
            printf("  IF0 ID7   flags=%02X X=%5u Y=%5u P=%4u\n", p[0],
                   p[1]|(p[2]<<8), p[3]|(p[4]<<8), p[5]|(p[6]<<8)), fflush(stdout);
    } else if (rid == 10 && n >= 7) {
        if (gN10++ % 40 == 0)
            printf("  IF1 ID10  flags=%02X X=%5u Y=%5u P=%4u  (compatibility mode!)\n", p[0],
                   p[1]|(p[2]<<8), p[3]|(p[4]<<8), p[5]|(p[6]<<8)), fflush(stdout);
    } else if (rid == 1) {
        gN1++;
    }
}

static CGEventRef onTap(CGEventTapProxy proxy, CGEventType type, CGEventRef e, void *ctx) {
    (void)proxy;(void)ctx;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) return e;
    // Count only what the system itself treats as tablet input.
    if (CGEventGetIntegerValueField(e, kCGMouseEventSubtype) != 0) gTap++;
    return e;
}

int main(int argc, char **argv) {
    double secs = (argc > 1) ? atof(argv[1]) : 20.0;

    if (IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted) {
        printf("No Input Monitoring permission.\n"); return 1; }

    int ir = init_full_mode();
    printf("Init (string descriptor 100): %s\n", ir == 0 ? "ok" : "ERROR");

    IOHIDDeviceRef if0 = find_iface(0x0D, 0x02);
    IOHIDDeviceRef if1 = find_iface(0x01, 0x02);
    printf("IF0 Digitizer: %s   IF1 Mouse: %s\n", if0 ? "found" : "NO", if1 ? "found" : "NO");
    if (!if0) return 2;

    IOReturn k0 = IOHIDDeviceOpen(if0, kIOHIDOptionsTypeSeizeDevice);
    printf("IF0 open(SEIZE) = 0x%08X  %s\n", k0,
           k0 == kIOReturnSuccess ? "SUCCESS" :
           k0 == kIOReturnExclusiveAccess ? "BUSY" :
           k0 == kIOReturnNotPermitted ? "NOT PERMITTED" : "ERROR");
    if (k0 != kIOReturnSuccess) return 3;
    IOHIDDeviceRegisterInputReportCallback(if0, gBuf0, sizeof gBuf0, onReport, NULL);
    IOHIDDeviceScheduleWithRunLoop(if0, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    // We listen on IF1 WITHOUT a seize — only to see if the pen went there instead.
    if (if1 && IOHIDDeviceOpen(if1, kIOHIDOptionsTypeNone) == kIOReturnSuccess) {
        IOHIDDeviceRegisterInputReportCallback(if1, gBuf1, sizeof gBuf1, onReport, NULL);
        IOHIDDeviceScheduleWithRunLoop(if1, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    }

    CGEventMask mask = CGEventMaskBit(kCGEventMouseMoved)
                     | CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp)
                     | CGEventMaskBit(kCGEventLeftMouseDragged) | CGEventMaskBit(kCGEventTabletProximity)
                     | CGEventMaskBit(kCGEventTabletPointer);
    CFMachPortRef tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap,
                                         kCGEventTapOptionListenOnly, mask, onTap, NULL);
    if (tap) {
        CFRunLoopAddSource(CFRunLoopGetCurrent(),
            CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), kCFRunLoopDefaultMode);
        CGEventTapEnable(tap, true);
    }
    printf("CGEventTap: %s\n\n>>> MOVE THE PEN ON THE TABLET FOR %.0f SECONDS <<<\n\n",
           tap ? "on" : "NOT CREATED", secs);
    fflush(stdout);

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, secs, false);

    printf("\n--- totals ---\n");
    printf("  IF0 ID7  (full resolution)   : %llu\n", gN7);
    printf("  IF1 ID10 (compatibility)     : %llu\n", gN10);
    printf("  IF1 ID1  (relative mouse)    : %llu\n", gN1);
    printf("  tablet events in the system  : %llu\n", gTap);
    printf("\n--- verdict ---\n");
    if (gN7 == 0 && gN10 == 0 && gN1 == 0)
        printf("  Not a single report. Did the pen really touch the tablet?\n");
    else if (gN7 == 0)
        printf("  COMPATIBILITY MODE: the pen goes to IF1. The init did not hold.\n");
    else if (gTap == 0)
        printf("  SEIZE WORKS: we get the reports, the system does not handle the tablet.\n");
    else
        printf("  DOUBLE INPUT: the system sends its own tablet events. We need option 2.\n");
    return 0;
}
