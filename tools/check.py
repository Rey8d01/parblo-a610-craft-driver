#!/usr/bin/env python3
"""check.py — which tablet interface really sends data.

Reads the ReportAvailableCalls counters of macOS itself from the IORegistry.
It needs no permissions, does not open the device and writes nothing.

    python3 check.py          a snapshot right now
    python3 check.py watch    a snapshot, 10 seconds of drawing, a second one, a verdict
"""
import plistlib
import subprocess
import sys
import time

NAMES = {
    (13, 2): "IF0 Digitizer  full 40000x24000",
    (1, 2):  "IF1 Mouse      cut down 2048x2048",
    (1, 6):  "IF2 Keyboard   express keys",
}


def snapshot():
    """Returns {(usagePage, usage): ReportAvailableCalls}."""
    raw = subprocess.run(["ioreg", "-a", "-l", "-w", "0"],
                         capture_output=True).stdout
    root = plistlib.loads(raw)
    out = {}

    def walk(node):
        if isinstance(node, dict):
            if (node.get("Product") == "TABLET 1060"
                    and node.get("IOObjectClass") == "IOHIDInterface"):
                key = (node.get("PrimaryUsagePage"), node.get("PrimaryUsage"))
                debug = node.get("DebugState") or {}
                out[key] = debug.get("ReportAvailableCalls")
            for child in node.get("IORegistryEntryChildren") or []:
                walk(child)

    walk(root)
    return out


def show(counters, title):
    print(f"=== {title} ===")
    for key in sorted(counters, key=lambda k: NAMES.get(k, str(k))):
        print(f"  {NAMES.get(key, str(key)):<38} {counters[key]}")


def main():
    before = snapshot()
    if not before:
        print("Tablet not found. Is it plugged in?")
        return 1

    show(before, "counters now")

    if len(sys.argv) < 2 or sys.argv[1] != "watch":
        return 0

    print("\n>>> DRAW ON THE TABLET WITH THE PEN FOR 10 SECONDS <<<")
    time.sleep(10)
    print()

    after = snapshot()
    show(after, "after")

    print("\n=== growth ===")
    delta = {}
    for key in after:
        a, b = after.get(key), before.get(key)
        delta[key] = (a - b) if (isinstance(a, int) and isinstance(b, int)) else None
        print(f"  {NAMES.get(key, str(key)):<38} +{delta[key]}")

    pen_full = delta.get((13, 2)) or 0
    pen_compat = delta.get((1, 2)) or 0

    print("\n=== verdict ===")
    if pen_full > 0:
        print("  FULL MODE. The tablet sends the pen to interface 0,")
        print("  resolution 40000 x 24000. The init worked.")
    elif pen_compat > 0:
        print("  COMPATIBILITY MODE. The pen still goes to interface 1,")
        print("  resolution 2048 x 2048. The switch did not hold.")
    else:
        print("  The pen gave no reports at all — did it really touch the tablet?")
    return 0


if __name__ == "__main__":
    sys.exit(main())
