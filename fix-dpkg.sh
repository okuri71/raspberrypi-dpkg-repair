#!/usr/bin/env bash
#
# fix-dpkg.sh -- repair a broken / half-configured dpkg state on a Raspberry Pi
#
#   Target : Raspberry Pi OS (Debian 13 "trixie", arm64)
#   Install: /usr/local/sbin/fix-dpkg.sh   (on the Pi)
#   Usage  : sudo fix-dpkg.sh            repair the package database
#            sudo fix-dpkg.sh --status   show the current breakage and exit
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# rpi-connect's maintainer script (/var/lib/dpkg/info/rpi-connect.postinst)
# ends with:
#
#     deb-systemd-invoke --user restart 'rpi-connect.service' ...
#
# If you run `dpkg --configure -a` from a shell that is a descendant of
# rpi-connect.service -- which is exactly what a Raspberry Pi Connect remote
# shell is -- that restart tears your shell down, the pty closes, dpkg takes a
# SIGHUP and dies in the middle of the postinst.  rpi-connect is then left
# "half configured" forever, every retry dies the same way, and the packages
# that an interrupted `apt full-upgrade` left unpacked never get configured.
#
# Symptom on an affected Raspberry Pi (observed on Raspberry Pi OS 13):
#
#   $ sudo dpkg --audit
#    The following packages are only half configured, probably due to problems
#    configuring them the first time. ...
#     rpi-connect          Raspberry Pi Connect - Access your Raspberry Pi from anyw
#
#   with ~100 further packages stuck at "install ok unpacked" (iU) and the
#   trigger list never draining.
#
# Evidence that dpkg was being killed rather than failing:
#
#   * /var/log/dpkg.log showed  "status half-configured rpi-connect"  with
#     NO following "status installed" -- a killed process, not a script error.
#   * journalctl at the failure timestamp:
#         systemd[850]: rpi-connect.service: Failed to kill control group
#             .../app.slice/rpi-connect.service, ignoring: Operation not permitted
#     i.e. dpkg was running INSIDE rpi-connect.service's cgroup.
#   * systemctl --user status rpi-connect showed the operator's own
#     "/bin/bash -l" living in that cgroup.
#   * The postinst exits 0 when run by hand.
#
# ---------------------------------------------------------------------------
# WHAT THIS SCRIPT DOES
# ---------------------------------------------------------------------------
#   1. refuses to run while another apt/dpkg still holds the lock
#   2. runs the repair detached from your terminal, inside the *system*
#      manager, so neither SIGHUP nor an rpi-connect restart can kill it
#   3. temporarily neutralises the offending `deb-systemd-invoke --user
#      restart` line in rpi-connect's postinst and restores it afterwards
#   4. runs dpkg --configure -a, apt-get -f install and the pending triggers
#   5. verifies the result with dpkg --audit and restores rpi-connect's
#      original running state
#
# ---------------------------------------------------------------------------
set -uo pipefail

readonly LOG=/var/log/fix-dpkg.log
readonly RC_POSTINST=/var/lib/dpkg/info/rpi-connect.postinst
readonly WORKDIR=/var/lib/fix-dpkg
RC_BACKUP=""

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

# --------------------------------------------------------------------------
# preflight
# --------------------------------------------------------------------------
[[ ${EUID} -eq 0 ]] || die "must be run as root:  sudo $0"

pi_model() {
    local m=""
    [[ -r /proc/device-tree/model ]] && m=$(tr -d '\0' < /proc/device-tree/model)
    [[ -z $m && -r /sys/firmware/devicetree/base/model ]] && m=$(tr -d '\0' < /sys/firmware/devicetree/base/model)
    printf '%s' "$m"
}

# Another apt/dpkg already running?  dpkg uses fcntl locks, so probe with flock.
lock_held() {
    local f=$1 fd
    exec {fd}>>"$f" 2>/dev/null || return 1
    if flock -n "$fd"; then
        flock -u "$fd"
        exec {fd}>&-
        return 1
    fi
    exec {fd}>&-
    return 0
}

