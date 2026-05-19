#!/bin/sh
# bench-otbr-init — one-shot setup for a fresh Pi4-EKH01 OpenWrt image as
# a bench Border Router, isolated from production (R1000 at 192.168.8.176).
#
# Run ONCE on the Pi4 after the first SSH login post-flash:
#
#   scp bench-otbr-init.sh root@<PI4_IP>:/tmp/
#   ssh root@<PI4_IP> sh /tmp/bench-otbr-init.sh
#
# Idempotent — safe to re-run.
#
# What it does (and what it does NOT):
#   - Sets hostname to pi4-bench-otbr
#   - Opens SSH on the WAN zone (bench convenience, NOT for production)
#   - Creates a fresh Thread dataset on channel 15 (different from
#     production channel 21 on the R1000) with network name UNAL-BENCH
#   - Persists the dataset TLV blob so we can re-apply after sysupgrade
#   - Adds fw4 'thread' zone for wpan0 (otherwise UDP from mesh is
#     dropped — same gotcha as edge-r1000.md §9 + thread-mesh-health.md
#     §3.5)
#   - Starts otbr-agent
#   - Adds /etc/sysupgrade.conf entries so the config sticks across
#     image upgrades
#
# What it does NOT install:
#   - No TB Edge container
#   - No SRP service publish (bench has no LwM2M server by default)
#   - No otbr-addr-lifetime-guard cron (the custom otbr-br package
#     ships the daemon as init.d — already running if installed)

set -e

LOG() { logger -t bench-otbr-init -s "$*"; }
LOG "starting bench setup"

# ---- 1. hostname ----------------------------------------------------------

uci set system.@system[0].hostname='pi4-bench-otbr'
uci commit system
echo 'pi4-bench-otbr' > /proc/sys/kernel/hostname

# ---- 2. SSH on WAN + uhttpd no-RFC1918 (bench convenience) ---------------

if ! uci -q show firewall | grep -q "Bench-SSH-WAN"; then
    uci -q batch <<-EOF
        add firewall rule
        set firewall.@rule[-1].name='Bench-SSH-WAN'
        set firewall.@rule[-1].src='wan'
        set firewall.@rule[-1].proto='tcp'
        set firewall.@rule[-1].dest_port='22'
        set firewall.@rule[-1].target='ACCEPT'
EOF
    LOG "added Bench-SSH-WAN rule"
fi

uci set uhttpd.main.rfc1918_filter='0'

# ---- 3. firewall zone for wpan0 (CRITICAL — without this UDP from mesh dropped)

if ! uci -q show firewall | grep -q "@zone.*name='thread'"; then
    uci add firewall zone >/dev/null
    uci set firewall.@zone[-1].name='thread'
    uci set firewall.@zone[-1].input='ACCEPT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].forward='ACCEPT'
    uci add_list firewall.@zone[-1].device='wpan0'
    LOG "added fw4 'thread' zone for wpan0"
fi

uci commit firewall
uci commit uhttpd
fw4 reload >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

# ---- 4. Thread dataset (channel 15, network UNAL-BENCH) ------------------
# Production R1000 lives on channel 21 / UNAL-R1000 — keep bench far away.
# We generate fresh random secrets so this mesh is cryptographically distinct.

DATASET_FILE=/etc/otbr/bench-dataset.tlvs
mkdir -p /etc/otbr

if [ ! -s "$DATASET_FILE" ]; then
    LOG "generating fresh bench dataset (channel 15, UNAL-BENCH)"

    # Make sure otbr-agent is up enough to drive ot-ctl
    /etc/init.d/otbr-agent enable
    /etc/init.d/otbr-agent start
    sleep 8

    # Wipe any pre-existing dataset, build a new one
    ot-ctl thread stop >/dev/null 2>&1 || true
    ot-ctl ifconfig down >/dev/null 2>&1 || true
    ot-ctl dataset clear >/dev/null 2>&1 || true
    ot-ctl dataset init new

    ot-ctl dataset activetimestamp 1
    ot-ctl dataset channel 15
    ot-ctl dataset networkname UNAL-BENCH

    # Persist the dataset TLV blob for replay after sysupgrade
    ot-ctl dataset commit active >/dev/null
    ot-ctl dataset active -x | head -1 | tr -d '\r' > "$DATASET_FILE"
    chmod 600 "$DATASET_FILE"
    LOG "wrote dataset to $DATASET_FILE ($(wc -c <$DATASET_FILE) bytes)"

    ot-ctl ifconfig up
    ot-ctl thread start

    # Wait for leader (single OTBR mesh — leader is us)
    i=0
    while [ "$i" -lt 12 ]; do
        STATE=$(ot-ctl state 2>&1 | head -1 | tr -d '\r')
        [ "$STATE" = "leader" ] && break
        sleep 3
        i=$((i+1))
    done
    LOG "Thread state after start: ${STATE:-unknown}"
