# parblo-a610-craft-driver

*По-русски: [README_RU.md](README_RU.md)*

> **Authorship.** The project was completely written by Claude Opus 5.
> Code review was done by ChatGPT 5.6 Sol.

A driver for the **Parblo A610** tablet (`UC-LOIC / TABLET 1060`,
`0x5543:0x0081`, firmware `F401-HK708-STD`) on macOS running on Apple Silicon.

Parblo's own driver from 2018 claims only OS X 10.11–10.14. This one is a
userspace daemon in Swift: it reads HID directly and posts real CoreGraphics
tablet events, with pressure, which Photoshop, Krita, Clip Studio and Blender
understand.

No external dependencies — no libusb, no hidapi, no Homebrew. Apple frameworks
only.

The measurements everything rests on are collected separately in
[FINDINGS.md](FINDINGS.md), also [in Russian](FINDINGS_RU.md). Most of them have
nothing to do with this model and are useful to anyone writing a tablet driver
or fighting TCC on macOS.

## Caveats

The scope is narrow, and it is better to know that before installing.

**One model.** The driver is written for the Parblo A610 with firmware
`F401-HK708-STD`. At least three different tablets use `0x5543:0x0081`, so the
identification goes by the firmware string, and the driver refuses to touch a
foreign device. The protocol layer is common to the UC-Logic v1 family: two
constants tie it to this model — the PID and the firmware string. Adapting it to
a neighbouring tablet is plausible and has been tried by nobody.

**One machine.** Everything was measured on one piece of hardware, under one
version of macOS, with one user. That is n = 1. Reports of "it behaves
differently here" are expected, and settling them takes a measurement — the
tools for that are in `tools/`.

**One user.** The installation is per-user. Under fast user switching the tablet
goes to whichever session seized the device first; the details and the way to
fix it are in the TODO section.

**No tilt and no pen rotation.** The hardware has neither.

**The express keys cannot be remapped by the driver.** That is how macOS works;
the details are at the end of this file.

## Installation

There are two ways in. The first takes a Terminal window. The second takes a
Swift toolchain and gives you a build from the source you can read.

### From a release archive

For anyone who has no interest in compilers. Unpack the archive, and in Terminal
type `cd `, drag the unpacked folder into the window, press Enter, then:

```bash
./install.sh
```

Nothing is built: the files inside are already compiled and signed. The archive
carries `INSTALL.txt` with the same steps spelled out click by click, in English
and in Russian.

The build is **not notarized by Apple** — that needs a paid developer account.
So macOS marks the downloaded files as quarantined and the installer asks once
whether to clear that flag, saying plainly what it means. Answering no installs
nothing.

### From source

```bash
tools/build.sh
```

The script builds a release, signs it (an unsigned binary does not run at all on
arm64 — a requirement of the architecture), installs the LaunchAgent
and starts it. Swift is needed, which means Xcode or the Command Line Tools.

`tools/build.sh package` builds the release archive described above into `dist/`
and installs nothing.

### The permissions

Whichever way you came, grant **two** permissions. Both live in
**System Settings → Privacy & Security**, both for
`~/Library/Application Support/parblo-a610-craft-driver/bin/parblo-a610-craft-driver`:

| Section | What it is for |
|---|---|
| **Input Monitoring** | reading HID and seizing the tablet interface |
| **Accessibility** | so that `CGEventPost` actually delivers events |

The second permission is mandatory and easy to miss. Without it `CGEventPost`
silently throws away everything the driver produces: there is no error, the log
looks successful, and the tablet is completely dead — it has already been seized
and no longer belongs to the system. So the driver checks both rights at startup
and refuses to run until they are there: a working coarse mouse beats a seized
tablet that posts nowhere.

The driver lives in a folder Finder keeps hidden, so in the file picker press
Command+Shift+G and paste the path. On the first run
the driver also asks for both permissions with a dialog. If you missed it,
switch the toggles on by hand and nudge the agent:

