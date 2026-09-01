// ucinit — reads UC-Logic string descriptor 100 over a USB control transfer.
//
// This is a READ-ONLY GET_DESCRIPTOR request: nothing is written to the device.
// The native Windows and Linux drivers do exactly the same on every connect.
// The documented side effect (see hid-uclogic-params.c, DIGImend):
//   "NOTE: This enables fully-functional tablet mode."
//
// Build:
//   clang -O2 -o ucinit ucinit.c -framework IOKit -framework CoreFoundation
// Run:
//   ./ucinit && ./hidwatch 20 --quiet
//
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdio.h>
#include <string.h>

#define VID 0x5543
#define PID 0x0081

static void dump(const char *t, unsigned char *b, int n) {
    printf("  %s (%d bytes):", t, n);
    for (int i = 0; i < n; i++) printf(" %02X", b[i]);
    printf("\n");
}

static int readStr(IOUSBDeviceInterface **dev, int idx, int len) {
    unsigned char buf[64];
    memset(buf, 0, sizeof buf);

    IOUSBDevRequest r;
    r.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBStandard, kUSBDevice); // 0x80
    r.bRequest      = kUSBRqGetDescriptor;          // 6
    r.wValue        = (kUSBStringDesc << 8) | idx;  // (0x03 << 8) | idx
    r.wIndex        = 0x0409;                       // langid en-US
    r.wLength       = len;
    r.pData         = buf;
    r.wLenDone      = 0;

    IOReturn k = (*dev)->DeviceRequest(dev, &r);
    if (k != kIOReturnSuccess) {
        printf("  string descriptor %d: ERROR 0x%08X%s\n", idx, k,
               (k == kIOReturnNotResponding) ? " (not found — stall/EPIPE)" : "");
        return -1;
    }
    char tag[32];
    snprintf(tag, sizeof tag, "string descriptor %d", idx);
    dump(tag, buf, r.wLenDone);
    return (int)r.wLenDone;
}

int main(void) {
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBHostDevice");
    int v = VID, p = PID;
    CFNumberRef nv = CFNumberCreate(0, kCFNumberIntType, &v);
    CFNumberRef np = CFNumberCreate(0, kCFNumberIntType, &p);
    CFDictionarySetValue(m, CFSTR("idVendor"), nv);
    CFDictionarySetValue(m, CFSTR("idProduct"), np);
    CFRelease(nv); CFRelease(np);

    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (!svc) { printf("Device 5543:0081 not found\n"); return 1; }
    printf("Device found.\n");

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
            kIOCFPlugInInterfaceID, &plug, &score) != kIOReturnSuccess || !plug) {
        printf("IOCreatePlugInInterfaceForService failed\n");
        return 1;
    }

    IOUSBDeviceInterface **dev = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (!dev) { printf("QueryInterface failed\n"); return 1; }

    IOReturn k = (*dev)->USBDeviceOpen(dev);
    if (k != kIOReturnSuccess) {
        printf("USBDeviceOpen: 0x%08X — trying USBDeviceOpenSeize...\n", k);
        k = (*dev)->USBDeviceOpenSeize(dev);
    }
    if (k != kIOReturnSuccess) {
        printf("Could not open the device: 0x%08X\n", k);
        if (k == kIOReturnExclusiveAccess) printf("  held by another driver\n");
        if (k == kIOReturnNotPermitted)    printf("  blocked by policy (needs an entitlement)\n");
        return 2;
    }
    printf("Device is open for a control transfer.\n\n");

    printf("--- reading the UC-Logic init strings ---\n");
    int r100 = readStr(dev, 100, 12);
    readStr(dev, 123, 12);
    readStr(dev, 201, 32);

    if (r100 == 12) {
        printf("\n  String descriptor 100 came back whole — full tablet mode should turn on.\n");
        printf("  Check it:  ./hidwatch 20 --quiet\n");
        printf("  Expect \"IF0 ID7\" lines with X up to 40000 and Y up to 24000.\n");
    }

    (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);
    IOObjectRelease(svc);
    return r100 == 12 ? 0 : 3;
}