else
    LOG "dataset already exists at $DATASET_FILE — leaving as is"
fi

# ---- 5. reapply-dataset hook for sysupgrade -----------------------------

cat > /etc/otbr/reapply-dataset.sh <<'INNER'
#!/bin/sh
# Run from /etc/rc.local on boot. If otbr-agent comes up without a
# stored dataset (e.g. after sysupgrade wipes NVS), re-apply it from
# the persisted TLV blob.
TLV=$(cat /etc/otbr/bench-dataset.tlvs 2>/dev/null)
[ -z "$TLV" ] && exit 0
STATE=$(ot-ctl state 2>/dev/null | head -1 | tr -d '\r')
[ "$STATE" = "disabled" ] || [ "$STATE" = "detached" ] || exit 0
logger -t bench-otbr "reapply dataset (state=$STATE)"
ot-ctl dataset set active "$TLV"
ot-ctl ifconfig up
ot-ctl thread start
INNER
chmod +x /etc/otbr/reapply-dataset.sh

# rc.local hook (idempotent)
if ! grep -q reapply-dataset.sh /etc/rc.local; then
    sed -i '/^exit 0$/i\\
( sleep 25 \&\& /etc/otbr/reapply-dataset.sh ) >> /tmp/reapply-dataset.log 2>\&1 \&' /etc/rc.local
    LOG "added reapply-dataset hook to /etc/rc.local"
fi

# ---- 6. sysupgrade persistence ------------------------------------------

for f in \
    /etc/config/otbr-agent \
    /etc/otbr/bench-dataset.tlvs \
    /etc/otbr/reapply-dataset.sh \
    /etc/rc.local \
    /etc/config/firewall ; do
    if ! grep -qxF "$f" /etc/sysupgrade.conf 2>/dev/null; then
        echo "$f" >> /etc/sysupgrade.conf
    fi
done
LOG "/etc/sysupgrade.conf updated"

# ---- 7. summary ---------------------------------------------------------

cat <<EOF

bench-otbr-init: done.

  hostname:     $(uci get system.@system[0].hostname)
  thread state: $(ot-ctl state 2>/dev/null | head -1 | tr -d '\r')
  channel:      $(ot-ctl channel 2>/dev/null | head -1 | tr -d '\r')
  networkname:  $(ot-ctl networkname 2>/dev/null | head -1 | tr -d '\r')
  panid:        $(ot-ctl panid 2>/dev/null | head -1 | tr -d '\r')
  dataset tlv:  $DATASET_FILE ($(wc -c <$DATASET_FILE 2>/dev/null || echo 0) bytes)
  fw4 thread zone: $(nft list chain inet fw4 input 2>/dev/null | grep -c 'iifname "wpan0"') jump rule(s)
  ssh-on-wan:   $(uci -q show firewall | grep -c 'Bench-SSH-WAN') rule(s)

To use as bench:
  - Get the dataset TLV (to load on test nodes via commissioning):
      cat $DATASET_FILE
  - Or copy the human-readable dataset:
      ot-ctl dataset active
  - Sanity check: from another host on LAN, ssh root@\$(uci get network.lan.ipaddr 2>/dev/null || echo '<dhcp-ip>')

To rotate dataset (forces all nodes to re-commission):
  rm $DATASET_FILE
  sh /tmp/bench-otbr-init.sh
EOF

LOG "bench setup complete"
