#!/usr/bin/env bash
# Fault injection for build step 7: break the network in a known way and
# check the tool blames the right segment.
#
#   sudo ./inject.sh list                 show the scenarios
#   sudo ./inject.sh fast                 60 s heavy cadence, for the test window
#   sudo ./inject.sh matrix               run all 8 unattended (~2h15)
#   sudo ./inject.sh run 05               apply scenario 05 and label the data
#   sudo ./inject.sh clear                remove all impairment, restore the label
#   sudo ./inject.sh status               what is currently applied
#   sudo ./inject.sh normal               restore production cadence
#
# Every scenario arms a watchdog that clears the impairment after
# WATCHDOG_MIN minutes, so a mistake cannot leave the link broken (which
# matters: scenario 07 cuts off-site traffic entirely, including SSH).
#
# Records are labelled with a per-scenario PROBE_SITE, so the production
# `true student` dataset stays clean and each scenario is queryable on its
# own afterwards. analyse.py reads the log this writes.
set -euo pipefail

IFACE=${IFACE:-wlan0}
ENV_FILE=${ENV_FILE:-/opt/probe/.env}
LOG=${LOG:-/opt/probe/faultinj-log.tsv}
WATCHDOG_MIN=${WATCHDOG_MIN:-25}
WATCHDOG_PID=/run/faultinj-watchdog.pid

[[ $EUID -eq 0 ]] || { echo "run me with sudo (tc needs root)"; exit 1; }

gateway() { ip route show default | awk '/via/ {print $3; exit}'; }

# Real-world targets, resolved at injection time. Scenario 06 impairs only
# these, leaving the cloud reference untouched, which is what separates
# "the service is slow" from "the path is slow".
real_hosts() {
  awk -F= '/^PROBE_REAL_(WEB|VIDEO|DOWNLOAD|IMAP_HOST)=/ {print $2}' "$ENV_FILE" \
    | tr -d '"' | sed -E 's#^https?://##; s#/.*##' | grep -v '^$' | sort -u
}

resolve_all() {
  local host ip
  for host in $(real_hosts); do
    for ip in $(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u); do
      echo "$ip"
    done
  done | sort -u
}

# --- impairment primitives ---------------------------------------------------

clear_tc() {
  tc qdisc del dev "$IFACE" root 2>/dev/null || true
  tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
  tc qdisc del dev ifb0 root 2>/dev/null || true
  ip link set ifb0 down 2>/dev/null || true
  ip link del ifb0 2>/dev/null || true
}

# netem applied to everything leaving the interface
all_egress() { tc qdisc add dev "$IFACE" root netem "$@"; }

# netem applied to everything EXCEPT the listed destinations. Band 1 is
# unimpaired and matched first, so the gateway keeps answering while the
# rest of the world degrades: that is what makes the WiFi link provably
# healthy during an internet-path fault.
except_dests() {
  local exempt=("$@")
  tc qdisc add dev "$IFACE" root handle 1: prio bands 3
  tc qdisc add dev "$IFACE" parent 1:3 handle 30: netem ${NETEM:?}
  local d
  for d in "${exempt[@]}"; do
    tc filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 \
      match ip dst "$d"/32 flowid 1:1
  done
  tc filter add dev "$IFACE" protocol ip parent 1: prio 2 u32 \
    match u32 0 0 flowid 1:3
}

# netem applied ONLY to the listed destinations
only_dests() {
  tc qdisc add dev "$IFACE" root handle 1: prio bands 3
  tc qdisc add dev "$IFACE" parent 1:3 handle 30: netem ${NETEM:?}
  local d
  for d in "$@"; do
    tc filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 \
      match ip dst "$d"/32 flowid 1:3
  done
}

# Inbound shaping needs a virtual device: tc only shapes egress, and a
# download is inbound. Traffic is mirrored to ifb0 and shaped there.
ingress_shape() {  # rate, latency
  modprobe ifb numifbs=1 2>/dev/null || true
  ip link add ifb0 type ifb 2>/dev/null || true
  ip link set ifb0 up
  tc qdisc add dev "$IFACE" handle ffff: ingress
  tc filter add dev "$IFACE" parent ffff: protocol ip u32 match u32 0 0 \
    action mirred egress redirect dev ifb0
  tc qdisc add dev ifb0 root tbf rate "$1" burst 32kbit latency "$2"
}

# --- probe plumbing ----------------------------------------------------------

set_env() {  # key value
  if grep -q "^$1=" "$ENV_FILE"; then
    sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"
  else
    echo "$1=$2" >> "$ENV_FILE"
  fi
}

restart_probe() { systemctl restart probe; sleep 2; }

arm_watchdog() {
  [[ -f $WATCHDOG_PID ]] && kill "$(cat $WATCHDOG_PID)" 2>/dev/null || true
  nohup bash -c "sleep $((WATCHDOG_MIN * 60)); $0 clear" >/dev/null 2>&1 &
  echo $! > "$WATCHDOG_PID"
  echo "watchdog armed: auto-clear in ${WATCHDOG_MIN} min"
}

log_event() {  # scenario site event
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" "$3" >> "$LOG"
}

# --- scenarios ---------------------------------------------------------------

declare -A DESC=(
  [01]="control, no impairment"
  [02]="WiFi link: +80 ms delay on everything"
  [03]="WiFi link: 5% packet loss on everything"
  [04]="WiFi link: throttled to 5 Mbit inbound"
  [05]="Internet path: +150 ms to everything except the gateway"
  [06]="Third party: +400 ms to the real services only"
  [07]="Total uplink loss: everything except the gateway dropped"
  [08]="Bufferbloat: 20 Mbit inbound with a 500 ms queue"
)

