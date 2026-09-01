# Graphics tablets on macOS: what we measured

*По-русски: [FINDINGS_RU.md](FINDINGS_RU.md)*

Notes taken while writing a userspace driver for a Parblo A610 on Apple Silicon
(macOS 26, arm64). Everything below was measured on hardware, and every entry
says how to repeat the measurement.

Most of it is not specific to this tablet. Findings 1–7 apply to any tablet
driver on macOS, finding 4 applies to any program that lives behind a TCC
permission, and findings 12–14 apply to any IOKit code that talks to USB.
Part 5 is about the order the work happened in, and applies to nobody's code.

The device: `UC-LOIC` / `TABLET 1060`, VID `0x5543`, PID `0x0081` — the base
Parblo A610, a UGEE M708 clone, one of the UC-Logic v1 family. Firmware string
descriptor 201 reads `F401-HK708-STD`.

The driver is a plain LaunchAgent: no kernel extension, no DriverKit, no
entitlements, no sudo. `IOHIDManager` in, `CGEventPost` out.

Tools used for the measurements are in `tools/`. Each is a single C file that
builds with one `clang` line printed in its header comment.

---

## Part 1 — any tablet driver on macOS

### 1. Pressure from userspace works

The claim that macOS does not allow pressure input from usermode circulates
widely and is out of date.

`kCGTabletEventPointPressure` (field 19, `double` 0.0–1.0), tilt, rotation and
the whole `kCGEventTabletProximity` family are public in `CGEventTypes.h` of the
current SDK, with no deprecation markers. A LaunchAgent that reads HID reports
and posts `CGEvent`s gives full pressure to Krita, Clip Studio and Photoshop.

**Reproduce.** `grep -n "TabletEventPointPressure\|TabletProximity" \
$(xcrun --show-sdk-path)/System/Library/Frameworks/CoreGraphics.framework/\
Headers/CGEventTypes.h`

**Cost of believing otherwise.** You reach for DriverKit, which needs a paid
developer account, an entitlement request Apple reviews, and notarization — for
a problem that does not exist.

---

### 2. Proximity must be a real `kCGEventTabletProximity` event

Building a mouse event and setting `kCGMouseEventSubtype` to
`kCGEventMouseSubtypeTabletProximity` (2) is **not** enough. Qt applications
register a tablet only from a real event of type `kCGEventTabletProximity`,
which reaches them as `NSEventTypeTabletProximity` and invokes their
`tabletProximity:` handler. A mouse event carrying the subtype arrives as
`mouseMoved`, and the tablet handler rejects it.

Unregistered, Qt cannot match the `deviceID` on the point events and silently
downgrades the whole stream to plain mouse input.

**The symptom is misleading.** The cursor tracks the pen smoothly, a circle
comes out round, the barrel button right-clicks — and pressure does nothing,
with no error anywhere, in any log.

CoreGraphics has no constructor for event type 23. Build a mouse event and
reassign its `type`; it keeps a correct source, timestamp and position:

```swift
let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                    mouseCursorPosition: point, mouseButton: .left)!
event.type = .tabletProximity
// then the kCGTabletProximityEvent* fields
```

Qt also keys pens by `VendorUniqueID` and reads 0 as "no serial", so set a
constant non-zero value even when the hardware has no serial number.

**Reproduce.** Post only the mouse-subtype form and draw in Krita: pressure is
flat. Add the real proximity event with the same `deviceID`, and pressure works
with no other change.

---

### 3. Two TCC permissions are required, and the second one is silent

Input Monitoring (`kIOHIDRequestTypeListenEvent`) covers reading HID reports and
seizing the device. **Posting events needs a separate grant**,
`kIOHIDRequestTypePostEvent` — Accessibility in System Settings.

With `IOHIDCheckAccess(kIOHIDRequestTypePostEvent)` returning
`kIOHIDAccessTypeDenied` (1), `CGEventPost` moves nothing and returns no error
at all. There is no return value to check and nothing in any log.

