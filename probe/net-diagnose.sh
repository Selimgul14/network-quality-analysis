#!/usr/bin/env bash
# Pre-flight network check for the probe host.
#
# Run on the Pi after joining a new WiFi network:
#   ./net-diagnose.sh [peer-ip]
# where peer-ip is the wired reference host (the Mac). Peer is optional.
#
# Everything is written to a log as well as stdout, so the result survives
# losing the SSH session (read it later from the comitup hotspot).

set -u
IFACE=${IFACE:-wlan0}
PEER=${1:-}
LOG=${LOG:-/opt/probe/net-diagnose.log}
exec > >(tee -a "$LOG") 2>&1

say() { printf '\n=== %s ===\n' "$1"; }
ok()  { printf '  [ok]   %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; }
note(){ printf '  ...    %s\n' "$1"; }

printf '\n########## %s ##########\n' "$(date -Is)"

say "WiFi link"
iw dev "$IFACE" link 2>/dev/null || note "iw unavailable"

say "Addressing"
ip -br addr show "$IFACE"
ip route
GW=$(ip route | awk '/^default/ {print $3; exit}')
MYIP=$(ip -4 -br addr show "$IFACE" | awk '{print $3}' | cut -d/ -f1)
note "gateway=${GW:-none} ip=${MYIP:-none}"

say "DNS"
if getent hosts example.com >/dev/null 2>&1; then ok "DNS resolves"; else bad "DNS resolution failed"; fi

say "Captive portal / internet reachability"
# 204 = clean internet. 200/3xx = something intercepted us (portal).
CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 6 http://connectivitycheck.gstatic.com/generate_204 || echo 000)
case "$CODE" in
  204) ok  "no portal, internet is open (HTTP 204)" ;;
  000) bad "no HTTP response at all (no route, or all traffic dropped)" ;;
  *)   bad "CAPTIVE PORTAL LIKELY (HTTP $CODE)"
       LOC=$(curl -sI -m 6 http://connectivitycheck.gstatic.com/generate_204 | awk -F': ' 'tolower($1)=="location"{print $2}')
       note "portal URL: ${LOC:-<not advertised, portal probably intercepts transparently>}" ;;
esac
# HTTPS works even behind some portals; useful to know which side is blocked.
if curl -s -o /dev/null -m 6 https://www.google.com; then ok "HTTPS egress works"; else bad "HTTPS egress blocked"; fi

say "ICMP (baseline/path workloads need this)"
if ping -c 2 -W 2 "${GW:-127.0.0.1}" >/dev/null 2>&1; then ok "gateway answers ping"; else bad "gateway does not answer ping"; fi
if ping -c 2 -W 2 1.1.1.1 >/dev/null 2>&1; then ok "ICMP to internet works"; else bad "ICMP blocked (baseline/path will show no data)"; fi

say "Client isolation"
if [ -n "$MYIP" ]; then
  SUBNET=${MYIP%.*}
  note "sweeping ${SUBNET}.0/24 for other visible hosts (a few seconds)"
  for i in $(seq 1 254); do ping -c1 -W1 "${SUBNET}.$i" >/dev/null 2>&1 & done
  wait
  # Neighbours we actually resolved a MAC for = hosts we can really talk to.
  SEEN=$(ip neigh show dev "$IFACE" | grep -cE 'REACHABLE|STALE|DELAY')
  note "hosts visible on the LAN: $SEEN"
  if [ "$SEEN" -le 1 ]; then
    bad "only the gateway is visible -> client isolation is ON"
    note "the local (WiFi-link) leg will not work over wireless-to-wireless"
  else
    ok "other hosts are visible -> no strict client isolation"
  fi
fi

say "Reference host reachability"
if [ -z "$PEER" ]; then
  note "no peer IP given; re-run as: $0 <mac-lan-ip>"
else
  if ping -c 2 -W 2 "$PEER" >/dev/null 2>&1; then ok "peer $PEER answers ping"; else bad "peer $PEER does not answer ping"; fi
  for p in 8080 5201; do
    if timeout 3 bash -c "echo > /dev/tcp/$PEER/$p" 2>/dev/null; then
      ok "peer TCP $p open ($([ "$p" = 8080 ] && echo 'nginx reference' || echo 'iperf3'))"
    else
      bad "peer TCP $p closed/filtered"
    fi
  done
fi

say "Verdict"
note "portal check=$CODE; see [FAIL] lines above for what blocks the probe"
note "log: $LOG"
