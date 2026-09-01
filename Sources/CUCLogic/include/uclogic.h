// uclogic.h — a thin layer over the two things that Swift cannot bridge:
// the COM-like IOUSBDeviceInterface** and IOHIDCheckAccess from hidsystem/IOHIDLib.h.
#ifndef UCLOGIC_H
#define UCLOGIC_H

#include <stdint.h>

typedef struct {
    uint16_t x_max;        // 40000
    uint16_t y_max;        // 24000
    uint16_t pressure_max; // 2047
    uint16_t resolution;   // 4000 LPI
} uclogic_params_t;

// Return codes.
#define UCLOGIC_OK               0
#define UCLOGIC_ERR_NOT_FOUND   -1  // no device with this VID/PID is connected
#define UCLOGIC_ERR_PLUGIN      -2  // could not create the IOUSBDevice plug-in
#define UCLOGIC_ERR_OPEN        -3  // USBDeviceOpen refused
#define UCLOGIC_ERR_REQUEST     -4  // the control transfer failed
#define UCLOGIC_ERR_SHORT       -5  // the string came back shorter than expected
#define UCLOGIC_ERR_ARG         -6

// Reads string descriptor 100. A side effect of the read is that the tablet goes
// into full mode (hid-uclogic-params.c: "NOTE: This enables fully-functional
// tablet mode"). Nothing is written to the device.
// The pen parameters are returned in *out. UCLOGIC_OK on success.
// `location_id` pins the request to one physical device. A VID/PID pair can
// match several tablets at once, and IOKit then returns an arbitrary one — we
// could read and switch the mode of one tablet while seizing another. Take the
// value from the HID device we are about to open (`kIOHIDLocationIDKey`); it is
// the same number the USB device carries. Pass 0 to match any device.
int uclogic_init(uint16_t vid, uint16_t pid, uint32_t location_id, uclogic_params_t *out);

// Reads any string descriptor as UTF-8 (UTF-16LE → ASCII).
// Returns the string length without the trailing zero, or a negative error code.
int uclogic_read_string(uint16_t vid, uint16_t pid, uint32_t location_id, uint8_t index,
                        char *buf, int buf_len);

// Check and request access.
// `check` returns the IOHIDCheckAccess value: 0 = granted, 1 = denied,
// 2 = unknown. `request` returns 1 if access was granted, otherwise 0 —
// IOHIDRequestAccess has a boolean result, and it does not match the `check` codes.
//
// There are TWO permissions, and they are different. Input Monitoring (listen) is
// needed to read HID and to seize the interface. Accessibility (post) is needed for
// CGEventPost to send anything at all: without it the window server drops the events
// silently, with no error and no trace in the log.
int uclogic_check_input_monitoring(void);
int uclogic_request_input_monitoring(void);
int uclogic_check_post_event(void);
int uclogic_request_post_event(void);

#endif
