// flagscan — what the flags byte of Report ID 7 really means.
//
// The IF0 descriptor claims: bit 6 = In Range, bit 7 = constant.
// The live device does neither: bit 7 is set in every report, and bit 6 is set
// only in the last report before the stream stops — it marks the pen LEAVING,
// the reverse of the declared meaning.
// This tool builds a histogram of the flags byte values and looks at
// what arrives right before a pause (the pen was taken away from the tablet).
// Press both barrel buttons during the run: the upper one is on bit 2, which
// the descriptor calls Eraser, and a run without button presses will miss it.
//
// It waits for the pen by itself: counting starts at the first report, so you
// can start it and pick up the pen without hurrying.
//
// clang -O2 -o flagscan flagscan.c -framework IOKit -framework CoreFoundation
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <stdio.h>
#include <stdlib.h>

#define VID 0x5543
#define PID 0x0081

static uint8_t  gBuf[64];
static uint64_t gHist[256];
static uint64_t gTotal = 0;
static double   gLast = 0, gFirst = 0;
static int      gGaps = 0, gGapsWithBit6 = 0;
static uint8_t  gBeforeGap[8]; static int gNBeforeGap = 0;

static double now_s(void){ return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC)/1e9; }

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
    IOCFPlugInInterface **plug = NULL; SInt32 sc = 0;
    if (IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
            kIOCFPlugInInterfaceID, &plug, &sc) != kIOReturnSuccess || !plug) {
        IOObjectRelease(svc); return -2; }
    IOObjectRelease(svc);
    IOUSBDeviceInterface **dev = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (!dev) return -2;
    IOReturn k = (*dev)->USBDeviceOpen(dev);
    if (k != kIOReturnSuccess) k = (*dev)->USBDeviceOpenSeize(dev);
    if (k != kIOReturnSuccess) { (*dev)->Release(dev); return -3; }
    uint8_t b[12] = {0};
    IOUSBDevRequest r = { .bmRequestType = USBmakebmRequestType(kUSBIn, kUSBStandard, kUSBDevice),
        .bRequest = kUSBRqGetDescriptor, .wValue = (kUSBStringDesc << 8) | 100,
        .wIndex = 0x0409, .wLength = 12, .pData = b, .wLenDone = 0 };
    k = (*dev)->DeviceRequest(dev, &r);
    (*dev)->USBDeviceClose(dev); (*dev)->Release(dev);
    return k == kIOReturnSuccess ? 0 : -4;
}

static IOHIDDeviceRef find_iface(int page, int usage) {
    CFMutableDictionaryRef m = IOServiceMatching("IOHIDDevice");
    const char *keys[4] = { kIOHIDVendorIDKey, kIOHIDProductIDKey,
                            kIOHIDPrimaryUsagePageKey, kIOHIDPrimaryUsageKey };
    int vals[4] = { VID, PID, page, usage };
    for (int i = 0; i < 4; i++) {
        CFNumberRef n = CFNumberCreate(0, kCFNumberIntType, &vals[i]);
        CFStringRef s = CFStringCreateWithCString(0, keys[i], kCFStringEncodingUTF8);
        CFDictionarySetValue(m, s, n); CFRelease(n); CFRelease(s);
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
    if (rid != 7 || len <= 0) return;
    uint8_t *p = rep; CFIndex n = len;
    if (n > 0 && p[0] == (uint8_t)rid) { p++; n--; }
    if (n < 7) return;

    double t = now_s();
    uint8_t f = p[0];

    if (gTotal == 0) { gFirst = t; printf("Pen detected, recording now.\n"); fflush(stdout); }
    else if (t - gLast > 0.8) {
        gGaps++;
        uint8_t before = gNBeforeGap ? gBeforeGap[0] : 0;
        if (before & 0x40) gGapsWithBit6++;
        printf("  PAUSE %.2f s — last flags before it: %02X%s\n", t - gLast, before,
               (before & 0x40) ? "  (bit 6 set — the pen announced it was leaving)" : "");
        fflush(stdout);
    }
    gLast = t;
    gBeforeGap[0] = f; gNBeforeGap = 1;

    if (gHist[f] == 0) {
        printf("  NEW flags value: %02X  ->  bit7=%d bit6=%d bit5=%d bit4=%d "
               "bit3=%d bit2=%d bit1=%d bit0=%d   (P=%u)\n",
               f, !!(f&0x80), !!(f&0x40), !!(f&0x20), !!(f&0x10),
               !!(f&0x08), !!(f&0x04), !!(f&0x02), !!(f&0x01),
               (unsigned)(p[5]|(p[6]<<8)));
        fflush(stdout);
    }
    gHist[f]++;
    gTotal++;
}

int main(int argc, char **argv) {
    double limit = (argc > 1) ? atof(argv[1]) : 150.0;
    if (IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted) {
        printf("No Input Monitoring permission.\n"); return 1; }
    if (init_full_mode() != 0) { printf("Init failed.\n"); return 2; }

    IOHIDDeviceRef if0 = find_iface(0x0D, 0x02);
    if (!if0) { printf("IF0 not found.\n"); return 3; }
    if (IOHIDDeviceOpen(if0, kIOHIDOptionsTypeSeizeDevice) != kIOReturnSuccess) {
        printf("seize failed.\n"); return 4; }
    IOHIDDeviceRegisterInputReportCallback(if0, gBuf, sizeof gBuf, onReport, NULL);
    IOHIDDeviceScheduleWithRunLoop(if0, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    printf("Ready and waiting for the pen (up to %.0f s). Take your time.\n\n", limit);
    fflush(stdout);

    // Run in short slices: we stop as soon as we have collected enough.
    double t0 = now_s();
    while (now_s() - t0 < limit) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
        if (gTotal > 300 && gGaps >= 3) break;
        if (gTotal > 0 && now_s() - gFirst > 60.0) break;
    }

    printf("\n--- histogram of the flags byte (%llu reports) ---\n", gTotal);
    for (int i = 0; i < 256; i++)
        if (gHist[i]) printf("  %02X : %-8llu  bit7=%d bit6=%d bit0=%d\n",
                             i, gHist[i], !!(i&0x80), !!(i&0x40), !!(i&1));

    int bit7_always = 1, bit6_ever = 0, saw_zero_bit7 = 0;
    for (int i = 0; i < 256; i++) if (gHist[i]) {
        if (!(i & 0x80)) { bit7_always = 0; saw_zero_bit7 = 1; }
        if (i & 0x40) bit6_ever = 1;
    }
    printf("\n--- verdict ---\n");
    if (gTotal == 0) { printf("  There were no reports.\n"); return 5; }
    if (bit6_ever)
        printf("  Bit 6 shows up, and it means the OPPOSITE of the descriptor: it is set\n"
               "  when the pen LEAVES. It preceded %d of the %d\n"
               "  pauses here. Treat a set bit 6 as 'gone'; keep the silence timeout for\n"
               "  the case where the stream just stops.\n", gGapsWithBit6, gGaps);
    else if (saw_zero_bit7)
        printf("  Bit 7 GOES OFF → this is In Range. Descriptor lies, use bit 7 for proximity.\n");
    else if (bit7_always)
        printf("  Bit 7 is always 1, bit 6 always 0 → the report has NO In Range flag.\n"
               "  Proximity has to come from a timeout: reports coming = pen in range.\n");
    return 0;
}