```bash
launchctl kickstart -k gui/$(id -u)/com.rey.parblo-a610-craft-driver
```

### Removal

Either installer removes what both of them install:

```bash
tools/build.sh uninstall
```

Unloads the agent, removes the plist, quits and deletes the settings app, and
removes the binary. The config and the logs stay, so a reinstall picks them up.
To drop those as well:

```bash
tools/build.sh uninstall --purge
```

The tablet goes back to the system straight away and works as an ordinary
pointer without pressure, the same as before the installation.

Two things the script cannot clean up:

- **The permissions.** Input Monitoring and Accessibility keep listing rows that
  point at a file that is gone. Remove them with the minus button in the same
  panel. There is no clean way from the terminal: `tccutil reset` works on a
  whole service and would reset the permissions of every program at once.
- **The certificate.** `Parblo A610 Craft Driver` and its private key stay in
  the `login` keychain. Nothing else is disturbed by them, so delete them only
  if they are no longer needed for anything.


| What | Where |
|---|---|
| Binary | `~/Library/Application Support/parblo-a610-craft-driver/bin/parblo-a610-craft-driver` |
| Config | `~/Library/Application Support/parblo-a610-craft-driver/config.json` |
| Log | `~/Library/Application Support/parblo-a610-craft-driver/parblo-a610-craft-driver.log` |
| Crash log | same place, `…crash.log` — empty in normal operation |
| LaunchAgent | `~/Library/LaunchAgents/com.rey.parblo-a610-craft-driver.plist` |
| Settings app | `~/Applications/Parblo A610.app` |

## Running by hand

```bash
swift build && ./.build/debug/parblo-a610-craft-driver --verbose
```

`--dump` prints the parsed pen stream and posts no events — handy when you want
to see what comes off the hardware without touching the cursor. Accessibility is
not needed in that mode: the driver sends nothing, so it does not ask for the
right to send.

Permissions are bound to a particular program: running from the terminal needs
the toggles on **Terminal** itself.

> **Permissions survive a rebuild** — but only when the binary is signed with a
> certificate, see the section below. With an ad-hoc signature they go off after
> every code change.

## The log

```bash
tail -f ~/Library/Application\ Support/parblo-a610-craft-driver/parblo-a610-craft-driver.log
```

The driver is a background process with no interface, and the log is its only
window outwards. So everything of consequence is written down: identification,
connect and disconnect, the mode being set up again after sleep, recovery after
a lost mode, refusals over permissions. About **half a kilobyte a day** — one
line per event, pen reports never.

The details — the pen entering and leaving the range — only under `--verbose`,
which the production agent does not pass.

### Why the driver writes its own log

A file nobody rotates is the job of whoever writes to it: macOS does not do it.
While `launchd` redirected the output there was nothing to trim an overgrown
file from the inside — it held the descriptor.

Now the driver opens the file itself, watches the size, and at one megabyte
renames the current one to `.1` and starts a new one. One old copy is kept and
the limit is never passed: the check runs **before** the write, otherwise the
freshest line would ride into the rotated file.

The rename can fail — a read-only directory, a `.1` held by somebody else. The
file is then cut in place through the descriptor we already own, which needs no
rights on the directory. Rotation does not ask itself about the size on the way
back: the earlier scheme recursed for ever on a failed rename and took the
daemon down, and `KeepAlive` turned the crash into a restart loop.

`launchd` keeps the output for the case of a crash — a separate `…crash.log`,
which does not grow at all in normal operation.

Run by hand, the driver prints to the terminal; `isatty` decides, and `--dump`
needs it that way.

All of it is plain Foundation: `FileManager` and `FileHandle`, plus `isatty`. No
external dependencies.

## The settings app

`~/Applications/Parblo A610.app` — a menu bar item and a calibration window.
Installed by the same installer.

**It needs no permissions at all.** Neither Input Monitoring nor Accessibility,
that follows from the design: the app has no link to the driver.

| What | How |
|---|---|
| Settings | writes `config.json`; the driver watches the file and re-reads it live |
| Live pressure and pen coordinates | arrive as tablet events, like in any editor |

