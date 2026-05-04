#!/bin/sh
#
# edge-doctor.sh — end-to-end health check for the UNAL-Thread / TB Edge
# deployment running on a Seeed reComputer R1000 + Wio-WM6108 + Nordic
# nRF52840 RCP. Designed for OpenWrt 23.05.x (busybox).
#
# Layers checked, in order:
#   L0  System         — uptime, load, memory, disk
#   L1  RCP / dongle   — USB device + ttyACM4 present
#   L2  otbr-agent     — process alive, mesh state, BR running
#   L3  Thread mesh    — children count, MAC counters delta
#   L4  Address guard  — preferred_lft forever on OMR + mleid
#   L5  Firewall       — wpan0 zone present in fw4 chain input
#   L6  SRP            — TB Edge service published with OMR address
#   L7  TB Edge        — container Up, Leshan listening :5683, JVM healthy
#   L8  LwM2M fleet    — bucket distribution from postgres ts_kv
#   L9  Cloud uplink   — gRPC to TB Central state
#   L10 Object 33000   — Read RPC sample of last_error_code on active nodes
#
# Usage:
#   edge-doctor.sh            # human-friendly text output
#   edge-doctor.sh --quiet    # only print failures (CI-friendly)
#   edge-doctor.sh --json     # one-line JSON summary (for cron / Prometheus)
#
# Exit codes:
#   0  — all checks pass (HEALTHY)
#   1  — at least one CRITICAL check failed (DOWN)
#   2  — at least one WARNING (DEGRADED)
#
# Reference: docs/runbooks/thread-mesh-health.md
#            docs/decisions/firmware-fixes-validation.md

set -u

MODE="text"
case "${1:-}" in
  --quiet) MODE="quiet" ;;
  --json)  MODE="json"  ;;
  --help|-h)
    sed -n '2,30p' "$0"
    exit 0
    ;;
esac

# ---- knobs (override via env) ------------------------------------------------
TB_HOST="${TB_HOST:-192.168.1.175}"
TB_PORT="${TB_PORT:-8090}"
TB_USER="${TB_USER:-tenant@thingsboard.org}"
TB_PASS="${TB_PASS:-tenant}"
EXPECTED_DEVICE_TYPE="${EXPECTED_DEVICE_TYPE:-AMI_LwM2M_Node}"
DISK_WARN_PCT="${DISK_WARN_PCT:-95}"  # warn when overlay used > 95%
DISK_CRIT_PCT="${DISK_CRIT_PCT:-98}"
MEM_AVAIL_WARN_KB="${MEM_AVAIL_WARN_KB:-100000}"  # warn if available < 100MB
LOAD_WARN="${LOAD_WARN:-3.0}"
MAC_SAMPLE_S="${MAC_SAMPLE_S:-30}"
TELEM_FRESH_SEC="${TELEM_FRESH_SEC:-300}"  # device alive if last_telem < 300s

# ---- accumulators ------------------------------------------------------------
PASS=0
WARN=0
FAIL=0
LAYERS_FAILED=""
LAYERS_WARNED=""

# ---- output helpers ---------------------------------------------------------
# Color codes only when stdout is a tty
if [ -t 1 ] && [ "$MODE" = "text" ]; then
  C_OK="\033[32m"
  C_WARN="\033[33m"
  C_FAIL="\033[31m"
  C_DIM="\033[2m"
  C_RST="\033[0m"
else
  C_OK="" C_WARN="" C_FAIL="" C_DIM="" C_RST=""
fi

emit_section() {
  [ "$MODE" = "text" ] && printf "\n${C_DIM}=== %s ===${C_RST}\n" "$1"
}

emit_ok() {
  PASS=$((PASS + 1))
  [ "$MODE" = "text" ] && printf "  ${C_OK}✓${C_RST} %s\n" "$1"
}

emit_warn() {
  WARN=$((WARN + 1))
  LAYERS_WARNED="$LAYERS_WARNED $2"
  [ "$MODE" != "json" ] && printf "  ${C_WARN}⚠${C_RST} %s\n" "$1"
}

emit_fail() {
  FAIL=$((FAIL + 1))
  LAYERS_FAILED="$LAYERS_FAILED $2"
  [ "$MODE" != "json" ] && printf "  ${C_FAIL}✗${C_RST} %s\n" "$1"
}

