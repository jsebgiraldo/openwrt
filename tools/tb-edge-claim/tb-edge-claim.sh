#!/bin/bash
# tb-edge-claim — Phase 1 zero-touch edge provisioning
#
# Usage:
#   ./tb-edge-claim.sh <EDGE_HOST> <EDGE_NAME> <TB_HOST> [TB_USER] [TB_PASS]
#
# Required env (override defaults):
#   TB_PORT       (default 8080)   — TB Central UI/API port
#   TB_RPC_PORT   (default 7070)   — TB Central edge RPC port
#   SSH_USER      (default root)   — SSH user to push creds to edge
#   TB_EDGE_IMAGE (default thingsboard/tb-edge:4.3.1.1EDGE)
#
# Example:
#   ./tb-edge-claim.sh 192.168.1.175 edge-r1000-wm6108 192.168.1.170
#
# References:
#   docs/decisions/edge-zero-touch-provisioning.md

set -euo pipefail

EDGE_HOST="${1:?Usage: $0 EDGE_HOST EDGE_NAME TB_HOST [TB_USER] [TB_PASS]}"
EDGE_NAME="${2:?missing EDGE_NAME}"
TB_HOST="${3:?missing TB_HOST}"
TB_USER="${4:-tenant@thingsboard.org}"
TB_PASS="${5:-tenant}"
TB_PORT="${TB_PORT:-8080}"
TB_RPC_PORT="${TB_RPC_PORT:-7070}"
SSH_USER="${SSH_USER:-root}"
TB_EDGE_IMAGE="${TB_EDGE_IMAGE:-thingsboard/tb-edge:4.3.1.1EDGE}"

err()  { echo "[ERROR] $*" >&2; exit 1; }
note() { echo "==> $*"; }

command -v openssl >/dev/null   || err "openssl not found"
command -v curl    >/dev/null   || err "curl not found"
command -v python3 >/dev/null   || err "python3 not found (used for JSON parsing)"
command -v ssh     >/dev/null   || err "ssh not found"

note "[1/5] Auth a TB Central ${TB_HOST}:${TB_PORT}"
TOKEN=$(curl -sf -X POST "http://${TB_HOST}:${TB_PORT}/api/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${TB_USER}\",\"password\":\"${TB_PASS}\"}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])") \
    || err "TB Central auth failed"

note "[2/5] Idempotency check — edge '${EDGE_NAME}' already exists?"
EXISTING=$(curl -sf -H "X-Authorization: Bearer $TOKEN" \
    "http://${TB_HOST}:${TB_PORT}/api/edges?pageSize=100&page=0&textSearch=${EDGE_NAME}" \
    | python3 -c "
import sys, json
edges = json.load(sys.stdin).get('data', [])
for e in edges:
    if e['name'] == '${EDGE_NAME}':
        print(f\"{e['id']['id']} {e['routingKey']} {e['secret']}\")
        break
")

if [ -n "$EXISTING" ]; then
    EDGE_ID=$(echo "$EXISTING" | awk '{print $1}')
    ROUTING_KEY=$(echo "$EXISTING" | awk '{print $2}')
    SECRET=$(echo "$EXISTING" | awk '{print $3}')
    note "    Edge ya existe: ${EDGE_ID}, reusing existing creds"
else
    note "[3/5] Generar routingKey + secret"
    ROUTING_KEY=$(openssl rand -hex 10)
    SECRET=$(openssl rand -hex 10)
    note "    routingKey:    $ROUTING_KEY"
    note "    routingSecret: $SECRET"

    note "[3.5/5] Crear edge ${EDGE_NAME} en TB Central"
    RESP=$(curl -sf -X POST "http://${TB_HOST}:${TB_PORT}/api/edge" \
        -H "X-Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${EDGE_NAME}\",\"type\":\"default\",\"routingKey\":\"${ROUTING_KEY}\",\"secret\":\"${SECRET}\"}") \
        || err "create edge failed"
    EDGE_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['id']['id'])")
    note "    edgeId: $EDGE_ID"
fi

note "[4/5] Push creds al edge ${EDGE_HOST} (Phase 1: ssh + docker recreate)"
ssh -o StrictHostKeyChecking=no "${SSH_USER}@${EDGE_HOST}" "
    set -e
    docker stop tb-edge-v2 2>/dev/null || true
    docker rm tb-edge-v2 2>/dev/null || true
    docker run -d --name tb-edge-v2 --restart unless-stopped --network host \
        -v /opt/docker/tb-edge-data:/data \
        -e CLOUD_RPC_HOST=${TB_HOST} \
        -e CLOUD_RPC_PORT=${TB_RPC_PORT} \
        -e CLOUD_ROUTING_KEY=${ROUTING_KEY} \
        -e CLOUD_ROUTING_SECRET=${SECRET} \
        -e HTTP_BIND_PORT=8090 \
        -e MQTT_BIND_PORT=1883 \
        -e LWM2M_BIND_PORT=5683 \
        -e LWM2M_SECURITY_BIND_PORT=5684 \
        -e LWM2M_ENABLED=true \
        -e COAP_ENABLED=false \
        -e COAP_SERVER_ENABLED=false \
        -e LWM2M_ENABLED_BS=false \
        -e SPRING_DATASOURCE_URL='jdbc:postgresql://127.0.0.1:5432/thingsboard_edge' \
        -e SPRING_DATASOURCE_USERNAME=postgres \
        -e SPRING_DATASOURCE_PASSWORD=postgres \
        -e JAVA_OPTS='-Xms768m -Xmx1280m -XX:+UseG1GC -XX:MaxGCPauseMillis=200' \
        ${TB_EDGE_IMAGE}
"

note "[5/5] Verify connection — poll TB Central up to 180s"
for i in $(seq 1 36); do
    STATE=$(curl -sf -H "X-Authorization: Bearer $TOKEN" \
        "http://${TB_HOST}:${TB_PORT}/api/edge/${EDGE_ID}" \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
ai = d.get('additionalInfo') or {}
print('online' if ai.get('isOnline') else 'offline')
" 2>/dev/null)
    echo "    [${i}/36] state=${STATE}"
    [ "$STATE" = "online" ] && {
        note "    ✅ EDGE ONLINE — claim successful"
        echo
        echo "Summary:"
        echo "  edgeId:        $EDGE_ID"
        echo "  routingKey:    $ROUTING_KEY"
        echo "  routingSecret: $SECRET"
        echo "  TB Central:    http://${TB_HOST}:${TB_PORT}/edges/${EDGE_ID}"
        exit 0
    }
    sleep 5
done

note "    ⚠️  edge still offline after 180s"
note "    Debug: ssh ${SSH_USER}@${EDGE_HOST} 'docker logs --tail 50 tb-edge-v2'"
exit 1
