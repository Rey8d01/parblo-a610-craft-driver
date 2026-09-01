#!/bin/bash
# Paths and steps shared by the two installers. Sourced, never run on its own.
#
#   tools/build.sh   builds from source and installs — for developers
#   install.sh       installs the prebuilt files from a release archive
#
# Both put the same files in the same places, so one can replace the other.

LABEL="com.rey.parblo-a610-craft-driver"
SUPPORT="$HOME/Library/Application Support/parblo-a610-craft-driver"
BINARY="$SUPPORT/bin/parblo-a610-craft-driver"
LOG="$SUPPORT/parblo-a610-craft-driver.log"
# The driver writes the main log itself; launchd only gets the output from a crash.
CRASHLOG="$SUPPORT/parblo-a610-craft-driver.crash.log"
# The settings app goes into the home ~/Applications: it needs no admin rights, but
# it is still visible in Spotlight and Launchpad.
APP="$HOME/Applications/Parblo A610.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
# Certificate used for the code signature. A signing requirement made by a real
# certificate points at the certificate and the identifier, so it survives rebuilds.
# An ad-hoc signature puts the hash of the contents into the requirement, so after
# every edit macOS sees the binary as a new program and drops the permissions it was
# given.
IDENTITY="Parblo A610 Craft Driver"

# The label is substituted into the template, so it exists in one place. A file name
# and a Label key that disagree register the job under a different name, and after
# that launchctl cannot find it.
render_plist() {
    mkdir -p "$HOME/Library/LaunchAgents"
    sed -e "s|__LABEL__|$LABEL|g" -e "s|__BINARY__|$BINARY|g" -e "s|__CRASHLOG__|$CRASHLOG|g" \
        "$1" > "$PLIST"
}

load_agent() {
    launchctl bootstrap "$DOMAIN" "$PLIST"
    launchctl kickstart -k "$DOMAIN/$LABEL"
}

unload_agent() {
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
}

do_uninstall() {
    local purge=0
    if [ "${1:-}" = "--purge" ]; then purge=1; fi

    unload_agent
    rm -f "$PLIST"

    # The settings app lives in the menu bar and keeps running after the agent is
    # gone. Deleting the bundle under a live process would leave it running with no
    # files behind it.
    pkill -f "$APP/Contents/MacOS/ParbloA610Settings" 2>/dev/null || true
    rm -rf "$APP"

    if [ "$purge" = 1 ]; then
        rm -rf "$SUPPORT"
        echo "Removed: the agent, $PLIST, $APP, and all of $SUPPORT."
    else
        rm -f "$BINARY"
        rmdir "$SUPPORT/bin" 2>/dev/null || true
        echo "Removed: the agent, $PLIST, $APP and the binary."
        echo "The config and the logs are still in $SUPPORT."
        echo "Run 'uninstall --purge' to drop those as well."
    fi

    echo
    echo "Two things a script cannot clean up:"
    echo "  • Privacy & Security still lists the binary under Input Monitoring and"
    echo "    Accessibility. Remove those rows with the minus button."
    echo "  • The certificate '$IDENTITY' stays in the login keychain, together with"
    echo "    its private key. Delete both there if nothing else signs with them."
}

print_permissions() {
    echo
    echo "Done. Log: $LOG"
    echo "Config:    $SUPPORT/config.json"
    echo
    echo "TWO permissions are needed, both for  $BINARY"
    echo "System Settings → Privacy & Security →"
    echo "  • Input Monitoring   — to read the tablet and seize it"
    echo "  • Accessibility      — so the events are really sent"
    echo
    echo "The second one is easy to miss, and without it the tablet is seized and"
    echo "completely dead. The driver checks both permissions at start and will not"
    echo "run without them — see the log."
    echo
    echo "Settings app: $APP"
    echo "Its icon appears in the menu bar. It needs no permissions: it writes the config"
    echo "as a file, and it gets the pressure for calibration as a normal application."
    echo
    echo "After you turn the switches on:"
    echo "  launchctl kickstart -k $DOMAIN/$LABEL"
}