# Read the Nth field from a label, e.g. "TxAcked: 37" -> 37
ot_field() {
  echo "$1" | awk -v p="$2" '$0 ~ p {print $NF; exit}'
}

# ---- L0 System ---------------------------------------------------------------
emit_section "L0 System"

UPTIME_OUT=$(uptime 2>/dev/null || echo "")
LOAD1=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
if [ -n "$LOAD1" ]; then
  if [ -n "$UPTIME_OUT" ]; then
    emit_ok "uptime: ${UPTIME_OUT##* up }, load_1=$LOAD1"
  else
    emit_ok "load_1=$LOAD1"
  fi
else
  emit_warn "could not read /proc/loadavg" L0
fi

MEM_AVAIL=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
MEM_TOTAL=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
if [ -n "$MEM_AVAIL" ] && [ -n "$MEM_TOTAL" ]; then
  MEM_PCT=$((100 - (MEM_AVAIL * 100) / MEM_TOTAL))
  if [ "$MEM_AVAIL" -lt "$MEM_AVAIL_WARN_KB" ]; then
    emit_warn "memory tight: ${MEM_AVAIL}KB available (used ${MEM_PCT}%)" L0
  else
    emit_ok "memory: ${MEM_AVAIL}KB available (used ${MEM_PCT}%)"
  fi
fi

# Disk on /overlay (the writable rootfs on OpenWrt)
DISK_LINE=$(df 2>/dev/null | awk '$NF=="/overlay" || $NF=="/"' | head -1)
DISK_PCT=$(echo "$DISK_LINE" | awk '{print $5}' | tr -d '%')
DISK_AVAIL_KB=$(echo "$DISK_LINE" | awk '{print $4}')
if [ -n "$DISK_PCT" ]; then
  if [ "$DISK_PCT" -ge "$DISK_CRIT_PCT" ]; then
    emit_fail "disk CRITICAL: ${DISK_PCT}% used, ${DISK_AVAIL_KB}KB free (threshold ${DISK_CRIT_PCT}%)" L0
  elif [ "$DISK_PCT" -ge "$DISK_WARN_PCT" ]; then
    emit_warn "disk tight: ${DISK_PCT}% used, ${DISK_AVAIL_KB}KB free (threshold ${DISK_WARN_PCT}%)" L0
  else
    emit_ok "disk: ${DISK_PCT}% used, ${DISK_AVAIL_KB}KB free"
  fi
fi

# Load average warning
LOAD_INT=$(echo "$LOAD1" | awk -F. '{print $1}')
if [ -n "$LOAD_INT" ] && [ "$LOAD_INT" -ge "${LOAD_WARN%.*}" ]; then
  emit_warn "load_1 high: $LOAD1 (threshold $LOAD_WARN)" L0
fi

# ---- L1 RCP dongle -----------------------------------------------------------
emit_section "L1 RCP / dongle"

if lsusb 2>/dev/null | grep -q "1915:cafe"; then
  emit_ok "Nordic nRF52840 dongle detected (1915:cafe)"
else
  if lsusb 2>/dev/null | grep -q "10c4:ea60"; then
    emit_warn "Sonoff CP210x detected (1915:cafe NOT found) — Sonoff has known stability issues" L1
  else
    emit_fail "no known OT RCP USB device found" L1
  fi
fi

UART_DEV=$(uci -q get otbr-agent.service.uart_device 2>/dev/null)
if [ -n "$UART_DEV" ] && [ -c "$UART_DEV" ]; then
  emit_ok "UART device $UART_DEV present"
else
  emit_fail "UART device $UART_DEV missing or unreadable" L1
fi

# ---- L2 otbr-agent -----------------------------------------------------------
emit_section "L2 otbr-agent"

