#!/usr/bin/env bash
#
# uninstall.sh -- remove fix-dpkg.sh from a Raspberry Pi
#
#   PI_HOST=pi@raspberrypi.local ./uninstall.sh
#
# Optional environment variables:
#   PI_HOST   ssh destination (required), e.g. user@host or user@host.lan
#   PI_NAME   friendly name used in messages (default: host part of PI_HOST)
#   SSH_KEY   private key to use (default: your ssh config / ssh-agent)
#
set -euo pipefail

PI_HOST="${PI_HOST:-}"
PI_NAME="${PI_NAME:-${PI_HOST#*@}}"
SSH_KEY="${SSH_KEY:-}"

if [[ -z $PI_HOST ]]; then
    printf '\033[1;31m!!\033[0m PI_HOST is required, e.g.:\n' >&2
    printf '    PI_HOST=pi@raspberrypi.local %s\n' "$0" >&2
    exit 1
fi

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
if [[ -n $SSH_KEY ]]; then
    SSH_OPTS+=(-i "$SSH_KEY")
fi

ssh_() { ssh "${SSH_OPTS[@]}" "$PI_HOST" "$@"; }

printf '\033[1;36m==>\033[0m removing fix-dpkg.sh from %s (%s)\n' "$PI_NAME" "$PI_HOST"

ssh_ 'sudo -n rm -f /usr/local/sbin/fix-dpkg.sh
      sudo -n rm -rf /var/lib/fix-dpkg
      rm -f "$HOME/fix-dpkg.sh"
      if [ -f /var/lib/dpkg/info/rpi-connect.postinst ] && \
         grep -q "fix-dpkg.sh: disabled" /var/lib/dpkg/info/rpi-connect.postinst ; then
          echo "WARNING: rpi-connect.postinst still carries the fix-dpkg.sh marker" >&2
          echo "         reinstall rpi-connect to restore it:  sudo apt-get install --reinstall rpi-connect" >&2
      fi
      echo "removed."'
