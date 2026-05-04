#!/bin/sh
#
# doctor-snapshot-cron.sh — periodic /usr/sbin/edge-doctor.sh snapshot
# capture for timeline reconstruction during scaling soak tests.
#
# Designed to run from cron (every 30 min). Each invocation appends one
# JSON line to /var/log/edge-doctor.jsonl with a timestamp prefix, so the
# file is grep-able and parseable without rotation logic.
#
# Companion log /var/log/edge-doctor-summary.log holds a short text summary
# (status + fail/warn counts) for quick scanning with tail -f.
#
# Usage:
#   /usr/sbin/doctor-snapshot-cron.sh           # once
#   */30 * * * * /usr/sbin/doctor-snapshot-cron.sh  # in /etc/crontabs/root
#
# References:
#   docs/runbooks/thread-mesh-health.md §1.0
#   tools/edge-doctor/edge-doctor.sh

set -u

JSONL=/var/log/edge-doctor.jsonl
SUMMARY=/var/log/edge-doctor-summary.log
LOCK=/var/lock/doctor-snapshot.lock

# Single-instance guard (a previous run may still be inside the 30s MAC sample)
exec 9>"$LOCK"
flock -n 9 || exit 0

TS=$(date -u +%s)
HUMAN=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Use a shorter MAC sample to fit cron timing. The default 30s sample blocks
# the script for 30s; 10s is enough to detect retries during a 30-min window.
JSON=$(MAC_SAMPLE_S=10 /usr/sbin/edge-doctor.sh --json 2>/dev/null)

# Append one line to JSONL — the JSON itself already has "ts", but we wrap
# with a header in case the doctor script ever changes its output schema.
printf '%s %s\n' "$HUMAN" "$JSON" >> "$JSONL"

# Short summary: status, pass/warn/fail
STATUS=$(echo "$JSON" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')
PASS=$(echo "$JSON"   | sed -n 's/.*"pass":\([0-9]*\).*/\1/p')
WARN=$(echo "$JSON"   | sed -n 's/.*"warn":\([0-9]*\).*/\1/p')
FAIL=$(echo "$JSON"   | sed -n 's/.*"fail":\([0-9]*\).*/\1/p')

# Pull a couple of fleet metrics for the summary
FLEET=$(docker exec tb-edge-postgres psql -tAU postgres thingsboard_edge -c "
  SELECT
    count(*) FILTER (WHERE sec_ago < 60)  AS a60,
    count(*) FILTER (WHERE sec_ago < 300) AS a300,
    count(*)                              AS total
  FROM (
    SELECT extract(epoch from (now() - to_timestamp(max(t.ts)/1000)))::int AS sec_ago
    FROM device d LEFT JOIN ts_kv t ON t.entity_id = d.id
    WHERE d.type = 'AMI_LwM2M_Node'
    GROUP BY d.name
  ) s;
" 2>/dev/null | tr '|' ',' | tr -d ' ')

# Children count from OT
CHILDREN=$(ot-ctl child table 2>/dev/null | grep -c '^|.*0x')

printf '%s status=%s pass=%s warn=%s fail=%s children=%s fleet(active60s/active5min/total)=%s\n' \
  "$HUMAN" "$STATUS" "$PASS" "$WARN" "$FAIL" "$CHILDREN" "${FLEET:-?,?,?}" \
  >> "$SUMMARY"

# Cap JSONL at 5 MB (rotate once)
SZ=$(wc -c < "$JSONL" 2>/dev/null | tr -d ' ')
if [ -n "$SZ" ] && [ "$SZ" -gt 5242880 ]; then
  mv "$JSONL" "$JSONL.old"
fi
SZ=$(wc -c < "$SUMMARY" 2>/dev/null | tr -d ' ')
if [ -n "$SZ" ] && [ "$SZ" -gt 1048576 ]; then
  mv "$SUMMARY" "$SUMMARY.old"
fi
