#!/usr/bin/env bash
#
# test_break_and_fix.sh -- reproduce the Raspberry Pi breakage and prove the
#                           repair script clears it.
#
# Runs ON THE PI (invoked by run-tests.sh over ssh).
#
# What it does:
#   1. breaks the package database by unpacking packages and leaving them
#      unconfigured (state "iU") - the same state an interrupted
#      `apt full-upgrade` leaves behind
#   2. runs fix-dpkg.sh from a shell that lives INSIDE
#      rpi-connect.service's cgroup, while that service is being restarted
#      underneath it every few seconds
#      -> this is the exact condition that made plain `dpkg --configure -a`
#         die with a SIGHUP on the original Pi
#   3. asserts the database ends up clean
#
set -uo pipefail

SCRIPT="${1:-/usr/local/sbin/fix-dpkg.sh}"
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_UID="$(id -u "$TARGET_USER" 2>/dev/null || id -u)"
CG="/sys/fs/cgroup/user.slice/user-${TARGET_UID}.slice/user@${TARGET_UID}.service/app.slice/rpi-connect.service/cgroup.procs"
RC=0

ok()   { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; }
bad()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; RC=1; }
info() { printf '  ---- %s\n' "$*"; }

not_ii() { dpkg -l 2>/dev/null | awk 'NR>5 && $1 !~ /^(ii|rc)$/' | wc -l; }

printf '\n=== test_break_and_fix: script=%s ===\n' "$SCRIPT"

if [[ ! -x $SCRIPT ]]; then
    bad "script not found/executable: $SCRIPT"
    exit 1
fi

# ---------------------------------------------------------------- 1. break it
info "breaking the package database (unpack without configure)"
BROKEN=0
for deb in /var/cache/apt/archives/rpi-connect_*.deb \
           /var/cache/apt/archives/vlc-plugin-base_*_arm64.deb \
           /var/cache/apt/archives/libcurl4t64_*_arm64.deb; do
    [[ -f $deb ]] || continue
    dpkg --unpack "$deb" >/dev/null 2>&1 && BROKEN=$((BROKEN+1))
done

n=$(not_ii)
if ((n > 0)); then
    ok "broke the state: $n package(s) not fully installed"
    dpkg -l 2>/dev/null | awk 'NR>5 && $1 !~ /^(ii|rc)$/ {printf "         %-4s %s\n", $1, $2}'
else
    bad "could not break the package database (no cached .deb to unpack?)"
    exit 1
fi

# ------------------------------------------- 2. kill it while we repair it
info "starting a background loop that restarts rpi-connect.service every 3s"
( for _ in $(seq 1 20); do
      systemctl --user --machine "$TARGET_USER@" restart rpi-connect.service >/dev/null 2>&1
      sleep 3
  done ) &
KILLER=$!
sleep 1

info "running the repair from inside rpi-connect.service's cgroup"
if [[ -w $CG ]]; then
    setsid bash -c "echo \$\$ > '$CG'; exec '$SCRIPT'" >/tmp/fix-dpkg-test.log 2>&1
    RC_SCRIPT=$?
    info "repair script exit code: $RC_SCRIPT"
else
    info "cgroup file not writable - running the repair normally"
    "$SCRIPT" >/tmp/fix-dpkg-test.log 2>&1
    RC_SCRIPT=$?
    info "repair script exit code: $RC_SCRIPT"
fi

kill "$KILLER" 2>/dev/null
wait "$KILLER" 2>/dev/null

# The outer script may itself have been killed by the rpi-connect restart
# (that is the bug being reproduced) - the worker runs on in the background,
# so wait for it to finish before checking the result.
info "waiting for the detached worker to finish"
for _ in $(seq 1 120); do
    grep -q '### worker end' /var/log/fix-dpkg-worker.log 2>/dev/null && break
    sleep 1
done

# ---------------------------------------------------------------- 3. verify
info "verifying the result"
n=$(not_ii)
audit=$(dpkg --audit 2>/dev/null)

if ((n == 0)); then
    ok "all packages fully installed"
else
    bad "$n package(s) still not fully installed"
    dpkg -l 2>/dev/null | awk 'NR>5 && $1 !~ /^(ii|rc)$/ {printf "         %-4s %s\n", $1, $2}'
fi

if [[ -z $audit ]]; then
    ok "dpkg --audit is clean"
else
    bad "dpkg --audit still reports problems"
    printf '%s\n' "$audit" | sed 's/^/         /'
fi

if grep -q '### VERDICT: OK' /var/log/fix-dpkg-worker.log 2>/dev/null; then
    ok "worker logged VERDICT: OK"
else
    bad "worker did not log VERDICT: OK"
fi

if grep -q 'fix-dpkg.sh: disabled' /var/lib/dpkg/info/rpi-connect.postinst 2>/dev/null; then
    bad "rpi-connect.postinst was NOT restored"
else
    ok "rpi-connect.postinst was restored"
fi

printf '\n=== test_break_and_fix: %s ===\n' "$( ((RC==0)) && echo PASS || echo FAIL )"
exit $RC
