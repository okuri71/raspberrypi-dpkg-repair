#!/usr/bin/env bash
#
# run-tests.sh -- test harness for raspberrypi-dpkg-repair
#
#   ./tests/run-tests.sh              run everything against the Pi
#   ./tests/run-tests.sh --local      only the checks that need no Pi
#
# The remote tests need a target:
#
#   PI_HOST=pi@raspberrypi.local ./tests/run-tests.sh
#
# Optional environment variables:
#   PI_HOST   ssh destination (required for remote tests), e.g. user@host
#   PI_NAME   friendly name used in messages (default: host part of PI_HOST)
#   SSH_KEY   private key to use (default: your ssh config / ssh-agent)
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

PI_HOST="${PI_HOST:-}"
PI_NAME="${PI_NAME:-${PI_HOST#*@}}"
SSH_KEY="${SSH_KEY:-}"
REMOTE_TEST=/tmp/test_break_and_fix.sh

PASS=0
FAIL=0

ok()  { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
hdr() { printf '\n\033[1;36m### %s\033[0m\n' "$*"; }

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
if [[ -n $SSH_KEY ]]; then
    SSH_OPTS+=(-i "$SSH_KEY")
fi
ssh_() { ssh "${SSH_OPTS[@]}" "$PI_HOST" "$@"; }
scp_() { scp "${SSH_OPTS[@]}" "$@"; }

# --------------------------------------------------------------- local tests
hdr "local: bash syntax"
for f in "$ROOT"/*.sh "$HERE"/*.sh; do
    [[ -f $f ]] || continue
    if bash -n "$f" 2>/dev/null; then ok "syntax: $(basename "$f")"; else bad "syntax: $(basename "$f")"; fi
done

hdr "local: shellcheck (if available)"
if command -v shellcheck >/dev/null 2>&1; then
    for f in "$ROOT"/*.sh "$HERE"/*.sh; do
        [[ -f $f ]] || continue
        if shellcheck -S warning "$f" >/tmp/sc.out 2>&1; then
            ok "shellcheck: $(basename "$f")"
        else
            bad "shellcheck: $(basename "$f")"
            sed 's/^/         /' /tmp/sc.out
        fi
    done
else
    printf '  ---- shellcheck not installed, skipped\n'
fi

hdr "local: required strings present in fix-dpkg.sh"
for needle in "deb-systemd-invoke --user restart" "dpkg --triggers-only -a" "systemd-run"; do
    if grep -qF "$needle" "$ROOT/fix-dpkg.sh"; then
        ok "contains: $needle"
    else
        bad "missing: $needle"
    fi
done

if [[ ${1:-} == "--local" ]]; then
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    exit $((FAIL > 0))
fi

# ---------------------------------------------------------------- remote test
hdr "remote tests"
if [[ -z $PI_HOST ]]; then
    bad "PI_HOST is not set - skipping remote tests"
    printf '     set it with: PI_HOST=user@host %s\n' "$0"
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    exit $((FAIL > 0))
fi

hdr "remote: $PI_NAME ($PI_HOST)"
if ! ssh_ 'hostname' >/dev/null 2>&1; then
    bad "cannot reach $PI_HOST - skipping remote tests"
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    exit $((FAIL > 0))
fi
ok "reachable"

if ! ssh_ 'test -x /usr/local/sbin/fix-dpkg.sh'; then
    bad "/usr/local/sbin/fix-dpkg.sh not installed on the Pi - run ./deploy.sh first"
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    exit $((FAIL > 0))
fi
ok "fix-dpkg.sh installed on the Pi"

scp_ "$HERE/test_break_and_fix.sh" "$PI_HOST:$REMOTE_TEST"
if ssh_ "sudo -n bash $REMOTE_TEST /usr/local/sbin/fix-dpkg.sh"; then
    ok "break_and_fix scenario"
else
    bad "break_and_fix scenario"
fi
ssh_ "rm -f $REMOTE_TEST" >/dev/null 2>&1

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