Combined with a seize this is a trap: the driver takes the tablet away from the
system event service, logs success, parses reports correctly — and the tablet is
stone dead. The user sees a driver that "installed fine" and a tablet that
stopped working entirely.

**Reproduce.** Turn off Accessibility for the binary, leave Input Monitoring on,
run. Reports arrive, `CGEventPost` returns, the cursor does not move.

**What to do.** Check both at startup and refuse to run, naming the missing one:

```swift
IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)  // read HID, seize
IOHIDCheckAccess(kIOHIDRequestTypePostEvent)    // CGEventPost
```

---

### 4. Ad-hoc signing costs a TCC re-grant on every rebuild

This one reaches far beyond tablets: it applies to anything the user has to
switch on in Privacy & Security.

A binary signed ad-hoc (`codesign -s -`) gets a designated requirement of
`cdhash H"..."` — the hash of the contents. Any code change makes macOS treat
the rebuilt binary as a different program, and the permission toggles the user
granted go off. During development that is every single build.

Signing with a certificate gives a content-independent requirement:

```
identifier "com.example.thing" and certificate leaf = H"..."
```

A **self-signed** certificate is enough. No paid account, no admin password —
it all lives in the login keychain.

**Recipe.** Keychain Access → Certificate Assistant → Create a Certificate,
Self Signed Root + Code Signing. Then open the certificate and set
**Trust → Code Signing → Always Trust** — only that row, leaving the top one
alone, which would trust it for SSL too. Certificate Assistant does not set
trust, and without it `codesign` reports "no identity found". At the first
private-key prompt answer **Always Allow**; **Allow** is the focused button and
is one-shot, so the dialog then returns on every build. Recovery if Allow was
clicked: Keychain Access → login → Keys → the private key → Access Control →
add `/usr/bin/codesign`.

**Proof it works.** Two binaries of different sizes signed with the same
certificate produce byte-identical designated requirements. Then a real source
edit, rebuild and reinstall: the driver starts with nothing to re-grant.

**One gotcha.** Certificate signing is **not deterministic** — the CMS carries a
signing time — so an installer that skips work when "nothing changed" must
compare `CDHash`, never whole files. A byte comparison silently always reports
"changed".

```bash
codesign -d -vvv "$binary" 2>&1 | awk -F= '/^CDHash=/{print $2}'
```

**TCC also keys on the path.** A build in `.build/` is refused Input Monitoring
even when signed with the same certificate as the installed copy. A test build
has to go through the installer to the granted path.

---

### 5. `kCGTabletEventPointButtons` is a mouse-button mask

The field name suggests the state of the pen. `IOLLEvent.h` says otherwise: bit
0 is the left mouse button, bit 1 the right, bit 2 the middle.

Filling it from the physical pen — tip, lower barrel, upper barrel — looks
identical while nothing is remapped. Map the lower barrel button to a left click
and every event becomes self-contradictory: `leftMouseDown` carrying mask `0x2`,
"right button held". Qt reads this field.

Fill it from the button the event is actually reporting, so it is empty on
release and while hovering.

---

### 6. Seizing a tablet from userspace works, and Input Monitoring is enough

`IOHIDDeviceOpen(device, kIOHIDOptionsTypeSeizeDevice)` returns success on the
pen interface, and the system stops delivering its events: a passive
`CGEventTap` counts **zero** tablet events while 2838 reports arrive over 25 s.
No sudo, no entitlements — Input Monitoring alone.

The tablet's IORegistry entry is what tells you this is allowed:

```
RequiresTCCAuthorization = Yes           # Input Monitoring is needed
IOUserClientClass = IOHIDLibUserClient   # userspace access is open
```

**One caveat that costs a wasted measurement.** Do **not** call
`IOHIDManagerOpen`. It opens the matching devices itself, the normal way, and
the seize you ask for afterwards means nothing. Enumerate with
`IOHIDManagerCopyDevices` and open each device individually.

