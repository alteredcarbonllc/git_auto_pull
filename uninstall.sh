#!/bin/sh
set -eu
[ "$(id -u)" -eq 0 ] || { echo 'Run as root' >&2; exit 1; }
purge=false
case "${1:-}" in '') [ "$#" -eq 0 ] || exit 1;; --purge|--all) [ "$#" -eq 1 ] || exit 1; purge=true;; *) echo 'Usage: uninstall.sh [--purge]' >&2; exit 1;; esac
systemctl disable --now git_auto_pull.timer 2>/dev/null || true
if systemctl is-active --quiet git_auto_pull.service || pgrep -f '^(/bin/bash|/usr/bin/bash|/usr/bin/python3) (/usr/bin|/usr/local/bin)/git_auto_pull\.(sh|py)( |$)' >/dev/null; then
    echo 'Updater still running; wait before uninstalling' >&2
    exit 1
fi
backup=$(mktemp -d /var/backups/git_auto_pull-uninstall.XXXXXX)
chmod 0700 "$backup"
for file in /usr/bin/git_auto_pull.sh /usr/local/bin/git_auto_pull.sh /usr/local/bin/git_auto_pull.py /etc/cron.d/git_auto_pull /etc/systemd/system/git_auto_pull.service /etc/systemd/system/git_auto_pull.timer; do
    if [ -e "$file" ] || [ -L "$file" ]; then
        cp -a --parents "$file" "$backup/"
        rm -f -- "$file"
    fi
done
if "$purge"; then
    if [ -e /etc/git_auto_pull.conf ] || [ -L /etc/git_auto_pull.conf ]; then
        cp -a --parents /etc/git_auto_pull.conf "$backup/"
        rm -f /etc/git_auto_pull.conf
    fi
fi
systemctl daemon-reload
systemctl reset-failed git_auto_pull.service 2>/dev/null || true
echo "UNINSTALLED: git_auto_pull; backup=$backup"