OTBR_PID=$(pgrep -f "/usr/sbin/otbr-agent" 2>/dev/null | head -1)
if [ -n "$OTBR_PID" ]; then
  emit_ok "otbr-agent running (pid $OTBR_PID)"
  STATE=$(ot-ctl state 2>/dev/null | head -1 | tr -d '\r')
  case "$STATE" in
    leader|router) emit_ok "Thread state: $STATE" ;;
    child)         emit_warn "Thread state: $STATE (expected leader on the BR)" L2 ;;
    detached)      emit_warn "Thread state: detached (mesh forming)" L2 ;;
    disabled|"")   emit_fail "Thread state: $STATE — daemon not responding" L2 ;;
    *)             emit_warn "Thread state: $STATE" L2 ;;
  esac

  BR_STATE=$(ot-ctl br state 2>/dev/null | head -1 | tr -d '\r')
  if [ "$BR_STATE" = "running" ]; then
    emit_ok "Border Router: running"
  else
    emit_fail "Border Router: $BR_STATE (expected running)" L2
  fi
else
  emit_fail "otbr-agent NOT running" L2
fi

# ---- L3 Thread mesh + MAC ---------------------------------------------------
emit_section "L3 Thread mesh"

if [ -n "$OTBR_PID" ]; then
  CHILD_COUNT=$(ot-ctl child table 2>/dev/null | grep -c '^|.*0x')
  if [ "$CHILD_COUNT" -gt 0 ]; then
    emit_ok "children attached: $CHILD_COUNT"
  else
    emit_warn "0 children attached" L3
  fi

  # Sample MAC counters over $MAC_SAMPLE_S seconds
  ot-ctl counters mac reset >/dev/null 2>&1
  [ "$MODE" = "text" ] && printf "  ${C_DIM}sampling MAC for ${MAC_SAMPLE_S}s...${C_RST}\n"
  sleep "$MAC_SAMPLE_S"
  MAC=$(ot-ctl counters mac 2>/dev/null)

  TX_REQ=$(ot_field "$MAC" "TxAckRequested:")
  TX_ACK=$(ot_field "$MAC" "TxAcked:")
  TX_RETRY=$(ot_field "$MAC" "TxRetry:")
  TX_CCA=$(ot_field "$MAC" "TxErrCca:")
  TX_BUSY=$(ot_field "$MAC" "TxErrBusyChannel:")
  TX_ABORT=$(ot_field "$MAC" "TxErrAbort:")
  TX_EXPIRY=$(ot_field "$MAC" "TxDirectMaxRetryExpiry:")

  TX_REQ=${TX_REQ:-0}
  TX_ACK=${TX_ACK:-0}
  TX_RETRY=${TX_RETRY:-0}
  TX_EXPIRY=${TX_EXPIRY:-0}

  if [ "$TX_REQ" -gt 0 ]; then
    ACK_PCT=$((TX_ACK * 100 / TX_REQ))
    if [ "$ACK_PCT" -ge 99 ]; then
      emit_ok "MAC ACK rate: ${ACK_PCT}% (${TX_ACK}/${TX_REQ})"
    elif [ "$ACK_PCT" -ge 95 ]; then
      emit_warn "MAC ACK rate: ${ACK_PCT}% (${TX_ACK}/${TX_REQ}) — degraded" L3
    else
      emit_fail "MAC ACK rate: ${ACK_PCT}% (${TX_ACK}/${TX_REQ}) — congestion" L3
    fi
  fi

  if [ "$TX_RETRY" -gt 0 ]; then
    emit_warn "TxRetry: $TX_RETRY (expected 0)" L3
  else
    emit_ok "TxRetry: 0"
  fi
  if [ "$TX_EXPIRY" -gt 0 ]; then
    emit_warn "TxDirectMaxRetryExpiry: $TX_EXPIRY (lost packets)" L3
  else
    emit_ok "TxDirectMaxRetryExpiry: 0"
  fi
  [ "${TX_CCA:-0}" -gt 0 ] && emit_warn "TxErrCca: $TX_CCA (channel contention)" L3
  [ "${TX_BUSY:-0}" -gt 0 ] && emit_warn "TxErrBusyChannel: $TX_BUSY" L3
  [ "${TX_ABORT:-0}" -gt 0 ] && emit_warn "TxErrAbort: $TX_ABORT" L3
fi

# ---- L4 Address guard --------------------------------------------------------
emit_section "L4 Address lifetime guard"

if pgrep -f "otbr-addr-lifetime-guard" >/dev/null 2>&1; then
  emit_ok "otbr-addr-lifetime-guard running"
else
  emit_warn "otbr-addr-lifetime-guard NOT running (using cron fallback?)" L4
fi

