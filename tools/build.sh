#!/bin/bash
# Build from source, sign and install the driver as a LaunchAgent.
# Needs Swift — that is Xcode or the Command Line Tools.
#
#   tools/build.sh                    build, install and start
#   tools/build.sh package            build a release archive in dist/, install nothing
#   tools/build.sh uninstall          remove, keeping the config and the logs
#   tools/build.sh uninstall --purge  remove everything the installers ever wrote
#
# To install without a toolchain, take a release archive and run its install.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tools/common.sh
. "$ROOT/tools/common.sh"

if [ "${1:-}" = "uninstall" ]; then
    do_uninstall "${2:-}"
    exit 0
fi

PACKAGE=0
if [ "${1:-}" = "package" ]; then PACKAGE=1; fi

echo "==> Building release"
cd "$ROOT"
swift build -c release

sign() {
    # On arm64 an unsigned binary does not run at all. This is a rule of the
    # architecture; Gatekeeper is a separate matter.
    if security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
        # --timestamp=none: a timestamp would make the signature non-deterministic
        # and break the CDHash comparison below; a local signature does not need it.
        codesign --force --sign "$IDENTITY" ${2:+-i "$2"} --timestamp=none "$1"
    else
        echo "==> WARNING: certificate '$IDENTITY' not found, signing ad-hoc."
        echo "    Permissions will turn off on every rebuild. To set up a"
        echo "    certificate, see the code signature section in README.md."
        codesign --force --sign - ${2:+-i "$2"} "$1" 2>/dev/null
    fi
}

# SwiftPM builds a bare executable. A minimal wrapper turns it into an app: an
# Info.plist next to the binary. Without it the process has no bundle identifier,
# and the system does not count it as an application.
STAGED_APP=".build/release/Parblo A610.app"
rm -rf "$STAGED_APP"
mkdir -p "$STAGED_APP/Contents/MacOS"
cp "$ROOT/Resources/Settings-Info.plist" "$STAGED_APP/Contents/Info.plist"
cp ".build/release/ParbloA610Settings" "$STAGED_APP/Contents/MacOS/ParbloA610Settings"
sign "$STAGED_APP"

if [ "$PACKAGE" = 1 ]; then
    VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo local)"
    NAME="parblo-a610-craft-driver-$VERSION"
    DIST="$ROOT/dist/$NAME"
    echo "==> Packaging $NAME"
    rm -rf "$ROOT/dist"
    mkdir -p "$DIST/payload/bin"

    cp ".build/release/parblo-a610-craft-driver" "$DIST/payload/bin/"
    sign "$DIST/payload/bin/parblo-a610-craft-driver" "$LABEL"
    cp -R "$STAGED_APP" "$DIST/payload/"
    cp "$ROOT/Resources/$LABEL.plist" "$DIST/payload/"
    cp "$ROOT/tools/install.sh" "$ROOT/tools/common.sh" "$DIST/"
    cp "$ROOT/Resources/INSTALL.txt" "$DIST/"
    chmod +x "$DIST/install.sh"

    tar -czf "$ROOT/dist/$NAME.tar.gz" -C "$ROOT/dist" "$NAME"
    echo "    $ROOT/dist/$NAME.tar.gz"
    echo
    echo "The archive installs with no toolchain: unpack it and run ./install.sh."
    echo "It is signed with '$IDENTITY' and NOT notarized, so whoever downloads it"
    echo "gets a quarantine flag and install.sh has to ask before clearing it."
    exit 0
fi

mkdir -p "$SUPPORT/bin"
# Unload before replacing the file: launchd holds the old binary.
unload_agent

# Replacing the binary changes the signature, and with it the fingerprint macOS uses
# to remember the granted permissions: the Input Monitoring and Accessibility switches
# turn off and the driver stops starting. So we touch the file only when it really
# changed — running the script again with no source edits should cost nothing.
# We cannot compare the files as a whole: a certificate signature includes the signing
# time, so two runs over the very same code give different bytes. We compare the
# CDHash — the hash of the code itself, which has no time in it.
STAGED="$SUPPORT/bin/.staged"
cp ".build/release/parblo-a610-craft-driver" "$STAGED"
sign "$STAGED" "$LABEL"

cdhash() { codesign -d --verbose=4 "$1" 2>&1 | grep -m1 "^CDHash=" || true; }

if [ -f "$BINARY" ] && [ -n "$(cdhash "$STAGED")" ] && [ "$(cdhash "$STAGED")" = "$(cdhash "$BINARY")" ]; then
    rm -f "$STAGED"
    echo "==> Code did not change, leaving the binary alone"
else
    mv "$STAGED" "$BINARY"
    echo "==> New binary installed: $BINARY"
fi

echo "==> LaunchAgent"
render_plist "$ROOT/Resources/$LABEL.plist"
load_agent

echo "==> Settings app"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R "$STAGED_APP" "$APP"
echo "    $APP"

print_permissions
echo
echo "An ad-hoc signature changes on every rebuild, and macOS sees the binary as new —"
echo "after a reinstall you will most likely have to grant the permissions again."
