#!/bin/sh
set -eu
[ "$(id -u)" -eq 0 ] || { echo 'Run as root' >&2; exit 1; }
[ "$#" -eq 0 ] || { echo 'Usage: install.sh (no automatic activation)' >&2; exit 1; }
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
/usr/bin/python3 - "$base/git_auto_pull.py" <<'CHECK'
import ast, pathlib, sys
ast.parse(pathlib.Path(sys.argv[1]).read_text())
CHECK
# This installer is for a retired tool, never for use during an active job.
if systemctl is-active --quiet git_auto_pull.service; then
    echo 'Stop the active updater before installing' >&2
    exit 1
fi
systemctl disable --now git_auto_pull.timer 2>/dev/null || true
backup=$(mktemp -d /var/backups/git_auto_pull-install.XXXXXX)
chmod 0700 "$backup"
for file in /usr/local/bin/git_auto_pull.sh /usr/local/bin/git_auto_pull.py /etc/systemd/system/git_auto_pull.service /etc/systemd/system/git_auto_pull.timer /etc/cron.d/git_auto_pull; do
    if [ -e "$file" ] || [ -L "$file" ]; then cp -a --parents "$file" "$backup/"; fi
done
install -d -m 0755 /usr/local/bin /etc/systemd/system
install -m 0755 -o root -g root "$base/git_auto_pull.sh" /usr/local/bin/git_auto_pull.sh
install -m 0644 -o root -g root "$base/git_auto_pull.py" /usr/local/bin/git_auto_pull.py
install -m 0644 -o root -g root "$base/git_auto_pull.service" /etc/systemd/system/git_auto_pull.service
install -m 0644 -o root -g root "$base/git_auto_pull.timer" /etc/systemd/system/git_auto_pull.timer
if [ ! -e /etc/git_auto_pull.conf ] && [ ! -L /etc/git_auto_pull.conf ]; then
    install -m 0600 -o root -g root "$base/git_auto_pull.conf.example" /etc/git_auto_pull.conf
fi
rm -f /etc/cron.d/git_auto_pull
systemctl daemon-reload
echo "INSTALLED_DISABLED: git_auto_pull; backup=$backup"