# OMR + mleid should both have preferred_lft forever
if [ -n "$OTBR_PID" ]; then
  WPAN_ADDRS=$(ip -6 addr show wpan0 2>/dev/null)
  N_FOREVER=$(echo "$WPAN_ADDRS" | grep -c "preferred_lft forever")
  N_DEPRECATED=$(echo "$WPAN_ADDRS" | grep -c "deprecated")
  if [ "$N_FOREVER" -ge 2 ]; then
    emit_ok "$N_FOREVER addresses on wpan0 with preferred_lft forever"
  else
    emit_warn "only $N_FOREVER addresses pinned (expected ≥2: OMR + mleid)" L4
  fi
fi

# ---- L5 Firewall -------------------------------------------------------------
emit_section "L5 Firewall"

if nft list chain inet fw4 input 2>/dev/null | grep -q 'iifname "wpan0".*input_thread'; then
  emit_ok "fw4 input chain has wpan0 → input_thread jump"
else
  emit_fail "fw4 input chain MISSING wpan0 zone — kernel will drop mesh UDP" L5
fi

# ---- L6 SRP ------------------------------------------------------------------
emit_section "L6 SRP service"

if [ -n "$OTBR_PID" ]; then
  SRP_OUT=$(ot-ctl srp server service 2>/dev/null)
  if echo "$SRP_OUT" | grep -q "ThingsBoard-Edge"; then
    # The service listing may have multiple subservices (_coap, _lwm2m). Look
    # for any address line in the whole block.
    SRP_ADDR=$(echo "$SRP_OUT" | grep -oE "fd[0-9a-f:]+" | head -1)
    if [ -n "$SRP_ADDR" ]; then
      emit_ok "SRP publishing TB Edge at [$SRP_ADDR]:5683"
    else
      emit_warn "SRP service listed but address parse failed" L6
    fi
  else
    emit_fail "SRP NOT publishing ThingsBoard-Edge service" L6
  fi
fi

# ---- L7 TB Edge --------------------------------------------------------------
emit_section "L7 TB Edge"

TB_STATUS=$(docker ps --filter "name=tb-edge-v2" --format "{{.Status}}" 2>/dev/null)
PG_STATUS=$(docker ps --filter "name=tb-edge-postgres" --format "{{.Status}}" 2>/dev/null)
if [ -n "$TB_STATUS" ]; then
  case "$TB_STATUS" in
    Up*) emit_ok "tb-edge-v2 container: $TB_STATUS" ;;
    *)   emit_fail "tb-edge-v2 container: $TB_STATUS" L7 ;;
  esac
else
  emit_fail "tb-edge-v2 container not found" L7
fi

if [ -n "$PG_STATUS" ]; then
  case "$PG_STATUS" in
    Up*) emit_ok "tb-edge-postgres: $PG_STATUS" ;;
    *)   emit_fail "tb-edge-postgres: $PG_STATUS" L7 ;;
  esac
fi

LESHAN_BOUND=$(netstat -uln 2>/dev/null | grep -c ':5683 ')
if [ "$LESHAN_BOUND" -gt 0 ]; then
  emit_ok "Leshan listening on :5683"
else
  emit_fail "no process listening on UDP :5683 (Leshan down)" L7
fi

JAVA_PID=$(pgrep -f 'java.*tb-edge' 2>/dev/null | head -1)
if [ -n "$JAVA_PID" ] && [ -r "/proc/$JAVA_PID/status" ]; then
  JAVA_RSS_KB=$(awk '/^VmRSS:/{print $2}' /proc/$JAVA_PID/status)
  JAVA_THR=$(awk '/^Threads:/{print $2}' /proc/$JAVA_PID/status)
  emit_ok "Java pid=$JAVA_PID rss=${JAVA_RSS_KB}KB threads=${JAVA_THR}"
  if [ "$JAVA_RSS_KB" -gt 1500000 ]; then
    emit_warn "Java RSS > 1.5GB (heap pressure?)" L7
  fi
fi

# ---- L8 LwM2M fleet ----------------------------------------------------------
emit_section "L8 LwM2M fleet (postgres ts_kv)"

# query distinct devices in fresh window. Column alias inside FILTER() needs
# a subquery-style structure for postgres; use a derived table.
FLEET_QUERY="
SELECT
  count(*) FILTER (WHERE sec_ago < 120)                         AS active_2min,
  count(*) FILTER (WHERE sec_ago < $TELEM_FRESH_SEC)            AS fresh,
  count(*) FILTER (WHERE sec_ago >= 1800 OR sec_ago IS NULL)    AS dead,
  count(*)                                                       AS total
