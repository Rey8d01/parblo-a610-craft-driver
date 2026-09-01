// keyscan — what the express keys of the tablet actually send.
//
// Listens on interface 2 (Keyboard, 0x01/0x06) and decodes the three kinds of
// report that its descriptor declares:
//   ID 3 — normal keyboard: a modifier byte plus up to six key codes
//   ID 4 — Consumer Control: media keys
//   ID 5 — System Control: power off, sleep, wake
//
// The interface is SEIZED for the whole run. Without the seize the presses would
// really work, and sleep and machine power off are among the possible ones.
//
// clang -O2 -o keyscan keyscan.c -framework IOKit -framework CoreFoundation
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VID 0x5543
#define PID 0x0081

static uint8_t gBuf[64];
static uint8_t gSeen[64][9];
static int     gSeenCount = 0;

// Usage Page 0x07 — HID key codes.
static const char *keyName(uint8_t k) {
    static char buf[16];
    if (k >= 0x04 && k <= 0x1D) { snprintf(buf, sizeof buf, "%c", 'A' + k - 0x04); return buf; }
    if (k >= 0x1E && k <= 0x26) { snprintf(buf, sizeof buf, "%c", '1' + k - 0x1E); return buf; }
    switch (k) {
        case 0x27: return "0";
        case 0x28: return "Enter";   case 0x29: return "Esc";
        case 0x2A: return "Backspace"; case 0x2B: return "Tab";
        case 0x2C: return "Space";   case 0x2D: return "-";
        case 0x2E: return "=";       case 0x2F: return "[";
        case 0x30: return "]";       case 0x31: return "\\";
        case 0x33: return ";";       case 0x34: return "'";
        case 0x35: return "`";       case 0x36: return ",";
        case 0x37: return ".";       case 0x38: return "/";
        case 0x39: return "CapsLock";
        case 0x49: return "Insert";  case 0x4A: return "Home";
        case 0x4B: return "PageUp";  case 0x4C: return "Delete";
        case 0x4D: return "End";     case 0x4E: return "PageDown";
        case 0x4F: return "→";       case 0x50: return "←";
        case 0x51: return "↓";       case 0x52: return "↑";
    }
    if (k >= 0x3A && k <= 0x45) { snprintf(buf, sizeof buf, "F%d", k - 0x3A + 1); return buf; }
    // Numeric keypad: these are the codes the tablet sends for + and -.
    switch (k) {
        case 0x53: return "numpad NumLock";
        case 0x54: return "numpad /";   case 0x55: return "numpad *";
        case 0x56: return "numpad −";   case 0x57: return "numpad +";
        case 0x58: return "numpad Enter"; case 0x63: return "numpad .";
    }
    if (k >= 0x59 && k <= 0x61) { snprintf(buf, sizeof buf, "numpad %c", '1' + k - 0x59); return buf; }
    if (k == 0x62) return "numpad 0";
    snprintf(buf, sizeof buf, "0x%02X", k);
    return buf;
}

static const char *consumerName(uint16_t u) {
    static char buf[24];
    switch (u) {
        case 0x00B5: return "next track";
        case 0x00B6: return "previous track";
        case 0x00B7: return "stop";
        case 0x00CD: return "play/pause";
        case 0x00E2: return "mute";
        case 0x00E9: return "volume up";
        case 0x00EA: return "volume down";
        case 0x006F: return "brighter";
        case 0x0070: return "dimmer";
        case 0x0221: return "search";
        case 0x0223: return "home";
        case 0x0224: return "back";
        case 0x0225: return "forward";
    }
    snprintf(buf, sizeof buf, "usage 0x%04X", u);
    return buf;
}

static void printModifiers(uint8_t m) {
    const char *names[8] = {"Ctrl", "Shift", "Alt", "Cmd", "right Ctrl",
                            "right Shift", "right Alt", "right Cmd"};
    for (int i = 0; i < 8; i++) if (m & (1 << i)) printf("%s + ", names[i]);
}

