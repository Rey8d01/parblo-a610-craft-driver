#include "uclogic.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <string.h>

// String descriptor 100 (12 bytes) — this is the exact length that was tested for the
// mode switch on the real device. The first two bytes are bLength and bDescriptorType.
#define UCLOGIC_STR_PARAMS      100
#define UCLOGIC_STR_PARAMS_LEN  12
#define UCLOGIC_OFF_X_MAX        2
#define UCLOGIC_OFF_Y_MAX        4
#define UCLOGIC_OFF_PRESSURE     8
#define UCLOGIC_OFF_RESOLUTION  10

// The request runs on the same run loop as the pen handling, so we cannot wait long.
#define UCLOGIC_TIMEOUT_MS      1000

static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }

// Opens one device for requests on EP0. The caller must call USBDeviceClose +
// Release.
//
// The search is narrowed by location id on purpose. VID/PID alone can match
// several tablets, and IOServiceGetMatchingService then returns an arbitrary
// one: we could read the parameters of one device and switch the mode of it,
// while the HID interface we seize belongs to another.
static int open_device(uint16_t vid, uint16_t pid, uint32_t location_id,
                       IOUSBDeviceInterface ***out) {
    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    if (!match) return UCLOGIC_ERR_NOT_FOUND;

    int v = vid, p = pid;
    CFNumberRef nv = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &v);
    CFNumberRef np = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &p);
    CFDictionarySetValue(match, CFSTR(kUSBVendorID), nv);
    CFDictionarySetValue(match, CFSTR(kUSBProductID), np);
    CFRelease(nv);
    CFRelease(np);

    if (location_id != 0) {
        CFNumberRef nl = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &location_id);
        CFDictionarySetValue(match, CFSTR(kUSBDevicePropertyLocationID), nl);
        CFRelease(nl);
    }

    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, match);
    if (!svc) return UCLOGIC_ERR_NOT_FOUND;

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(svc);
    if (kr != kIOReturnSuccess || !plug) return UCLOGIC_ERR_PLUGIN;

    // The interface version must match the type we use: `IOUSBDeviceInterface` is an
    // alias for version 942, and the function table of version 100 ends at
    // CreateInterfaceIterator. If we asked for 100 and then called anything newer, we
    // would read past the end of the table.
    IOUSBDeviceInterface **dev = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID942),
                            (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (!dev) return UCLOGIC_ERR_PLUGIN;

    // Seize (USBDeviceOpenSeize) is not used here on purpose: reading a descriptor on
    // EP0 does not need exclusive access, and taking the device away from its current
    // owner in the kernel would also hit our own HID interfaces.
    if ((*dev)->USBDeviceOpen(dev) != kIOReturnSuccess) {
        (*dev)->Release(dev);
        return UCLOGIC_ERR_OPEN;
    }

    *out = dev;
    return UCLOGIC_OK;
}

static void close_device(IOUSBDeviceInterface **dev) {
    (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);
}

// GET_DESCRIPTOR(string, index) — a read; nothing is written to the device.
static int get_string_descriptor(IOUSBDeviceInterface **dev, uint8_t index,
                                 uint8_t *buf, uint16_t len) {
    memset(buf, 0, len);

    // With timeouts: DeviceRequest waits 5 seconds for data by default and has no limit
    // at all on completion, and this is called from the same run loop where the pen
    // parsing lives. A device that went silent would hang the driver.
    IOUSBDevRequestTO r;
    r.bmRequestType     = USBmakebmRequestType(kUSBIn, kUSBStandard, kUSBDevice); // 0x80
    r.bRequest          = kUSBRqGetDescriptor;                                    // 0x06
    r.wValue            = (uint16_t)((kUSBStringDesc << 8) | index);
    r.wIndex            = 0x0409;                                                 // en-US
    r.wLength           = len;
    r.pData             = buf;
    r.wLenDone          = 0;
    r.noDataTimeout     = UCLOGIC_TIMEOUT_MS;
    r.completionTimeout = UCLOGIC_TIMEOUT_MS;

    if ((*dev)->DeviceRequestTO(dev, &r) != kIOReturnSuccess) return UCLOGIC_ERR_REQUEST;
    return (int)r.wLenDone;
}

int uclogic_init(uint16_t vid, uint16_t pid, uint32_t location_id,
                 uclogic_params_t *out) {
    if (!out) return UCLOGIC_ERR_ARG;

    IOUSBDeviceInterface **dev = NULL;
    int rc = open_device(vid, pid, location_id, &dev);
    if (rc != UCLOGIC_OK) return rc;

    uint8_t buf[UCLOGIC_STR_PARAMS_LEN];
    int n = get_string_descriptor(dev, UCLOGIC_STR_PARAMS, buf, UCLOGIC_STR_PARAMS_LEN);
    close_device(dev);

    if (n < 0) return n;
    if (n < UCLOGIC_STR_PARAMS_LEN) return UCLOGIC_ERR_SHORT;

    out->x_max        = le16(buf + UCLOGIC_OFF_X_MAX);
    out->y_max        = le16(buf + UCLOGIC_OFF_Y_MAX);
    out->pressure_max = le16(buf + UCLOGIC_OFF_PRESSURE);
    out->resolution   = le16(buf + UCLOGIC_OFF_RESOLUTION);
    return UCLOGIC_OK;
}

int uclogic_read_string(uint16_t vid, uint16_t pid, uint32_t location_id, uint8_t index,
                        char *buf, int buf_len) {
    if (!buf || buf_len < 1) return UCLOGIC_ERR_ARG;

    IOUSBDeviceInterface **dev = NULL;
    int rc = open_device(vid, pid, location_id, &dev);
    if (rc != UCLOGIC_OK) return rc;

    uint8_t raw[256];
    int n = get_string_descriptor(dev, index, raw, sizeof raw);
    close_device(dev);

    if (n < 0) return n;
    if (n < 2) return UCLOGIC_ERR_SHORT;

    // String descriptor: bLength, bDescriptorType, then UTF-16LE.
    int chars = (n - 2) / 2;
    int i = 0;
    for (; i < chars && i < buf_len - 1; i++) {
        uint16_t u = le16(raw + 2 + i * 2);
        buf[i] = (u < 0x80) ? (char)u : '?';
    }
    buf[i] = '\0';
    return i;
}

int uclogic_check_input_monitoring(void) {
    return (int)IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
}

int uclogic_request_input_monitoring(void) {
    return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) ? 1 : 0;
}

int uclogic_check_post_event(void) {
    return (int)IOHIDCheckAccess(kIOHIDRequestTypePostEvent);
}

int uclogic_request_post_event(void) {
    return IOHIDRequestAccess(kIOHIDRequestTypePostEvent) ? 1 : 0;
}
