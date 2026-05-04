#!/bin/sh
#
# edge-autoheal.sh — detect a wedged OTBR stack, resolve the RCP device
# by USB VID:PID, and restart otbr-agent with the correct uart path.
#
# Restart is COSTLY: every otbr-agent restart drops all attached children,
# they have to MLE re-attach (each costs a fresh RLOC16 assignment), and
# in practice we lose 1-2 nodes per restart that don't come back fast
# enough. So this script is biased *strongly* toward "do nothing" unless
# the stack is really dead.
#
# What counts as "really dead" (RESTART):
#   1. otbr-agent process gone (procd's fail-after-N gave up).
#   2. radio reports `disabled` (RCP init failed, can't recover by waiting).
#   3. Nordic dongle re-enumerated to a different /dev/ttyACMN, so the
#      uci uart_device value is stale (we resolve current tty by VID:PID
#      and update uci before the restart).
#
# What DOESN'T trigger a restart anymore (SOFT signal):
#   - "ot-ctl no response within Ns": observed empirically as transient
#     under load (SRP storms, mDNS bursts, busy session socket). The
#     daemon is alive, just contended. Restarting here costs more than
#     it saves. We log the observation and move on.
#
# Cron: */5 * * * * /usr/sbin/edge-autoheal.sh
#
# Output:
#   /var/log/edge-autoheal.log    — append-only, one line per check
#

set -u

STATE_DIR=/var/lib/edge-autoheal
LOG=/var/log/edge-autoheal.log
COOLDOWN_S=1800
OTCTL_TIMEOUT_S=30
RECHECK_DELAY_S=30
# Two consecutive HARD-bad probes required before restart. SOFT-bad probes
# (ot-ctl slow) never escalate to restart — they only get logged.
CONSECUTIVE_BAD_REQUIRED=2

# Nordic nRF52840 OpenThread Device — stable identity of our RCP.
RCP_VID=1915
RCP_PID=cafe

mkdir -p "$STATE_DIR"

log() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG"
}

now_epoch() { date +%s; }

last_restart_epoch() {
    [ -f "$STATE_DIR/last-restart" ] && cat "$STATE_DIR/last-restart" || echo 0
}

mark_restart() {
    now_epoch > "$STATE_DIR/last-restart"
}

in_cooldown() {
    last=$(last_restart_epoch)
    delta=$(( $(now_epoch) - last ))
    [ "$delta" -lt "$COOLDOWN_S" ]
}

# Resolve the current /dev/ttyACMN owned by VID:PID. Returns "" if not found.
resolve_rcp_tty() {
    for vid_file in /sys/bus/usb/devices/*/idVendor; do
        [ -e "$vid_file" ] || continue
        vid=$(cat "$vid_file" 2>/dev/null)
        [ "$vid" = "$RCP_VID" ] || continue
        dev_path=$(dirname "$vid_file")
        pid=$(cat "$dev_path/idProduct" 2>/dev/null)
        [ "$pid" = "$RCP_PID" ] || continue
        # Find a child interface that exposes a tty
        for tty in "$dev_path"/*/tty/ttyACM*; do
            [ -e "$tty" ] || continue
            echo "/dev/$(basename "$tty")"
            return 0
        done
    done
    echo ""
    return 1
}

# --- detection ---

# One probe of the stack.
# Echoes a reason on stderr and returns:
#   0 — healthy
#   1 — HARD bad (process gone, radio disabled, weird state)
#   2 — SOFT bad (ot-ctl slow / no response, daemon likely alive but busy)
probe() {
    if ! pidof otbr-agent > /dev/null 2>&1; then
        echo "otbr-agent process not running" >&2
        return 1
    fi
    s=$(timeout "$OTCTL_TIMEOUT_S" ot-ctl state 2>/dev/null | head -1 | tr -d '\r')
    case "$s" in
        leader|router|child|detached)
            return 0
            ;;
        disabled)
            echo "ot-ctl reports disabled (radio not initialized)" >&2
            return 1
            ;;
        "")
            echo "ot-ctl no response within ${OTCTL_TIMEOUT_S}s (daemon alive, soft signal)" >&2
            return 2
            ;;
        *)
            echo "ot-ctl unexpected state: $s" >&2
            return 1
            ;;
    esac
}