---

### 7. Keyboards cannot be seized

The same call on a keyboard interface returns `kIOReturnNotPrivileged`
(`0xE00002C1`). macOS protects keyboards from capture, and Input Monitoring does
not cover it. Reading reports without a seize works fine.

For this tablet that settles the express keys: their eight combinations are
fixed in firmware and cannot be remapped by a userspace driver. They are a plain
HID keyboard, so the practical routes are binding the combinations inside the
application, or a tool that ships a signed driver extension (Karabiner-Elements,
with a `device_if` condition on the vendor and product id).

---

## Part 2 — UC-Logic v1 tablets

### 8. Initialization is a string descriptor read, and it needs no privilege

The tablet boots in **compatibility mode**: the pen goes to interface 1 at
2048×2048 — 20× coarser than the hardware — and interface 0 stays silent.
Measured: 2969 reports over 20 s, all on IF1, zero on IF0.

Reading USB string descriptor **100** switches it to full mode. The Linux driver
says the same in `hid-uclogic-params.c`: *"NOTE: This enables fully-functional
tablet mode"*.

```
GET_DESCRIPTOR
  bmRequestType 0x80    (IN, standard, device)
  bRequest      0x06
  wValue        0x0364  ((0x03 << 8) | 100)
  wIndex        0x0409  (langid en-US)
  wLength       12
```

This is a read; nothing is written to the device.

**It works on macOS with a plain `USBDeviceOpen` through IOUSBLib — no sudo, no
seize, no entitlements.** The IOHIDFamily restriction covers claiming interfaces;
device-level EP0 requests fall outside it.

The reply carries the pen parameters, so there is no reason to hardcode them:

| Offset | Value | Meaning        |
|--------|-------|----------------|
| +2     | 40000 | X logical max  |
| +4     | 24000 | Y logical max  |
| +8     | 2047  | Pressure max   |
| +10    | 4000  | Resolution, LPI |

Check: 40000 × 1000 / 4000 = 10″, 24000 × 1000 / 4000 = 6″ — the declared size.

Other strings: #123 = `HK On` (enables the express keys), #201 = the model
name, which is the only way to tell tablets apart when several share one
VID/PID. At least three different tablets use `0x5543:0x0081`.

**The mode survives closing the USB handle** (+1223 reports on IF0 over 10 s
with the handle closed), so initialize once per attach and use HID afterwards.
**It does not survive a replug.** Measured with the driver stopped: unplug,
replug, 15 s of pen work gives +1634 reports on IF1 and +0 on IF0. The flag
lives in the tablet's RAM and dies with the power, which is why full mode never
travels to a machine that has no driver.

---

### 9. The report descriptor lies, and a histogram only covers what you pressed

Interface 0, Report ID 7, eight bytes: report id, flags, X, Y, pressure — the
three values little-endian `uint16`. Reports arrive at 122–148 Hz.

The flags byte disagrees with the descriptor in three places out of eight.
Measured over 6535 reports with every bit exercised:

| Bit | Declared usage       | What the device does           |
|-----|----------------------|--------------------------------|
| 0   | Tip Switch           | tip                            |
| 1   | Barrel Switch        | lower barrel button            |
| 2   | **Eraser**           | **upper barrel button** (`0x84`) |
| 3   | Invert               | never sent                     |
| 4   | Secondary Tip Switch | never sent                     |
| 5   | **Barrel Switch**    | **never sent**                 |
| 6   | **In Range**         | **the pen has left** (`0xC0`)  |
| 7   | padding (Constant)   | set in every report            |

Firmware contradicting its own descriptor is ordinary for UC-Logic — it is
exactly why Linux replaces the descriptor wholesale for these tablets.

So: the pen is in range while bit 7 is set and bit 6 is clear. Reading bit 2 as
an eraser means the middle click never happens and the application sees an
eraser whenever the upper button is held on approach.