apply() {
  local s=$1 gw
  gw=$(gateway)
  [[ -n $gw ]] || { echo "no default gateway found"; exit 1; }
  case "$s" in
    01) : ;;                                            # control
    02) all_egress delay 80ms ;;
    03) all_egress loss 5% ;;
    04) ingress_shape 5mbit 400ms ;;
    05) NETEM="delay 150ms" except_dests "$gw" ;;
    06) local ips; mapfile -t ips < <(resolve_all)
        [[ ${#ips[@]} -gt 0 ]] || { echo "could not resolve the real targets"; exit 1; }
        echo "impairing ${#ips[@]} real-service addresses"
        NETEM="delay 400ms" only_dests "${ips[@]}" ;;
    07) NETEM="loss 100%" except_dests "$gw" ;;
    08) ingress_shape 20mbit 500ms ;;
    *)  echo "unknown scenario: $s"; exit 1 ;;
  esac
}

# --- commands ----------------------------------------------------------------

case "${1:-}" in
  list)
    for s in $(echo "${!DESC[@]}" | tr ' ' '\n' | sort); do
      printf '  %s  %s\n' "$s" "${DESC[$s]}"
    done ;;

  run)
    scenario=${2:?usage: inject.sh run <NN>}
    [[ -n ${DESC[$scenario]:-} ]] || { echo "unknown scenario"; exit 1; }
    site="faultinj-$scenario"
    clear_tc
    apply "$scenario"
    set_env PROBE_SITE "$site"
    restart_probe
    arm_watchdog
    log_event "$scenario" "$site" start
    echo "scenario $scenario applied: ${DESC[$scenario]}"
    echo "records are landing under site '$site'"
    echo
    # Prove the impairment is real before waiting 15 minutes for medians.
    # Scenario 05 and 07 are the interesting ones: the gateway must stay
    # healthy while the anchor degrades or dies.
    gw=$(gateway)
    echo "--- verification ---"
    echo -n "gateway $gw : "; ping -c 3 -W 3 -q "$gw" 2>/dev/null \
      | awk -F'/' '/rtt|round-trip/ {printf "%s ms avg", $5} /packet loss/ {printf " "}' \
      || echo -n "no reply"
    ping -c 3 -W 3 -q "$gw" 2>/dev/null | awk '/packet loss/ {print ", " $6 " loss"}'
    echo -n "anchor 1.1.1.1 : "; ping -c 3 -W 3 -q 1.1.1.1 2>/dev/null \
      | awk -F'/' '/rtt|round-trip/ {printf "%s ms avg", $5}'
    ping -c 3 -W 3 -q 1.1.1.1 2>/dev/null | awk '/packet loss/ {print ", " $6 " loss"}' \
      || echo "unreachable"
    echo "-------------------"
    echo "leave it running ~15 min, then: sudo $0 clear" ;;

  matrix)
    mins=${2:-15}
    echo "running all 8 scenarios at ${mins} min each: about $(( (mins + 2) * 8 / 60 ))h$(( (mins + 2) * 8 % 60 ))m"
    echo "safe to walk away; every scenario clears itself and the watchdog backs it up"
    # Clear up if this is interrupted, so a fault is never left applied.
    trap 'echo; echo "interrupted, clearing"; "$0" clear; "$0" normal; exit 130' INT TERM
    "$0" fast
    for s in 01 02 03 04 05 06 07 08; do
      echo; echo "=============== scenario $s ==============="
      if ! "$0" run "$s"; then
        echo "scenario $s could not be applied, skipping"
        "$0" clear; continue
      fi
      sleep $((mins * 60))
      "$0" clear
      sleep 120                      # let the probe settle before the next one
    done
    "$0" normal
    echo; echo "matrix complete. Now score it:"
    echo "  python3 analyse.py --password <dashboard-pw> --markdown" ;;

  clear)
    clear_tc
    set_env PROBE_SITE ""          # empty falls back to the SSID
    restart_probe
    [[ -f $WATCHDOG_PID ]] && kill "$(cat $WATCHDOG_PID)" 2>/dev/null || true
    rm -f "$WATCHDOG_PID"
    log_event - - clear
    echo "impairment cleared, site label restored" ;;

  fast)
    set_env PROBE_HEAVY_INTERVAL_S 60
    set_env PROBE_TRANSFER_INTERVAL_S 300
    restart_probe
    echo "test cadence: heavy 60 s, transfers 5 min" ;;

  normal)
    set_env PROBE_HEAVY_INTERVAL_S 300
    set_env PROBE_TRANSFER_INTERVAL_S 3600
    restart_probe
    echo "production cadence restored" ;;

  status)
    echo "--- $IFACE qdisc ---"; tc qdisc show dev "$IFACE"
    echo "--- filters ---";      tc filter show dev "$IFACE" 2>/dev/null | head
    echo "--- ifb0 ---";         tc qdisc show dev ifb0 2>/dev/null || echo "(none)"
    echo "--- probe env ---"
    grep -E '^PROBE_(SITE|HEAVY_INTERVAL_S|TRANSFER_INTERVAL_S)=' "$ENV_FILE" || true
    echo "--- gateway ---";      gateway ;;

  *)
    sed -n '2,20p' "$0"; exit 1 ;;
esac
