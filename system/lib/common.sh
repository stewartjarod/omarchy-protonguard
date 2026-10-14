# Shared settings and helpers for the Proton VPN torrent tunnel scripts.
# Sourced by everything in system/bin. Settings live in /etc/pvpn-torrent/
# torrent.conf (written by install.sh); the defaults below apply when a key is
# missing.

NS="pvpntor"                         # network namespace name
WG_IF="pvpntor0"                     # WireGuard interface inside it
WG_CONF="/etc/pvpn-torrent/wg.conf"  # Proton WireGuard config (root, 0600)
TARGET_USER=""                       # desktop user that runs qBittorrent
FALLBACK_DNS="10.2.0.1"              # Proton's in-tunnel resolver
NATPMP_GATEWAY="10.2.0.1"            # Proton's NAT-PMP gateway
QBT_WEBUI_PORT="8080"                # qBittorrent WebUI, bound inside the namespace
RUN_DIR="/run/pvpn-torrent"          # status + forwarded port, world-readable

# shellcheck disable=SC1091
[[ -r /etc/pvpn-torrent/torrent.conf ]] && . /etc/pvpn-torrent/torrent.conf

if [[ -n "$TARGET_USER" ]]; then
  TARGET_UID=$(id -u "$TARGET_USER" 2>/dev/null || echo "")
fi

# wg_get <file> <section> <key>: first value of key in [section] of a
# wg-quick style config. Case-insensitive section/key, trims whitespace.
wg_get() {
  awk -v want_sec="$(echo "$2" | tr '[:upper:]' '[:lower:]')" -v want_key="$(echo "$3" | tr '[:upper:]' '[:lower:]')" '
    /^[[:space:]]*\[/ { sec = tolower($0); gsub(/[][[:space:]]/, "", sec); next }
    /^[[:space:]]*#/ { next }
    sec == want_sec {
      line = $0
      eq = index(line, "=")
      if (eq == 0) next
      key = tolower(substr(line, 1, eq - 1)); gsub(/[[:space:]]/, "", key)
      if (key != want_key) next
      val = substr(line, eq + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      print val; exit
    }' "$1"
}

# Server tag from the config's comments, e.g. "# US-CO#54" -> US-CO#54.
wg_server_tag() {
  grep -oE '^#[[:space:]]*[A-Z]{2}(-[A-Z0-9]+)*#[0-9]+' "$1" 2>/dev/null | head -1 | sed -E 's/^#[[:space:]]*//'
}

ns_exists() {
  [[ -e "/run/netns/$NS" ]]
}

# --- keep the tunnel's own packets off the killswitch ------------------------
# The tunnel's encrypted socket lives in the root namespace. With a desktop
# killswitch up, `main` has a default route into a dummy interface that beats
# the real gateway, and only the desktop VPN's endpoint is excepted. Without a
# host route of its own, the torrent tunnel's endpoint is swallowed by it.

# physical_uplink: "<gateway> <dev>" of the lowest-metric default route in
# `main` that leaves through a real NIC (not dummy, wireguard, tun, ...).
physical_uplink() {
  local metric gw dev
  while read -r metric gw dev; do
    [[ -e "/sys/class/net/$dev/device" ]] || continue   # virtual devices have no backing device
    echo "$gw $dev"; return 0
  done < <(ip -4 route show default table main | awk '
    { m = 0; gw = ""; dev = ""
      for (i = 1; i < NF; i++) {
        if ($i == "metric") m = $(i + 1)
        if ($i == "via")    gw = $(i + 1)
        if ($i == "dev")    dev = $(i + 1)
      }
      if (gw != "" && dev != "") print m, gw, dev }' | sort -n)
  return 1
}

# sync_endpoint_route: make sure the endpoint in $WG_CONF is reachable through
# the real uplink, and record the route we installed so down can remove it.
# Idempotent; safe to call every few seconds. Never fails the caller.
sync_endpoint_route() {
  local endpoint ep spec uplink gw dev
  endpoint=$(wg_get "$WG_CONF" peer Endpoint 2>/dev/null)
  ep=${endpoint%:*}
  [[ "$ep" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0   # IPv4 literals only
  uplink=$(physical_uplink) || return 0
  read -r gw dev <<< "$uplink"
  spec="$ep/32 via $gw dev $dev"
  [[ "$(cat "$RUN_DIR/endpoint-route" 2>/dev/null)" == "$spec" ]] \
    && ip route show "$ep/32" 2>/dev/null | grep -q . && return 0
  # A different endpoint than last time: drop the old route first.
  drop_endpoint_route
  # Leave a route something else (the desktop VPN) already put there alone.
  ip route show exact "$ep/32" table main 2>/dev/null | grep -q . && return 0
  # shellcheck disable=SC2086
  if ip route replace $spec metric 100 2>/dev/null; then
    install -d -m 755 "$RUN_DIR"
    printf '%s\n' "$spec" > "$RUN_DIR/endpoint-route"
    echo "[pvpn-torrent] endpoint route: $spec"
  fi
  return 0
}

drop_endpoint_route() {
  local spec
  spec=$(cat "$RUN_DIR/endpoint-route" 2>/dev/null) || return 0
  # shellcheck disable=SC2086
  ip route del $spec 2>/dev/null || true
  rm -f "$RUN_DIR/endpoint-route"
}
