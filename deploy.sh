#!/usr/bin/env bash
#
# deploy.sh -- install fix-dpkg.sh on a Raspberry Pi over SSH
#
#   ./deploy.sh              copy + install, then show the current status
#   ./deploy.sh --run        copy + install, then actually run the repair
#   ./deploy.sh --status     just show the Pi's current package state
#
# The target has no default. Point it at your Pi, for example:
#
#   PI_HOST=pi@raspberrypi.local ./deploy.sh
#   PI_HOST=user@192.168.1.50 PI_NAME=my-pi ./deploy.sh
#
# Optional environment variables:
#   PI_HOST   ssh destination (required), e.g. user@host or user@host.lan
#   PI_NAME   friendly name used in messages (default: host part of PI_HOST)
#   SSH_KEY   private key to use (default: your ssh config / ssh-agent)
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PI_HOST="${PI_HOST:-}"
PI_NAME="${PI_NAME:-${PI_HOST#*@}}"
SSH_KEY="${SSH_KEY:-}"
REMOTE_SCRIPT=/usr/local/sbin/fix-dpkg.sh

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; }

if [[ -z $PI_HOST ]]; then
    err "PI_HOST is required."
    printf '    example: PI_HOST=pi@raspberrypi.local %s\n' "$0" >&2
    exit 1
fi

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
if [[ -n $SSH_KEY ]]; then
    SSH_OPTS+=(-i "$SSH_KEY")
fi

ssh_() { ssh "${SSH_OPTS[@]}" "$PI_HOST" "$@"; }
scp_() { scp "${SSH_OPTS[@]}" "$@"; }

say "target: $PI_NAME ($PI_HOST)"

say "checking the Pi is reachable"
if ! ssh_ 'hostname; dpkg --print-architecture' ; then
    err "cannot reach $PI_HOST - check PI_HOST, your ssh config and the network"
    exit 1
fi

case "${1:-}" in
--status)
    say "package state on $PI_NAME"
    ssh_ 'sudo -n dpkg --audit; echo "--- not-ii packages ---"; dpkg -l 2>/dev/null | awk "NR>5 && \$1 !~ /^(ii|rc)\$/ {print \$1, \$2}"'
    exit 0
    ;;
esac

say "copying fix-dpkg.sh"
scp_ "$HERE/fix-dpkg.sh" "$PI_HOST:/tmp/fix-dpkg.sh"

say "installing to $REMOTE_SCRIPT"
ssh_ "sudo -n install -m 0755 -o root -g root /tmp/fix-dpkg.sh $REMOTE_SCRIPT && rm -f /tmp/fix-dpkg.sh"

REMOTE_HOME=$(ssh_ 'printf %s "$HOME"')
if [[ -n $REMOTE_HOME && $REMOTE_HOME != /root ]]; then
    ssh_ "sudo -n cp $REMOTE_SCRIPT $REMOTE_HOME/fix-dpkg.sh && sudo -n chown \$(id -un):\$(id -gn) $REMOTE_HOME/fix-dpkg.sh"
fi

say "installed on $PI_NAME:"
ssh_ "ls -la $REMOTE_SCRIPT"

if [[ "${1:-}" == "--run" ]]; then
    say "running the repair on $PI_NAME"
    ssh_ "sudo -n $REMOTE_SCRIPT"
    exit $?
fi

say "run the repair with:"
if [[ -n $SSH_KEY ]]; then
    echo "    ssh -i $SSH_KEY $PI_HOST 'sudo $REMOTE_SCRIPT'"
else
    echo "    ssh $PI_HOST 'sudo $REMOTE_SCRIPT'"
fi
say "or, from the Pi itself:"
echo "    sudo fix-dpkg.sh"
say "status only:"
echo "    sudo fix-dpkg.sh --status"
