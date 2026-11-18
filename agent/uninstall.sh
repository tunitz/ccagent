#!/usr/bin/env bash
# Removes the Control Center agent from this unit. Run as root.
set -u
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }
# The dedicated SSH port is recorded by the installer; fall back to the default for older installs.
SSH_PORT=62478
if [ -r /etc/ccagent.conf ]; then
  . /etc/ccagent.conf 2>/dev/null || true
fi
case "$SSH_PORT" in ''|*[!0-9]*) SSH_PORT=62478;; esac
systemctl disable --now ccagent-sshd.service 2>/dev/null || true
systemctl disable --now ccagent.service 2>/dev/null || true
pkill -f /opt/ccagent/ccagent.sh 2>/dev/null || true
systemctl disable --now ccagent-power.path 2>/dev/null || true
systemctl disable --now ccagent-svc.path 2>/dev/null || true
rm -f /etc/systemd/system/ccagent-sshd.service /etc/ssh/ccagent_sshd_config /etc/systemd/system/ccagent-power.path /etc/systemd/system/ccagent-power.service /etc/systemd/system/ccagent-svc.path /etc/systemd/system/ccagent-svc.service /etc/systemd/system/ccagent.service /etc/sudoers.d/ccagent /etc/tmpfiles.d/ccagent-rapl.conf /etc/ccagent.conf
rm -rf /etc/ccagent
# Remove only rules we can positively identify as ours; leave the system sshd/port 22 alone.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  while ufw status 2>/dev/null | grep -q 'ccagent control center'; do
    RULE_NO=$(ufw status numbered 2>/dev/null | grep 'ccagent control center' | head -n1 | sed -E 's/^\[ *([0-9]+)\].*/\1/')
    [ -n "$RULE_NO" ] || break
    printf 'y\n' | ufw delete "$RULE_NO" >/dev/null 2>&1 || break
  done
fi
if command -v firewall-cmd >/dev/null 2>&1 && [ "$(firewall-cmd --state 2>/dev/null)" = "running" ]; then
  if firewall-cmd --permanent --query-port="${SSH_PORT}/tcp" >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="${SSH_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
fi
if command -v iptables >/dev/null 2>&1 && iptables -S INPUT >/dev/null 2>&1; then
  iptables -D INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT >/dev/null 2>&1 || true
fi
if command -v ip6tables >/dev/null 2>&1 && ip6tables -S INPUT >/dev/null 2>&1; then
  ip6tables -D INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT >/dev/null 2>&1 || true
fi
if command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
  echo "NOTE: nftables detected. If you added a ccagent rule for port $SSH_PORT, remove it manually:"
  echo "  nft list chain inet filter input   # find 'tcp dport $SSH_PORT accept' and delete by handle"
fi
systemctl daemon-reload 2>/dev/null || true
rm -rf /opt/ccagent
userdel -r ccagent 2>/dev/null || rm -rf /var/lib/ccagent
echo "ccagent removed."
