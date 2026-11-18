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
rm -rf /run/ccagent
rm -rf /etc/ccagent
# Remove only rules recorded in the installer's ownership manifest. A same-port rule
# created by someone else is never touched. Legacy installs without a manifest fall back
# to the old comment-based match for ufw only.
FW_MARKER=""; FW_UFW=0; FW_FIREDALD=0; FW_NFT=0; FW_IPTABLES=0; FW_IP6=0; HAVE_MANIFEST=0
FW_NFT_FAMILY=inet; FW_NFT_TABLE=filter; FW_NFT_CHAIN=input
if [ -r /etc/ccagent/firewall.json ]; then
  HAVE_MANIFEST=1
  FW_MARKER=$(python3 -c 'import json;print(json.load(open("/etc/ccagent/firewall.json")).get("marker",""))' 2>/dev/null || true)
  FW_UFW=$(python3 -c 'import json;print(int(bool(json.load(open("/etc/ccagent/firewall.json")).get("ufw"))))' 2>/dev/null || echo 0)
  FW_FIREDALD=$(python3 -c 'import json;print(int(bool(json.load(open("/etc/ccagent/firewall.json")).get("firewalld"))))' 2>/dev/null || echo 0)
  FW_NFT=$(python3 -c 'import json;print(int(bool(json.load(open("/etc/ccagent/firewall.json")).get("nft"))))' 2>/dev/null || echo 0)
  FW_NFT_FAMILY=$(python3 -c 'import json;print(json.load(open("/etc/ccagent/firewall.json")).get("nft_family","inet"))' 2>/dev/null || echo inet)
  FW_NFT_TABLE=$(python3 -c 'import json;print(json.load(open("/etc/ccagent/firewall.json")).get("nft_table","filter"))' 2>/dev/null || echo filter)
  FW_NFT_CHAIN=$(python3 -c 'import json;print(json.load(open("/etc/ccagent/firewall.json")).get("nft_chain","input"))' 2>/dev/null || echo input)
  FW_IPTABLES=$(python3 -c 'import json;print(int(bool(json.load(open("/etc/ccagent/firewall.json")).get("iptables"))))' 2>/dev/null || echo 0)
  FW_IP6=$(python3 -c 'import json;print(int(bool(json.load(open("/etc/ccagent/firewall.json")).get("ip6tables"))))' 2>/dev/null || echo 0)
else
  FW_MARKER="ccagent control center"   # legacy ufw comment
  FW_UFW=1
fi
if [ "$FW_UFW" = 1 ] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  while ufw status 2>/dev/null | grep -q "$FW_MARKER"; do
    RULE_NO=$(ufw status numbered 2>/dev/null | grep "$FW_MARKER" | head -n1 | sed -E 's/^\[ *([0-9]+)\].*/\1/')
    [ -n "$RULE_NO" ] || break
    printf 'y\n' | ufw delete "$RULE_NO" >/dev/null 2>&1 || break
  done
fi
if [ "$FW_FIREDALD" = 1 ] && command -v firewall-cmd >/dev/null 2>&1 && [ "$(firewall-cmd --state 2>/dev/null)" = "running" ]; then
  if firewall-cmd --permanent --query-port="${SSH_PORT}/tcp" >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="${SSH_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
fi
if [ "$FW_NFT" = 1 ] && command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
  # Delete by handle so only the marked rule goes, not another port rule.
  HANDLES=$(nft -a list chain "$FW_NFT_FAMILY" "$FW_NFT_TABLE" "$FW_NFT_CHAIN" 2>/dev/null | grep "$FW_MARKER" | sed -E 's/.*handle ([0-9]+).*/\1/')
  for h in $HANDLES; do nft delete rule "$FW_NFT_FAMILY" "$FW_NFT_TABLE" "$FW_NFT_CHAIN" handle "$h" >/dev/null 2>&1 || true; done
elif [ "$HAVE_MANIFEST" = 0 ] && command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
  echo "NOTE: nftables detected on a legacy install. If you added a ccagent rule for port $SSH_PORT, remove it manually:"
  echo "  nft list chain inet filter input   # find 'tcp dport $SSH_PORT accept' and delete by handle"
fi
if [ "$FW_IPTABLES" = 1 ] && command -v iptables >/dev/null 2>&1 && iptables -S INPUT >/dev/null 2>&1; then
  iptables -D INPUT -p tcp --dport "$SSH_PORT" -m comment --comment "$FW_MARKER" -j ACCEPT >/dev/null 2>&1 || true
fi
if [ "$FW_IP6" = 1 ] && command -v ip6tables >/dev/null 2>&1 && ip6tables -S INPUT >/dev/null 2>&1; then
  ip6tables -D INPUT -p tcp --dport "$SSH_PORT" -m comment --comment "$FW_MARKER" -j ACCEPT >/dev/null 2>&1 || true
fi
rm -f /etc/ccagent/firewall.json
systemctl daemon-reload 2>/dev/null || true
rm -rf /opt/ccagent
userdel -r ccagent 2>/dev/null || rm -rf /var/lib/ccagent
echo "ccagent removed."