FROM (
  SELECT d.name,
         extract(epoch from (now() - to_timestamp(max(t.ts)/1000)))::int AS sec_ago
  FROM device d LEFT JOIN ts_kv t ON t.entity_id = d.id
  WHERE d.type = '$EXPECTED_DEVICE_TYPE'
  GROUP BY d.name
) s;
"
FLEET=$(docker exec tb-edge-postgres psql -tAU postgres thingsboard_edge -c "$FLEET_QUERY" 2>/dev/null | tr -d ' ')
if [ -n "$FLEET" ]; then
  ACTIVE=$(echo "$FLEET" | cut -d'|' -f1)
  FRESH=$(echo "$FLEET" | cut -d'|' -f2)
  DEAD=$(echo "$FLEET" | cut -d'|' -f3)
  TOTAL=$(echo "$FLEET" | cut -d'|' -f4)
  emit_ok "fleet: total=$TOTAL active(<2min)=$ACTIVE fresh(<${TELEM_FRESH_SEC}s)=$FRESH dead(>30min or never)=$DEAD"
  if [ "$TOTAL" -gt 0 ]; then
    HEALTH_PCT=$((FRESH * 100 / TOTAL))
    if [ "$HEALTH_PCT" -ge 90 ]; then
      emit_ok "fleet health: ${HEALTH_PCT}% nodes fresh"
    elif [ "$HEALTH_PCT" -ge 50 ]; then
      emit_warn "fleet health: ${HEALTH_PCT}% nodes fresh (degraded)" L8
    else
      emit_warn "fleet health: ${HEALTH_PCT}% nodes fresh (most are zombies)" L8
    fi
  fi
else
  emit_warn "could not query postgres fleet status" L8
fi

# ---- L9 Cloud uplink ---------------------------------------------------------
emit_section "L9 Cloud uplink"

# Look for recent UNAVAILABLE errors vs successful uplink sends
RECENT_LOG=$(docker exec tb-edge-v2 tail -200 /var/log/tb-edge/tb-edge.log 2>/dev/null)
LAST_UPLINK=$(echo "$RECENT_LOG" | grep -aE 'GrpcCloudEventUplinkSender' | tail -1)
LAST_UNAVAIL=$(echo "$RECENT_LOG" | grep -ac 'UNAVAILABLE')
if [ -n "$LAST_UPLINK" ]; then
  UPLINK_LATENCY=$(echo "$LAST_UPLINK" | grep -oE 'took [0-9]+ ms' | grep -oE '[0-9]+')
  emit_ok "cloud uplink alive (last send took ${UPLINK_LATENCY}ms)"
fi
if [ "$LAST_UNAVAIL" -gt 5 ]; then
  emit_warn "$LAST_UNAVAIL UNAVAILABLE errors in last 200 log lines (TB Central reachability?)" L9
fi

# ---- L10 Object 33000 sample (only if fleet > 0) -----------------------------
emit_section "L10 Object 33000 spot-check"

