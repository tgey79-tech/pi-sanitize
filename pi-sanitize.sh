#!/usr/bin/env bash
# =============================================================================
# pi-sanitize.sh
# -----------------------------------------------------------------------------
# Removes personal identity / GitHub-account / development traces from a
# Raspberry Pi so the SD-card image can be handed out to third parties
# without leaking the developer's data.
#
# Designed to be dropped into ANY Raspberry Pi project. Configure the project
# directory either via env-var or first positional argument:
#
#   sudo bash pi-sanitize.sh                       # uses /home/pi
#   sudo bash pi-sanitize.sh /home/pi/myproject    # specific project dir
#   PROJECT_DIR=/srv/app sudo -E bash pi-sanitize.sh
#
# Flags:
#   --yes / -y         : assume yes to every confirmation
#   --dry-run          : only print what would happen, change nothing
#   --keep-git         : do NOT touch the project's .git history
#   --zero-free-space  : after cleanup, fill free space with zeros so the
#                        image compresses better (slow, optional; not needed
#                        if you use pishrink afterwards)
#   -h | --help        : show this header
#
# What it does:
#   1. Replace the project git repo with a fresh local-only repo
#      (removes history, GitHub remote, author email)
#   2. Wipe ~/.vscode-server, Copilot / PR extension caches
#   3. Remove any other .git directories under /var/www
#   4. Truncate bash / python / less / zsh history for pi + root
#   5. Delete SSH host keys (regenerated on next boot)
#   6. Truncate system journal and /var/log
#   7. Drop APT / pip / npm caches and /tmp
#   8. Optional: zero free space
#
# After running, reboot, shut down, dd the image and (optionally) run pishrink.
# =============================================================================

set -u

PROJECT_DIR="${PROJECT_DIR:-}"
DRY_RUN=0
ASSUME_YES=0
KEEP_GIT=0
ZERO_FREE=0

POSITIONAL=()
for a in "$@"; do
    case "$a" in
        --dry-run)         DRY_RUN=1 ;;
        --yes|-y)          ASSUME_YES=1 ;;
        --keep-git)        KEEP_GIT=1 ;;
        --zero-free-space) ZERO_FREE=1 ;;
        -h|--help)         sed -n '2,40p' "$0"; exit 0 ;;
        -*)                echo "unknown option: $a" >&2; exit 2 ;;
        *)                 POSITIONAL+=("$a") ;;
    esac
done

