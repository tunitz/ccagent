#!/usr/bin/env bash
# Removes the Control Center agent from this unit. Run as root.
set -u
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }
systemctl disable --now ccagent.service 2>/dev/null || true
pkill -f /opt/ccagent/ccagent.sh 2>/dev/null || true
rm -f /etc/systemd/system/ccagent.service /etc/sudoers.d/ccagent /etc/tmpfiles.d/ccagent-rapl.conf /etc/ccagent.conf
systemctl daemon-reload 2>/dev/null || true
rm -rf /opt/ccagent
userdel -r ccagent 2>/dev/null || rm -rf /var/lib/ccagent
echo "ccagent removed."