for l in /var/lib/dpkg/lock-frontend \
         /var/lib/dpkg/lock \
         /var/lib/apt/lists/lock \
         /var/cache/apt/archives/lock; do
    [[ -e $l ]] || continue
    lock_held "$l" && die "another apt/dpkg is running (holds $l) - let it finish first"
done

show_state() {
    log "--- dpkg --audit ---"
    dpkg --audit 2>&1 | sed 's/^/    /'
    log "--- packages not in 'ii' state (iU=unpacked iF=half-configured iT=triggers) ---"
    dpkg -l 2>/dev/null | awk 'NR>5 && $1 !~ /^(ii|rc)$/ {printf "    %-4s %-38s %s\n", $1, $2, $3}' | head -60
    local n
    n=$(dpkg -l 2>/dev/null | awk 'NR>5 && $1 !~ /^(ii|rc)$/' | wc -l)
    log "--- $n package(s) not fully installed ---"
}

if [[ ${1:-} == "--status" ]]; then
    show_state
    exit 0
fi

MODEL=$(pi_model)
if [[ -n $MODEL ]]; then
    log "Raspberry Pi detected: $MODEL"
else
    log "WARNING: no Raspberry Pi device tree model found - this script targets Raspberry Pi OS"
fi

if grep -q 'rpi-connect\.service' /proc/self/cgroup 2>/dev/null; then
    log "NOTE: this shell lives inside rpi-connect.service's cgroup."
    log "      A bare 'dpkg --configure -a' here gets SIGHUP-killed when"
    log "      rpi-connect's postinst restarts that service. Working around it."
    log "      Your terminal may still be dropped by that restart - if it is, the"
    log "      repair keeps running in the background. Check with:"
    log "          tail -f /var/log/fix-dpkg-worker.log"
fi

log "==================== BEFORE ===================="
show_state

# --- remember the state of the user services we may disturb ---------------
TARGET_USER=${SUDO_USER:-root}
rc_active() { systemctl --user --machine "$TARGET_USER@" is-active rpi-connect.service >/dev/null 2>&1; }
rc_enabled() { systemctl --user --machine "$TARGET_USER@" is-enabled rpi-connect.service >/dev/null 2>&1; }
RC_WAS_ACTIVE=0
rc_active && RC_WAS_ACTIVE=1
log "rpi-connect.service was: $( ((RC_WAS_ACTIVE)) && echo active || echo inactive ) (user: $TARGET_USER)"

# --------------------------------------------------------------------------
# neutralise the rpi-connect postinst's service restart
# --------------------------------------------------------------------------
restore_postinst() {
    if [[ -n $RC_BACKUP && -f $RC_BACKUP ]]; then
        cp -a "$RC_BACKUP" "$RC_POSTINST"
        log "restored $RC_POSTINST"
        rm -f "$RC_BACKUP"
    fi
}
trap restore_postinst EXIT INT TERM

if [[ -f $RC_POSTINST ]] && grep -q 'deb-systemd-invoke --user restart' "$RC_POSTINST"; then
    RC_BACKUP=$(mktemp /tmp/rpi-connect.postinst.XXXXXX)
    cp -a "$RC_POSTINST" "$RC_BACKUP"
    sed -i 's|deb-systemd-invoke --user restart|# fix-dpkg.sh: disabled: deb-systemd-invoke --user restart|' "$RC_POSTINST"
    if sh -n "$RC_POSTINST" 2>/dev/null; then
        log "neutralised rpi-connect postinst service-restart (backup: $RC_BACKUP)"
    else
        cp -a "$RC_BACKUP" "$RC_POSTINST"
        RC_BACKUP=""
        log "could not neutralise postinst safely - left it untouched"
    fi
fi

