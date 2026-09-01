#!/bin/bash
# Install the driver from a release archive. Nothing is built here, so no Xcode and
# no Swift are needed — the files are already compiled.
#
#   ./install.sh                    install and start
#   ./install.sh uninstall          remove, keeping the config and the logs
#   ./install.sh uninstall --purge  remove everything the installers ever wrote
#
# To build from source instead, use tools/build.sh in the repository.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/common.sh
. "$HERE/common.sh"

if [ "${1:-}" = "uninstall" ]; then
    do_uninstall "${2:-}"
    exit 0
fi

PAYLOAD="$HERE/payload"
if [ ! -x "$PAYLOAD/bin/parblo-a610-craft-driver" ]; then
    echo "No compiled files next to this script."
    echo
    echo "This installer belongs to a release archive and expects a payload/ folder"
    echo "beside it. In a source checkout, build and install with:"
    echo "    tools/build.sh"
    exit 1
fi

# Everything a browser downloads is marked with com.apple.quarantine, and macOS
# refuses to run quarantined code that Apple has not notarized. Notarization needs a
# paid developer account, which this build does not have. So the flag has to go, and
# whoever runs this decides that, answering the question below.
if xattr -p com.apple.quarantine "$PAYLOAD/bin/parblo-a610-craft-driver" >/dev/null 2>&1; then
    echo "These files came from a download and macOS has flagged them as quarantined."
    echo
    echo "This build is signed, and it is NOT notarized by Apple. Clearing the flag is"
    echo "what lets it run. The driver then asks for Input Monitoring and Accessibility,"
    echo "which together mean reading every input device and posting events. Continue"
    echo "only if you trust where this archive came from."
    echo
    printf "Clear the quarantine flag and install? [y/N] "
    read -r answer || answer=""
    case "$answer" in
        [Yy]*) xattr -dr com.apple.quarantine "$PAYLOAD" ;;
        *) echo "Stopped. Nothing was installed."; exit 1 ;;
    esac
fi

echo "==> Driver"
mkdir -p "$SUPPORT/bin"
# Unload before replacing the file: launchd holds the old binary.
unload_agent
cp "$PAYLOAD/bin/parblo-a610-craft-driver" "$BINARY"
echo "    $BINARY"

echo "==> LaunchAgent"
render_plist "$PAYLOAD/$LABEL.plist"
load_agent

echo "==> Settings app"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R "$PAYLOAD/Parblo A610.app" "$APP"
echo "    $APP"

print_permissions