No sockets, no XPC, no shared memory. Both mechanisms existed before the app.

The same design says what the app cannot know. The badge at the top is about the
launchd agent: whether the process is alive. The tablet — plugged in or gone, pen
answering or silent — is what the line below reports, by the age of the last pen
event. The app reads the config through the same `ConfigStore` as the driver, so
an edit made to the file from outside while the window is open is picked up;
earlier it was overwritten by the next slider move.

### What is in the window

- **Display** — where to map to, rotation, aspect ratio fitting.
- **Active area** — the rectangle is dragged and resized by a corner. The dashed
  line shows what actually reaches the screen after the aspect fit; the orange
  dot is the pen in real time, so you see at once how far the hand reaches. The
  same `ScreenMapper` as the driver does the arithmetic: a preview must not draw
  its own version of the calculation.
- **Pen buttons** — what the barrel buttons do.
- **Pressure** — the curve with a linear one for comparison, sliders for gamma
  and the cut-offs, a live dot on the curve, and a place to draw a line with the
  pen and see its width. A curve cannot be chosen blind, which is what the
  editor is for.

The app sees pressure the driver has already mapped, so the dot on the curve is
placed by the inverse transform — otherwise it would sit on the wrong axis.

### Building the bundle

SwiftPM builds a bare executable: without an `Info.plist` the process
has no bundle identifier and the system does not treat it as an app. `build.sh`
makes the wrapper and signs it with the same certificate as the driver. There is
no Xcode project in the repository — everything builds with one `swift build`.

## The config

The file is created on the first run and re-read live — no restart needed.
Missing keys fall back to the defaults, so you can keep only what you change.

```json
{
  "display": "main",
  "activeArea": { "x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0 },
  "lockAspectRatio": true,
  "orientation": 0,
  "pressure": { "min": 0.02, "max": 0.95, "gamma": 0.75 },
  "penButtons": { "barrel1": "rightClick", "barrel2": "middleClick" }
}
```

| Key | Meaning |
|---|---|
| `display` | `"main"`, or the index in the list of active displays counting from zero: `"1"` |
| `activeArea` | the working part of the tablet in fractions of the whole area, so it is independent of the resolution |
| `lockAspectRatio` | fit the area to the screen's ratio so a circle stays a circle |
| `orientation` | `0`, `90`, `180`, `270` |
| `pressure.min` / `.max` | the dead zone at the bottom and the saturation at the top, as fractions of the raw range |
| `pressure.gamma` | `< 1` softer (a light touch gives more), `> 1` harder, `1` linear |
| `penButtons.*` | `none`, `leftClick`, `rightClick`, `middleClick` |

On `lockAspectRatio`: the tablet is 5:3 (1.667), the Mac's screen about 1.54.
Without the fit the horizontal is stretched more than the vertical and a circle
comes out an ellipse.

On `gamma`: an ordinary working press on this hardware gives ~1450–1520 out of
2047, that is 0.71–0.74 of the scale. The top quarter is nearly unreachable and
all the fine work is squeezed into the lower half. If a thin line is hard to
draw, lower the gamma; if the full range is reached too early, raise it.

A barrel button outranks the tip: holding it, you draw with the button it is
mapped to. The button does not change mid-stroke — a key pressed along the way
will not turn a left stroke into a right one.

## How it works

```
USB control transfer, string #100  →  full tablet mode
IOHIDManager, IF0 (0x0D/0x02), seize  →  Report ID 7, 8 bytes, ~130 Hz
ReportParser  →  PenState
ScreenMapper + PressureCurve  →  screen coordinates and pressure 0…1
CGEvent (subtype TabletPoint / TabletProximity)  →  applications
```

Four things everything rests on:

1. **Initialization is mandatory.** The tablet starts in compatibility mode and
   sends the pen to interface 1 at 2048×2048 while interface 0 stays silent.
   Reading string descriptor #100 moves it to full mode at 40000×24000
   (`hid-uclogic-params.c`: *"NOTE: This enables fully-functional tablet
   mode"*). This is a **read**; nothing is written to the device. The mode holds
   after the USB handle is closed, so it is done once per attach and repeated
   after waking from sleep.

2. **The seize is mandatory.** `DeviceOpenedByEventSystem = Yes` — the system
   event service handles the tablet itself and moves the cursor. Without
   `kIOHIDOptionsTypeSeizeDevice` the cursor would get two commands at once.
   Measured: under a seize the reports reach the driver and the system posts
   zero tablet events.

3. **Proximity is mandatory, and it takes two forms.** Without enter and leave
   events an application does not accept the device as a tablet and silently
   ignores pressure. A mouse event with subtype `2` is **not enough**: Qt
   applications (Krita, Clip Studio) register a tablet only from a real event of
   type `kCGEventTabletProximity`, which reaches them as
   `NSEventTypeTabletProximity` and calls `tabletProximity:`. The mouse variant
   arrives as `mouseMoved` and the tablet handler rejects it — Qt then fails to
   find the device by `deviceID` in the point events and treats the stream as a
   plain mouse. The symptom is recognizable: the cursor moves smoothly, the
   circle is round, the barrel button clicks — and pressure does nothing, with
   no error anywhere. The driver posts both forms.

4. **Two rights are needed, and the second one is silent.** Input Monitoring
   opens reading and the seize, Accessibility opens posting. Without the second,
   `CGEventPost` returns nothing and complains nowhere; the events simply
   vanish. Measured: with
   `IOHIDCheckAccess(kIOHIDRequestTypePostEvent) = denied` a posted event moves
   no cursor.

Interface 1 (Mouse) is a trap: it also gives the pen with pressure, at
coordinates 20× coarser. The driver listens to it **without a seize** and for
exactly one purpose: in full mode that interface is silent, so any report from
it means the tablet has lost full mode and string #100 has to be read again.
Otherwise such a loss would go unnoticed for ever, because re-initialization is
tied to the attach event and nobody touched the cable.

Interface 2 (Keyboard) is the express keys. They send combinations fixed in
firmware and work with no driver; this one does not open that interface.

### The flags byte of Report ID 7

The IF0 descriptor declares `Usage(In Range)` on bit 6 and bit 7 as padding
(`Input (Constant)`). The firmware does not match its own descriptor — ordinary
for UC-Logic, which is exactly why Linux replaces the descriptor wholesale for
these tablets. Measured 2026-08-31 over 6535 reports:

| Bit | What is declared | What the device sends |
|---|---|---|
| 0 | tip switch | as declared |
| 1 | lower barrel button | as declared |
| 2 | eraser | **the upper barrel button** |
| 3 | pen inverted | never seen |
| 4 | secondary tip switch | never seen |
| 5 | upper barrel button | never seen |
| 6 | pen in range | **the pen has left the range** |
| 7 | padding | set in every report, carries nothing |

The pen counts as in range while bit 7 is set and bit 6 is clear. All eight pen
removals in the measurement ended with the byte `C0` — the last report before
the silence.

Bit 6 is not acted on immediately. While the pen hovers at the edge of the
sensing height it blinks: 29 such blinks in the measurement ended within 118 ms,
while every real lift lasted at least 226 ms. So a report with bit 6 starts a
countdown of 150 ms that any in-range report cancels. That report is not passed
to the button tracker: it carries pressure zero and cleared bits, and it would
release a button the hand is still holding. Without this, Krita latched its
canvas pan.

The silence timeout of 250 ms stays as the backup for when the stream simply
stops: the cable was pulled, the tablet lost full mode.

This pen has no eraser. Bit 2 is the upper button, and reading it as an eraser
meant the middle click never worked at all, while entering the range with the
upper button held looked like an eraser to the application.

## Tools

Separate diagnostic programs in C; the driver does not need them:

| File | What it does |
|---|---|
| `tools/check.py` | which interface is actually transmitting; opens nothing, needs no permission |
| `tools/ucinit.c` | reads the init strings #100 / #123 / #201 |
| `tools/hidwatch.c` | live dump of reports from both pen interfaces |
| `tools/seizetest.c` | stage zero: does full mode hold, does the seize pass, does the system duplicate the input |
| `tools/flagscan.c` | what the flags byte really means: a histogram of the values and the behaviour before a pause |
| `tools/keyscan.c` | what each express key sends |
| `tools/eventwatch.c` | what reaches the system: a tap at the HID level and at the session level |
| `tools/clickwatch.c` | what goes out on every press: click count, tablet button mask, pointer type, coordinates |

Each builds with one command:

```bash
clang -O2 -o tools/hidwatch tools/hidwatch.c -framework IOKit -framework CoreFoundation
```

`seizetest`, `flagscan`, `eventwatch` and `clickwatch` also need
`-framework CoreGraphics`. `clickwatch` listens passively, and the tap is still
created only with Accessibility.

## Verified on hardware

| | |
|---|---|
| Identification by firmware string #201 | ✅ |
| Switch to full mode by string #100 | ✅ 40000×24000, 2047, 4000 LPI read off the device |
| Seizing interface 0 | ✅ reports reach the driver, zero tablet events from the system |
| The cursor follows the pen | ✅ smoothly |
| A circle stays a circle | ✅ the letterbox works |
| Pressure changes line width in Krita | ✅ the full 0.0–1.0 range |
| Right click from the barrel button | ✅ |
| Cable replug | ✅ including into a different port: the removal is caught, on re-attach the firmware is checked again and string #100 is read |
| Sleep and wake | ✅ from the button and from the lid |
| No leaks | ✅ measured: `leaks` on the live process and 400 cycles of the C shim over USB give zero from our code |
| The settings app | ✅ works: settings apply live, the live pen dot and pressure are visible |
| Recovery after a lost full mode | ✅ verified: tablet in compatibility mode, driver on a silent interface — noticed and healed in **16 ms** |

## What is missing

- **Tilt and rotation.** The hardware has neither: `kCGTabletEventTiltX/Y` and
  `Rotation` are not set in the events, and the matching bits are not raised in
  the `CapabilityMask`.
- **Remapping of the express keys.** macOS refuses to seize the keyboard
  interface with `kIOReturnNotPrivileged`, a defence against keyloggers, so this
  one is closed for good. Reading the reports is allowed; taking them away from
  the system is not. Details below.
- **Interface localization.** The settings window is in English, and there is no
  code for switching the language.

## Development

Every check with one command:

```bash
tools/check.sh
```

```
==> Swift build, warnings as errors    ok
==> C warnings                         ok
==> clang static analyzer              ok
==> Swift formatting                   ok
==> Tests                              ok
==> shell scripts                      ok
==> plist is valid                     ok
```

`tools/check.sh --full` adds a test run under the address and undefined
behaviour sanitizers. Everything listed ships with Swift and Xcode — there is
nothing to install.

### Tests

```bash
swift test
```

Ten suites. They cover the pure functions — the ones where a mistake is
invisible to the eye:

| Suite | What it checks |
|---|---|
| Settings app | parsing the driver state, the display value for the config, reading and writing the file, picking up an outside edit of the config |
| Report ID 7 parsing | assembling numbers low byte first, dropping the report id, flags as the device sends them, both barrel buttons on the bits the device really uses, a short and a long buffer |
| Pen button state | every transition, including the bug the suite was written for |
| Pen proximity | the threshold between the measured blinks and the real lifts, the countdown cancelled by a returning pen, the exit on silence |
| Pen click count | counting per button and per place, the system interval, the cap at three |
| Tablet to screen mapping | centre to centre, equal scale on both axes, all four rotations, the active area, a portrait display, a display with an offset |
| Pressure curve | the edges, monotonicity, gamma, degenerate settings |
| Config parsing and writing | defaults, a partial config, junk in the values, the default file matching the code |
| Log rotation | overflow keeping the previous copy, a read-only directory |

A test that passes on broken code is useless, so the button suite was checked by
substituting the old logic back: exactly the two tests that encode the bug fail
and the other six pass. The proximity suite was checked the same way — a
threshold of 0 breaks six tests, 50 ms four, 400 ms six.

The mapper takes the display bounds as a parameter, otherwise the tests would
depend on the monitor that happens to be attached.

### Tooling

| Task | With what | Where from |
|---|---|---|
| Swift formatting and linting | `swift format`, settings in `.swift-format` | part of the toolchain |
| Memory ownership in C | the clang static analyzer, 77 checkers | part of the toolchain |
| C warnings | `-Wall -Wextra -Wshadow -Wconversion` | the compiler |
| Tests | Swift Testing, `swift test` | part of the toolchain |
| Sanitizers | `--sanitize=address` / `undefined` | part of the toolchain |

SwiftLint and clang-format would add strictness and require Homebrew; they are
not used here.

## Code signing

An unsigned binary does not run at all on arm64 — a requirement of the
architecture, with Gatekeeper a separate matter. What it is signed with decides
the fate of the granted permissions.

An **ad-hoc** signature (`codesign -s -`) puts the hash of the contents into the
requirement:

```
designated => cdhash H"2814fd9e…"
```

One byte changes, the hash changes, and for macOS this is a different program:
the rows stay in the permission lists and the toggles go off. While the code is
being worked on that happens after every build.

With a **certificate** the requirement refers to the certificate and the
identifier, and the contents stay out of it:

```
designated => identifier "com.rey.parblo-a610-craft-driver"
              and certificate leaf = H"c32d7356…"
```

Verified: two binaries with deliberately different contents signed with the same
certificate produce byte-identical requirements; after a source edit and a
reinstall the driver starts without asking for the permissions again.

### Making the certificate

A self-signed one works; an Apple Developer ID is not needed. An administrator
password is not needed either — it all happens in the login keychain.

This is a certificate you create on your own machine and trust for code signing
only. No third-party root certificate is added to the system, the trust does not
extend to SSL, and it never leaves your computer.

```bash
open "/System/Library/CoreServices/Applications/Keychain Access.app"
```

1. **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name it `Parblo A610 Craft Driver`, identity type **Self Signed Root**,
   certificate type **Code Signing**. Tick "Let me override defaults" and set
   3650 days, otherwise it all repeats in a year.
3. Find the new certificate in the `login` keychain, open it with a double
   click, expand **Trust** and set **Code Signing → Always Trust**. Close the
   window and enter your account password.
   Only the Code Signing row: the top row would set trust for every purpose,
   SSL included, which is wider than needed.
4. On the first build the system asks for access to the private key. Answer
   **Always Allow**, **not** Allow.

   Allow is usually focused and gets pressed out of habit, and it applies to
   the current run only, after which the dialog returns on every build. Always Allow adds `codesign` to the list
   of trusted programs for that key and the question never comes back.

   If Allow was already pressed: open the `login` keychain, category **Keys**,
   find the key `Parblo A610 Craft Driver`, double click → the **Access
   Control** tab → add `/usr/bin/codesign` to the allowed programs. Or simply
   wait for the next dialog and press the right button.

To check:

```bash
security find-identity -v -p codesigning
```

One valid identity should be found. With no certificate, `build.sh` signs
ad-hoc and says so.

The certificate name is set in `tools/common.sh` by the `IDENTITY` variable.

A self-signed certificate does not allow handing the driver to other people —
that needs a Developer ID and notarization ($99 a year). For your own machine it
is not required.

### The small thing that is easy to forget

Signing with a certificate is **not deterministic**: the signing time goes into
it, and two runs over the same code give different files. So `build.sh`
compares `CDHash` — the hash of the code itself, with no time in it — rather
than whole files. Otherwise the "do not touch an unchanged binary" check would
silently stop working.

## TODO

### Multi-user mode

The installation today is **per-user**: the driver works for whoever installed
it. Another user of the same machine does not get it, and there are four reasons
at once:

| What | Where it lives | Why the other user cannot see it |
|---|---|---|
| the agent plist | `~/Library/LaunchAgents/` | the job is simply absent from their domain |
| the binary | `~/Library/Application Support/parblo-a610-craft-driver/bin/` | `~/Library` is `drwx------` |
| the config | same place | the same |
| TCC permissions | `~/Library/Application Support/com.apple.TCC/TCC.db` | **every user has their own database** |

There is a way around it today: the second user runs an installer for
themselves. The script is built entirely on `$HOME`, so it installs everything
into their home with their config and log; the sources are read as long as the
project directory is readable. Two toggles are then left to switch on.

Under **fast user switching** this still runs into the seize. The previous
user's session does not end, their LaunchAgents keep running, and
`kIOHIDOptionsTypeSeizeDevice` is exclusive — the second driver does not get the
device. It behaves honestly, `DeviceWatcher` logs "the device is busy in another
process", and it will not work until the first user logs out.

Doing it properly needs three things:

1. The binary in a shared place: `/usr/local/bin` or
   `/Library/Application Support/…` in place of the home directory.
2. The plist in `/Library/LaunchAgents`: agents load from there into **every**
   GUI session. Requires administrator rights.
3. The driver has to **give the device back** when its session stops being
   active and take it again when it becomes active —
   `NSWorkspace.sessionDidResignActiveNotification` and
   `sessionDidBecomeActiveNotification`. Without that, points 1 and 2 only lead
   to several processes fighting over the seize, and the first one wins.

The third point is the actual work, and the first two are pointless without it.
TCC permissions stay per-user in any case: that is macOS's own arrangement and
there is nothing to get around it with.

## The express keys

The eight buttons on the tablet send combinations fixed in firmware. The driver
does not touch them: it does not open the keyboard interface.

What each one sends, top to bottom — captured with `tools/keyscan.c` on
2026-08-25:

| # | Report | Combination | The intent |
|---|---|---|---|
| 1 | `03 04 3D` | Alt + F4 | close the window *(Windows)* |
| 2 | `03 01 16` | Ctrl + S | save *(Windows)* |
| 3 | `03 02 56` | Shift + Keypad − | zoom out |
| 4 | `03 02 57` | Shift + Keypad + | zoom in |
| 5 | `03 01 1A` | Ctrl + W | close *(Windows)* |
| 6 | `03 01 19` | Ctrl + V | paste *(Windows)* |
| 7 | `03 01 1B` | Ctrl + X | cut *(Windows)* |
| 8 | `03 01 06` | Ctrl + C | copy *(Windows)* |

The firmware is built for Windows, where Ctrl is the command modifier. On macOS
that is Cmd, so six of the eight do nothing by default. Buttons 3 and 4 do type
`-` and `+`, which in Krita happens to be the zoom.

### How to use them anyway

**Bind them in the editor.** All eight send distinguishable combinations, and in
Krita, Photoshop and Clip Studio they can be assigned to any action. On macOS
combinations with Ctrl are almost always free — Cmd takes their place — so there
are no conflicts. This works today and needs no code.

**Remap them system-wide.** Seizing the interface and substituting events is not
possible: macOS answers `kIOReturnNotPrivileged`. Of the ready-made tools,
[Karabiner-Elements](https://karabiner-elements.pqrs.org/) fits — it supports
rules bound to a particular device through
[`device_if`](https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/conditions/device/)
with `vendor_id` and `product_id`. For this tablet those are `21827` and `129`
(decimal for `0x5543` and `0x0081`), so the rules touch only the tablet's
buttons and leave the real keyboard alone.

## License

MIT, see [LICENSE](LICENSE).

The protocol facts came from measurements on the device and from reading the
Linux driver `hid-uclogic-params.c` (GPL-2.0), which is quoted once for
attribution. The implementation here is our own.