# --------------------------------------------------------------------------
# the repair worker
# --------------------------------------------------------------------------
mkdir -p "$WORKDIR"
cat > "$WORKDIR/worker.sh" <<'WORKER'
#!/bin/bash
# Runs as root, inside a transient *system* unit -> not in rpi-connect.service's
# cgroup and not attached to any tty, so neither SIGHUP nor a service restart
# can kill it halfway through.
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
exec > >(tee -a /var/log/fix-dpkg-worker.log) 2>&1
echo "### worker start $(date -Is)"
echo "### cgroup: $(cat /proc/self/cgroup)"
echo "### step 1: dpkg --configure -a"
dpkg --configure -a
echo "### step 2: dpkg --configure --pending"
dpkg --configure --pending
echo "### step 3: apt-get -f install"
apt-get -y -f install
echo "### step 4: pending triggers"
# NOTE: `apt-get --triggers-only` is rejected on Debian/Raspberry Pi OS because
# APT::Get::List-Cleanup is "false" -> use dpkg directly instead.
dpkg --triggers-only -a
echo "### step 5: dpkg --configure -a (catch stragglers)"
dpkg --configure -a
echo "### verification: dpkg --audit"
dpkg --audit
echo "### verification: packages not fully installed"
dpkg -l 2>/dev/null | awk 'NR>5 && $1 !~ /^(ii|rc)$/ {printf "    %-4s %-38s %s\n", $1, $2, $3}'
n=$(dpkg -l 2>/dev/null | awk 'NR>5 && $1 !~ /^(ii|rc)$/' | wc -l)
if [ "$n" -eq 0 ] && [ -z "$(dpkg --audit 2>/dev/null)" ]; then
    echo "### VERDICT: OK - package database is consistent"
    rc=0
else
    echo "### VERDICT: STILL BROKEN - $n package(s) not fully installed"
    rc=1
fi
echo "### worker end $(date -Is) verdict=$rc"
exit $rc
WORKER
chmod +x "$WORKDIR/worker.sh"

run_detached() {
    local script=$1
    if command -v systemd-run >/dev/null 2>&1; then
        local unit
        unit="fix-dpkg-$(date +%s)"
        log "running repair in transient system unit $unit"
        systemd-run --quiet --wait --collect \
            --unit="$unit" \
            --service-type=oneshot \
            --property=TimeoutStartSec=3600 \
            --property=StandardOutput=journal+console \
            --property=StandardError=journal+console \
            "$script"
        return $?
    fi
    log "systemd-run unavailable - falling back to setsid (still detached from tty)"
    setsid --wait "$script" </dev/null >/dev/null 2>&1
    return $?
}

run_detached "$WORKDIR/worker.sh"
rc=$?
log "repair worker exited with $rc"

if [[ -f /var/log/fix-dpkg-worker.log ]]; then
    log "--- worker log (tail) ---"
    tail -n 40 /var/log/fix-dpkg-worker.log | sed 's/^/    /'
fi

# --------------------------------------------------------------------------
# verify
# --------------------------------------------------------------------------
log "==================== AFTER ===================="
show_state

if [[ $(dpkg --audit 2>/dev/null | wc -l) -eq 0 ]] &&
   [[ $(dpkg -l 2>/dev/null | awk 'NR>5 && $1 !~ /^(ii|rc)$/' | wc -l) -eq 0 ]]; then
    log "OK - package database is consistent."

    if ((RC_WAS_ACTIVE)) && ! rc_active; then
        log "restarting rpi-connect.service (it was running before the repair)"
        systemctl --user --machine "$TARGET_USER@" restart rpi-connect.service || true
        sleep 2
    fi
    if rc_active; then
        log "rpi-connect.service is running."
    elif rc_enabled; then
        log "rpi-connect.service is enabled but not running - start it with:"
        log "    sudo systemctl --user --machine $TARGET_USER@ start rpi-connect.service"
    else
        log "rpi-connect.service is disabled/not installed - nothing to do."
    fi

    pending=$(apt-get -s full-upgrade 2>/dev/null | grep -E '^[0-9]+ upgraded' | head -1)
    log "note: remaining upgrades -> ${pending:-none}"
    exit 0
fi

log "STILL BROKEN - review $WORKDIR and the output above."
exit 1