reason=""
probe_class=0  # 0=healthy, 1=hard, 2=soft
probe_err=$(probe 2>&1)
probe_class=$?
[ "$probe_class" -ne 0 ] && reason="$probe_err"

# Healthy → reset bad-counter, opportunistically reconcile uci with sysfs.
current_uart=$(uci -q get otbr-agent.service.uart_device)
actual_tty=$(resolve_rcp_tty)

if [ "$probe_class" -eq 0 ]; then
    rm -f "$STATE_DIR/bad-count"
    if [ -n "$actual_tty" ] && [ "$current_uart" != "$actual_tty" ]; then
        log "RECONCILE uci uart_device: $current_uart -> $actual_tty (no restart, stack healthy)"
        uci set otbr-agent.service.uart_device="$actual_tty"
        uci commit otbr-agent
    fi
    exit 0
fi

# SOFT signal — never escalates to restart. Just log and exit. This
# happens when ot-ctl is slow under load; restarting causes child loss
# and is worse than waiting it out.
if [ "$probe_class" -eq 2 ]; then
    log "SOFT bad probe (no action) reason=\"$reason\""
    rm -f "$STATE_DIR/bad-count"
    exit 0
fi

# --- HARD signal — confirm with a re-probe before acting ---
# A single hard-bad can still be a transient at exactly the wrong moment
# (e.g., natural otbr restart from sysupgrade overlap). Wait, probe again;
# only count it if still HARD-bad. Two consecutive hard-bad ticks → restart.

sleep "$RECHECK_DELAY_S"
probe_err2=$(probe 2>&1)
probe_class2=$?
if [ "$probe_class2" -eq 0 ]; then
    log "transient hard-bad recovered after ${RECHECK_DELAY_S}s — first reason=\"$reason\""
    rm -f "$STATE_DIR/bad-count"
    exit 0
fi
if [ "$probe_class2" -eq 2 ]; then
    log "hard-bad downgraded to soft after ${RECHECK_DELAY_S}s — first reason=\"$reason\" recheck=\"$probe_err2\""
    rm -f "$STATE_DIR/bad-count"
    exit 0
fi

bad_count=0
[ -f "$STATE_DIR/bad-count" ] && bad_count=$(cat "$STATE_DIR/bad-count")
bad_count=$(( bad_count + 1 ))
echo "$bad_count" > "$STATE_DIR/bad-count"

if [ "$bad_count" -lt "$CONSECUTIVE_BAD_REQUIRED" ]; then
    log "hard-bad ${bad_count}/${CONSECUTIVE_BAD_REQUIRED} reason=\"$probe_err2\" — waiting for next tick"
    exit 0
fi

# --- decision ---

if in_cooldown; then
    last=$(last_restart_epoch)
    delta=$(( $(now_epoch) - last ))
    log "skip restart (cooldown ${delta}s/${COOLDOWN_S}s) reason=\"$reason\" current_uart=\"$current_uart\" actual_tty=\"$actual_tty\""
    exit 0
fi

# --- act ---

if [ -z "$actual_tty" ]; then
    log "FAIL Nordic RCP not enumerated (vid=$RCP_VID pid=$RCP_PID); not restarting (would loop). Check USB cable / dongle power."
    # We still mark the attempt to avoid spamming; cooldown protects us.
    mark_restart
    exit 1
fi

if [ "$current_uart" != "$actual_tty" ]; then
    log "uart_device mismatch: uci=$current_uart actual=$actual_tty — updating uci"
    uci set otbr-agent.service.uart_device="$actual_tty"
    uci commit otbr-agent
fi

log "RESTART otbr-agent reason=\"$reason\" uart_device=$actual_tty"
mark_restart

if [ -x /etc/init.d/otbr-agent ]; then
    /etc/init.d/otbr-agent restart >> "$LOG" 2>&1
    rc=$?
    log "restart exit=$rc"
else
    log "ERROR /etc/init.d/otbr-agent not executable"
fi

exit 0