**The methodological half of this finding is the more useful one.** An earlier
run of the same tool concluded "bit 6 never appears, bit 7 is In Range", and
that wrong fact survived a week in our documentation. The histogram behind it
held only `0x80` and `0x81`: nobody pressed a button during that run, and no pen
removal landed in the sample. The tell was available the whole time — the lower
barrel button demonstrably worked, so it had to produce a flags value, and none
was in the histogram.

**A histogram covers only the inputs somebody exercised.** Record which ones
those were, or the gap turns into a fact. `tools/flagscan.c` now says so in its
header and counts how many pauses each marker preceded.

---

### 10. "The pen left" blinks, so it needs a countdown

Bit 6 is a reliable marker: all 8 removals in one run ended with `0xC0` as the
last report before the stream stopped. Acting on it immediately is still wrong.

The device sends it every time the pen crosses the top of the sensing height,
including the times the hand brings it straight back. Over 51 exits in one
session, **29 ended within 118 ms** and **every real lift lasted at least
226 ms**. The band between the two is empty.

Leaving the range on the first announcement made proximity flicker several times
a second while hovering. With a barrel button held, the button was released and
pressed again on each blink — Krita latched its canvas pan on that and stayed
there.

So an announcement starts a countdown of 150 ms that any in-range report
cancels. The announcing report is not passed on at all: it carries pressure zero
and every button bit clear, so using it would release a button the hand is still
holding.

Result over a comparable session: 10 proximity transitions where there had been
102, and same-button release/re-press within 100 ms down from 19 to 2.

Keep a silence timeout as well — 250 ms of nothing, against reports every
7–8 ms — for the case where the stream stops with no announcement, because the
cable was pulled or the tablet fell out of full mode.

---

### 11. Full mode can be lost without a disconnect, and interface 1 tells you

The tablet can drop back to compatibility mode while staying plugged in. The pen
then moves to interface 1 while the driver sits seized on an interface that has
gone quiet — quiet for good, because re-initialization is usually tied to the
attach callback and there was no attach.

In full mode interface 1 sends nothing, so **any** report from it means exactly
one thing. Open it without a seize (the system owns it anyway, so nothing is
taken away) and re-read string 100 on the first report, rate-limited.

**Measured recovery: 16 ms**, from the first report on IF1 to a working pen on
IF0. To reproduce the failure: a cable replug always leaves the tablet in
compatibility mode, so build a version that skips the init on attach and let it
seize a silent IF0.

The original cause of the loss stays unknown. Neither 400 USB open/close cycles
nor a deliberate `USBDeviceOpenSeize` drops the tablet out of full mode. It does
not matter: the recovery does not depend on the cause.

---

## Part 3 — IOKit traps

### 12. `IOUSBDeviceInterface` is an alias for version 942

`IOUSBLib.h` typedefs `IOUSBDeviceInterface` to the **942** interface. Asking
the plugin for `kIOUSBDeviceInterfaceID` gives you version **100**, whose
function table ends at `CreateInterfaceIterator`.

Store one in a pointer typed as the other and every call past that point reads
off the end of the vtable. Ours was latent only because the affected call — a
fallback — never ran.

```c
(*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID942),
                        (LPVOID *)&dev);
```

Request the version whose functions you actually call.

### 13. `DeviceRequest` has an infinite completion timeout

`DeviceRequest` defaults to a 5 s no-data timeout and an **infinite** completion
timeout. On a single-threaded run loop that also parses the pen stream, one
wedged control transfer stops the driver for good.

Use `DeviceRequestTO` with explicit values.

### 14. Bind every request to one physical device

`IOServiceGetMatchingService` with only VID and PID returns an arbitrary match.
With two tablets of the same model attached, the driver can read and switch the
mode of one while seizing the interface of the other.