if [[ -z "$PROJECT_DIR" && ${#POSITIONAL[@]} -gt 0 ]]; then
    PROJECT_DIR="${POSITIONAL[0]}"
fi
PROJECT_DIR="${PROJECT_DIR:-/home/pi}"

PI_USER="${SUDO_USER:-pi}"
PI_HOME="$(getent passwd "$PI_USER" | cut -d: -f6)"
PI_HOME="${PI_HOME:-/home/$PI_USER}"

NEUTRAL_NAME="${NEUTRAL_NAME:-Raspberry Pi}"
NEUTRAL_EMAIL="${NEUTRAL_EMAIL:-pi@localhost}"

if [[ $EUID -ne 0 ]]; then
    echo "Please run with sudo." >&2
    exit 1
fi

run() {
    if (( DRY_RUN )); then
        echo "DRY-RUN: $*"
    else
        echo ">>> $*"
        eval "$@"
    fi
}
confirm() {
    (( ASSUME_YES )) && return 0
    read -r -p "$1 [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}
banner() {
    echo
    echo "=============================================================="
    echo "  $1"
    echo "=============================================================="
}

# -----------------------------------------------------------------------------
banner "Plan"
cat <<EOF
User       : $PI_USER  (home: $PI_HOME)
Project    : $PROJECT_DIR
Mode       : $([[ $DRY_RUN -eq 1 ]] && echo "DRY-RUN (no changes)" || echo "WILL APPLY CHANGES")
Keep .git  : $([[ $KEEP_GIT -eq 1 ]] && echo "yes" || echo "no (will be reset)")
Zero free  : $([[ $ZERO_FREE -eq 1 ]] && echo "yes (slow)" || echo "no")
EOF
confirm "Continue?" || { echo "Aborted."; exit 0; }

# -----------------------------------------------------------------------------
banner "1) Sanitize project git repo"
if (( KEEP_GIT )); then
    echo "--keep-git given, skipping."
elif [[ -d "$PROJECT_DIR/.git" ]]; then
    if confirm "Delete .git history of $PROJECT_DIR and re-init clean?"; then
        run "rm -rf '$PROJECT_DIR/.git'"
        run "sudo -u '$PI_USER' git -C '$PROJECT_DIR' init -q"
        run "sudo -u '$PI_USER' git -C '$PROJECT_DIR' config user.name  '$NEUTRAL_NAME'"
        run "sudo -u '$PI_USER' git -C '$PROJECT_DIR' config user.email '$NEUTRAL_EMAIL'"
        run "sudo -u '$PI_USER' git -C '$PROJECT_DIR' add -A"
        run "sudo -u '$PI_USER' git -C '$PROJECT_DIR' commit -q -m 'initial' --author='$NEUTRAL_NAME <$NEUTRAL_EMAIL>' || true"
    fi
else
    echo "No .git found in $PROJECT_DIR, skipping."
fi

# -----------------------------------------------------------------------------
banner "2) Wipe VS Code Server / Copilot / PR caches"
for d in \
    "$PI_HOME/.vscode-server" \
    "$PI_HOME/.vscode-cli" \
    "$PI_HOME/.vscode" \
    "$PI_HOME/.config/Code" \
    "$PI_HOME/.config/Code - Insiders" \
    "$PI_HOME/.config/github-copilot" \
    "$PI_HOME/.cache/vscode-cpptools" \
    "$PI_HOME/.cache/copilot" \
    ; do
    [[ -e "$d" ]] && run "rm -rf '$d'"
done

# -----------------------------------------------------------------------------
banner "3) Remove other .git directories under /var/www"
for d in /var/www/html/.git /var/www/html_backup_*/.git; do
    [[ -d "$d" ]] && run "rm -rf '$d'"
done

# -----------------------------------------------------------------------------
banner "4) Clear shell history"
for f in "$PI_HOME/.bash_history" "$PI_HOME/.python_history" \
         /root/.bash_history /root/.python_history; do
    [[ -e "$f" ]] && run ": > '$f'"
done
run "rm -f '$PI_HOME/.zsh_history' '$PI_HOME/.lesshst' /root/.zsh_history /root/.lesshst"

# -----------------------------------------------------------------------------
banner "5) Remove SSH host keys (regenerated on next boot)"
run "rm -f /etc/ssh/ssh_host_*"
[[ -f /lib/systemd/system/regenerate_ssh_host_keys.service ]] && \
    run "systemctl enable regenerate_ssh_host_keys.service >/dev/null 2>&1 || true"

# -----------------------------------------------------------------------------
banner "6) Truncate system logs"
run "journalctl --rotate >/dev/null 2>&1 || true"
run "journalctl --vacuum-time=1s >/dev/null 2>&1 || true"
if (( ! DRY_RUN )); then
    find /var/log -type f \( -name "*.log" -o -name "*.log.*" \) \
         -exec truncate -s 0 {} \; 2>/dev/null
    find /var/log -type f \( -name "*.gz" -o -name "*.1" \) -delete 2>/dev/null
else
    echo "DRY-RUN: would truncate /var/log/*.log* and delete *.gz / *.1"
fi

# -----------------------------------------------------------------------------
banner "7) Caches (apt/pip/npm) + tmp"
run "apt-get clean -y >/dev/null 2>&1 || true"
run "rm -rf /var/cache/apt/archives/*.deb /var/lib/apt/lists/*"
run "rm -rf '$PI_HOME/.cache/pip' /root/.cache/pip"
run "rm -rf '$PI_HOME/.npm' /root/.npm"
run "rm -rf /tmp/* /var/tmp/*"

# -----------------------------------------------------------------------------
if (( ZERO_FREE )); then
    banner "8) Zero free space"
    if confirm "Really fill the free space with zeros (slow)?"; then
        run "dd if=/dev/zero of=/zero.fill bs=8M status=progress 2>/dev/null || true"
        run "sync"
        run "rm -f /zero.fill"
    fi
fi

# -----------------------------------------------------------------------------
banner "Done"
cat <<EOF
Recommended next steps:
  1) sudo reboot
  2) Verify:    git -C "$PROJECT_DIR" log         # only 1 commit expected
                git -C "$PROJECT_DIR" remote -v   # should be empty
  3) sudo shutdown -h now
  4) dd the SD-card to an .img file
  5) (optional) shrink with pishrink, then gzip / xz
EOF