# Skip if no devices fresh
if [ -n "${FRESH:-}" ] && [ "$FRESH" -gt 0 ]; then
  TOKEN=$(curl -sf -X POST "http://${TB_HOST}:${TB_PORT}/api/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${TB_USER}\",\"password\":\"${TB_PASS}\"}" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)

  if [ -n "$TOKEN" ]; then
    # Pick the most recently active device
    DEV_ID=$(docker exec tb-edge-postgres psql -tAU postgres thingsboard_edge -c "
      SELECT t.entity_id::text FROM ts_kv t
      JOIN device d ON t.entity_id = d.id
      WHERE d.type = '$EXPECTED_DEVICE_TYPE'
      ORDER BY t.ts DESC LIMIT 1;
    " 2>/dev/null | tr -d ' ')

    if [ -n "$DEV_ID" ]; then
      DEV_NAME=$(docker exec tb-edge-postgres psql -tAU postgres thingsboard_edge -c "
        SELECT name FROM device WHERE id = '$DEV_ID';" 2>/dev/null | tr -d ' ')
      # Read RID 17 (last_error_code) — should be 0 if firmware healthy
      # Helper to read one resource and extract numeric value (signed for last_error_code).
      # TB Edge RPC under load (Send observation pending + 28 zombie nodes pulling
      # downlink slots) can take 15-25s for the round trip. Empirically:
      #   timeout=5s   → 100% NO_RESPONSE
      #   timeout=10s  → 100% NO_RESPONSE during heavy load
      #   timeout=20s  → reliable
      # Use 22s curl + 20s server-side; if a node truly is silent at this
      # threshold, it is genuinely zombie (not just a slow downlink queue).
      read_rid() {
        curl -sf -X POST -H "X-Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
          --max-time 22 \
          -d "{\"method\":\"Read\",\"params\":{\"id\":\"/33000_2.2/0/$1\"},\"persistent\":false,\"timeout\":20000}" \
          "http://${TB_HOST}:${TB_PORT}/api/plugins/rpc/twoway/$DEV_ID" 2>/dev/null \
          | sed -n 's/.*value=\(-\{0,1\}[0-9]*\).*/\1/p' | head -1
      }
      LAST_ERR=$(read_rid 17)
      RECOVER=$(read_rid 15)

      if [ -n "$LAST_ERR" ]; then
        if [ "$LAST_ERR" = "0" ]; then
          emit_ok "$DEV_NAME RID17 last_error_code=0 RID15 recover_count=${RECOVER:-?}"
        else
          emit_warn "$DEV_NAME RID17 last_error_code=$LAST_ERR (firmware reports error)" L10
        fi
        if [ -n "$RECOVER" ] && [ "$RECOVER" -gt 0 ]; then
          emit_warn "$DEV_NAME RID15 recover_count=$RECOVER (recovery has triggered)" L10
        fi
      else
        emit_warn "Read RPC to $DEV_NAME timed out — node may be silent (PRIO 5 case)" L10
      fi
    fi
  else
    emit_warn "could not authenticate to TB Edge for Object 33000 sample" L10
  fi
else
  [ "$MODE" = "text" ] && printf "  ${C_DIM}skipped (no fresh devices)${C_RST}\n"
fi

# ---- Summary ----------------------------------------------------------------
TOTAL_CHECKS=$((PASS + WARN + FAIL))

if [ "$MODE" = "json" ]; then
  STATUS="HEALTHY"
  [ "$WARN" -gt 0 ] && STATUS="DEGRADED"
  [ "$FAIL" -gt 0 ] && STATUS="DOWN"
  printf '{"status":"%s","pass":%d,"warn":%d,"fail":%d,"total":%d,"failed_layers":"%s","warned_layers":"%s","ts":%d}\n' \
    "$STATUS" "$PASS" "$WARN" "$FAIL" "$TOTAL_CHECKS" \
    "${LAYERS_FAILED# }" "${LAYERS_WARNED# }" "$(date -u +%s)"
else
  printf "\n${C_DIM}=== Summary ===${C_RST}\n"
  printf "  ${C_OK}PASS${C_RST}: %d\n" "$PASS"
  if [ -n "$LAYERS_WARNED" ]; then
    printf "  ${C_WARN}WARN${C_RST}: %d  layers:%s\n" "$WARN" "$LAYERS_WARNED"
  else
    printf "  ${C_WARN}WARN${C_RST}: %d  layers: (none)\n" "$WARN"
  fi
  if [ -n "$LAYERS_FAILED" ]; then
    printf "  ${C_FAIL}FAIL${C_RST}: %d  layers:%s\n" "$FAIL" "$LAYERS_FAILED"
  else
    printf "  ${C_FAIL}FAIL${C_RST}: %d  layers: (none)\n" "$FAIL"
  fi

  if [ "$FAIL" -gt 0 ]; then
    printf "\n${C_FAIL}Status: DOWN${C_RST} — at least one critical layer failed.\n"
  elif [ "$WARN" -gt 0 ]; then
    printf "\n${C_WARN}Status: DEGRADED${C_RST} — operational but with warnings.\n"
  else
    printf "\n${C_OK}Status: HEALTHY${C_RST}\n"
  fi
fi

# Exit codes
[ "$FAIL" -gt 0 ] && exit 1
[ "$WARN" -gt 0 ] && exit 2
exit 0