`LocationID` is the same on all HID interfaces of a device and on the USB device
itself, under two different key names:

| Where | Key |
|---|---|
| HID device | `kIOHIDLocationIDKey` — `"LocationID"` |
| USB service | `kUSBDevicePropertyLocationID` — `"locationID"` |

Read it from the HID device the matching callback handed you and add it to the
USB matching dictionary. A registry-id or parent-walk approach is not needed.

---

## Part 4 — how the measurements were run

`tools/` holds one C file per question. They need no build system:

| File | Question it answers |
|---|---|
| `check.py` | which interface is actually transmitting (opens nothing, needs no permission) |
| `ucinit.c` | reads the init strings #100 / #123 / #201 |
| `hidwatch.c` | live dump of reports from both pen interfaces |
| `seizetest.c` | does the seize work, and does the system stop seeing the device |
| `flagscan.c` | what the flags byte really means: histogram plus the value before each pause |
| `keyscan.c` | what each express key sends |
| `eventwatch.c` | what reaches the system, tapped at the HID level and at the session level |
| `clickwatch.c` | click count, tablet button mask and pointer type of every press |

**A passive `CGEventTap` shows exactly what an application will see.** It
listens only, so it needs no post-event permission. Every behavioural claim in
Part 1 was settled with one.

---

## Part 5 — how the work actually went

The findings above read as if they were known in advance. They were not. This
part is the order things happened in, because the order carries its own lesson.

### Test the riskiest assumption before writing anything

The whole architecture hung on one question: can a userspace process take the
tablet away from the system event service? A "no" meant filtering the system's
own events through a `CGEventTap`, a different output layer and a different set
of problems.

Answering it cost one changed line in a tool that already existed —
`kIOHIDOptionsTypeNone` to `kIOHIDOptionsTypeSeizeDevice` — and ten minutes.
The seize worked, 2838 reports arrived over 25 s, and a passive tap counted zero
tablet events from the system. The same run produced finding 6's caveat about
`IOHIDManagerOpen`, which would otherwise have cost a day later on.

### Three things we wrote down as facts before measuring them

**"In Range is bit 6."** The report descriptor says so. The first measurement
found the device setting bit 7 in every report and bit 6 in none, so the note
became "bit 7 is In Range, the descriptor lies". That conclusion stood for a
week and was wrong in a second way: a proper run with every button pressed and
every removal captured showed bit 2 is the upper barrel button and bit 6 marks
the pen leaving. The first sample had exercised neither. See finding 9.

**"A mouse event with subtype 2 is enough for proximity."** It reads as the
obvious way to do it, and every field is accepted without complaint. Krita
disagreed, silently. See finding 2.

**"Initialization is optional — the device enumerates, so data flows."**
Enumeration is not data flow: 2969 reports over 20 s, all of them on interface 1,
zero on interface 0. See finding 8.

A measurement also killed a hypothesis of ours that was never written down as a
fact and would have been: the tablet dropped out of full mode once, and the
suspected cause was a fallback `USBDeviceOpenSeize` in our own code. Under 400
open/close cycles the plain `USBDeviceOpen` succeeded every time, so the fallback
had never run.

### A refuted claim is not a false one

An adversarial verification pass over the audit confirmed 1 finding out of 17.
Re-reading the refutations by hand found 4 more that were real, including the
vtable version bug in finding 12 — latent only because the affected call never
ran.

Read "refuted" as "not yet confirmed" and go through the high-severity ones
again yourself.

### What made the wrong beliefs expensive

Each of them was cheap to hold and cheap to test: the tool was already written,
the tablet was on the desk, the run took a minute. Writing them down as facts is
what made them expensive. From then on they were cited, and code was built on
them, and the code worked well enough that nothing pointed back at the note.

A claim that has been measured is worth the sentence saying which run measured it
and what was exercised in that run. Finding 9 exists because its first version
carried the number of reports and left out that nobody had pressed a button.