static int alreadySeen(const uint8_t *p, int n) {
    for (int i = 0; i < gSeenCount; i++)
        if (memcmp(gSeen[i], p, n) == 0) return 1;
    if (gSeenCount < 64) { memcpy(gSeen[gSeenCount], p, n); gSeenCount++; }
    return 0;
}

static void onReport(void *ctx, IOReturn res, void *sender, IOHIDReportType type,
                     uint32_t rid, uint8_t *rep, CFIndex len) {
    (void)ctx;(void)res;(void)sender;(void)type;
    if (len <= 0) return;
    uint8_t *p = rep; CFIndex n = len;
    if (n > 0 && p[0] == (uint8_t)rid) { p++; n--; }

    // A key release is all zeros. We only care about the press.
    int empty = 1;
    for (CFIndex i = 0; i < n; i++) if (p[i]) { empty = 0; break; }
    if (empty) return;
    if (alreadySeen(p, (int)n)) return;

    printf("  raw bytes:");
    for (CFIndex i = 0; i < len; i++) printf(" %02X", rep[i]);
    printf("\n      ");

    if (rid == 3 && n >= 7) {
        printModifiers(p[0]);
        int any = 0;
        for (int i = 1; i <= 6; i++) if (p[i]) { printf("%s ", keyName(p[i])); any = 1; }
        if (!any && p[0]) printf("(modifiers only)");
        printf("  ← keyboard\n");
    } else if (rid == 4 && n >= 2) {
        printf("%s  ← media\n", consumerName((uint16_t)(p[0] | (p[1] << 8))));
    } else if (rid == 5 && n >= 1) {
        if (p[0] & 1) printf("POWER OFF ");
        if (p[0] & 2) printf("SLEEP ");
        if (p[0] & 4) printf("WAKE ");
        printf("  ← power control\n");
    } else {
        printf("unknown report ID %u\n", rid);
    }
    fflush(stdout);
}

int main(int argc, char **argv) {
    double secs = (argc > 1) ? atof(argv[1]) : 60.0;

    if (IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted) {
        printf("No Input Monitoring permission.\n"); return 1;
    }

    CFMutableDictionaryRef m = IOServiceMatching("IOHIDDevice");
    const char *keys[4] = { kIOHIDVendorIDKey, kIOHIDProductIDKey,
                            kIOHIDPrimaryUsagePageKey, kIOHIDPrimaryUsageKey };
    int vals[4] = { VID, PID, 0x01, 0x06 };
    for (int i = 0; i < 4; i++) {
        CFNumberRef num = CFNumberCreate(0, kCFNumberIntType, &vals[i]);
        CFStringRef key = CFStringCreateWithCString(0, keys[i], kCFStringEncodingUTF8);
        CFDictionarySetValue(m, key, num);
        CFRelease(num); CFRelease(key);
    }
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (!svc) { printf("The keyboard interface of the tablet was not found.\n"); return 2; }
    IOHIDDeviceRef dev = IOHIDDeviceCreate(kCFAllocatorDefault, svc);
    IOObjectRelease(svc);
    if (!dev) { printf("Could not open the device.\n"); return 2; }

    IOReturn k = IOHIDDeviceOpen(dev, kIOHIDOptionsTypeSeizeDevice);
    if (k == kIOReturnSuccess) {
        printf("Interface seized: presses will NOT reach the system, press them safely.\n");
    } else {
        printf("WARNING: the seize failed (0x%08X).\n", k);
        printf("Presses will really work — sleep and power off may be among them.\n");
        if (IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
            printf("Opening it did not work either.\n"); return 3;
        }
    }

    IOHIDDeviceRegisterInputReportCallback(dev, gBuf, sizeof gBuf, onReport, NULL);
    IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    printf("\n>>> PRESS THE EXPRESS KEYS ONE BY ONE, %.0f SECONDS <<<\n\n", secs);
    fflush(stdout);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, secs, false);

    printf("\n--- distinct presses: %d ---\n", gSeenCount);
    if (gSeenCount == 0) printf("Nothing arrived. Were the keys really pressed?\n");
    return 0;
}
