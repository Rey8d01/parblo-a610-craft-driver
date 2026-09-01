#!/bin/bash
# All project checks in one command. The same idea as `make lint test`.
#
#   tools/check.sh          fast checks
#   tools/check.sh --full   plus sanitizers (slower)
#
# Everything started here comes with Swift and Xcode — there is nothing to install.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FULL=0
[ "${1:-}" = "--full" ] && FULL=1

fails=0
step() {
    local name="$1"; shift
    printf '\033[1m==> %s\033[0m\n' "$name"
    local out
    if out="$("$@" 2>&1)"; then
        printf '    ok\n'
    else
        printf '    FAILED\n'
        printf '%s\n' "$out" | sed 's/^/    /' | head -30
        fails=$((fails + 1))
    fi
}

# Compiler warnings are treated as errors: the project has zero of them,
# and that state is worth keeping.
step "Swift build, warnings as errors" \
    swift build -c release -Xswiftc -warnings-as-errors

step "C warnings" \
    clang -fsyntax-only -Wall -Wextra -Wshadow -Wconversion \
        -ISources/CUCLogic/include Sources/CUCLogic/uclogic.c

# The analyzer has checks for CoreFoundation ownership — exactly the class of
# bugs that is possible in the C layer with its manual retain/release.
step "clang static analyzer" \
    clang --analyze -Xclang -analyzer-checker=core,deadcode,security,unix,osx \
        --analyzer-output text -ISources/CUCLogic/include \
        Sources/CUCLogic/uclogic.c -o /dev/null

step "Swift formatting" \
    swift format lint --recursive --strict Sources/ Tests/

step "Tests" swift test

if [ "$FULL" = 1 ]; then
    step "Tests under ASan" swift test --sanitize=address
    step "Tests under UBSan" swift test --sanitize=undefined
fi

# `bash -n` takes one file and turns the rest into positional parameters, so the
# scripts are checked one at a time.
check_shell() { for f in "$@"; do bash -n "$f" || return 1; done; }
step "shell scripts" check_shell tools/build.sh tools/install.sh tools/common.sh
step "plist is valid" plutil -lint \
    Resources/com.rey.parblo-a610-craft-driver.plist \
    Resources/Settings-Info.plist

echo
if [ "$fails" -eq 0 ]; then
    printf '\033[1mAll checks passed.\033[0m\n'
else
    printf '\033[1mFailed: %d\033[0m\n' "$fails"
fi
exit "$fails"
