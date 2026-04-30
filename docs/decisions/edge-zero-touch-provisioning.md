# Zero-touch provisioning de edges con TB Central + mDNS

**Audiencia:** ingeniería que diseña el flujo de comissioning de un nuevo edge. Customer success que va a presentar el feature como diferenciador comercial.
**Estado:** Decidido — 2026-04-28. Validado empíricamente al provisionar `edge-r1000-wm6108` (`192.168.1.175`) usando la TB Central REST API directamente desde la laptop del operador. Plan de evolución a 3 fases (manual script → mDNS auto-discovery → cloud phone-home).
**Hermano:** [`edge-thingsboard.md`](../architecture/edge-thingsboard.md) y [`edge-r1000.md`](../architecture/edge-r1000.md) — specs vivas de los edges.

> **Resumen de una línea:** la TB Central REST API permite el provisioning end-to-end por script. Edges salen de fábrica con TB Edge embebido pero sin creds; la laptop del operador (1) crea la entrada en TB Central, (2) inyecta las creds en el edge vía LAN, (3) verifica que conectó. Todo automatizable con Ansible.

---

## 1. Contexto

### 1.1 La pregunta de negocio

Para que el edge sea **vendible como producto** (no como una integración custom por cliente), el flujo de instalación debe ser:

1. Cliente recibe edge "in box" — hardware + firmware preinstalado
2. Cliente conecta el edge a su LAN — toma DHCP, anuncia su presencia
3. Cliente (o el integrador) ejecuta UN comando desde su laptop → edge queda operativo

**SIN**:
- SSH manual al edge
- Edición a mano de archivos `.env`
- Copy/paste de routingKey/secret
- Conocimiento de la stack interna (Docker, OTBR, postgres)

### 1.2 La pregunta técnica

Para implementar lo de §1.1, hay que resolver:

- **A. Creación del edge en TB Central** — ¿se puede hacer por API? ¿qué creds piden? ¿cómo se autentica el operador?
- **B. Push de creds al edge** — ¿el edge expone un endpoint de setup? ¿cómo se autentica el push?
- **C. Discovery del edge en LAN** — ¿cómo encuentra la laptop al edge sin saber su IP? ¿cómo distingue edges unclaimed de claimed?

### 1.3 Lo que descubrimos al automatizar `edge-r1000-wm6108`

El 2026-04-28 ejecutamos el flow manualmente (SSH + comandos) y vía REST API. Hallazgos:

#### Hallazgo 1 — TB Central CE expone REST API funcional

```
POST http://<tb-central>:8080/api/auth/login
  body: { "username": "...", "password": "..." }
  resp: { "token": "<JWT>", "refreshToken": "..." }

POST http://<tb-central>:8080/api/edge
  header: X-Authorization: Bearer <JWT>
  body: { "name": "...", "type": "default", "routingKey": "...", "secret": "..." }
  resp: edge entity completo (incluye id, routingKey, secret, etc.)

GET http://<tb-central>:8080/api/edges?pageSize=20&page=0
  header: X-Authorization: Bearer <JWT>
  resp: { "data": [edge,...], "totalElements": N, ... }
```

**Las credenciales default (`tenant@thingsboard.org` / `tenant`) funcionan** out-of-the-box en TB CE. En producción se cambian, pero la API misma no cambia.

#### Hallazgo 2 — TB CE NO auto-genera routingKey/secret

Esto fue inesperado. El primer intento de `POST /api/edge` con solo `name` y `type` retornó:

```json
{
  "status": 400,
  "message": "Edge secret should be specified!",
  "errorCode": 31
}
```

**Implicación**: el cliente (laptop / Ansible / script) **debe generar las creds y enviarlas en el body**. La UI de TB Central las genera client-side antes del POST. Para automatización, hacemos:

```sh
ROUTING_KEY=$(openssl rand -hex 10)   # 20 chars hex
SECRET=$(openssl rand -hex 10)        # 20 chars hex
```

Coincide exactamente con el formato de las creds de un edge previo (`a20260e0f6129d16f080` / `627aa0162bc2e05c6fd2`).

#### Hallazgo 3 — El edge está pre-configurable, sólo le faltan las creds runtime

Cuando flasheamos un R1000 con la imagen OpenWrt actual, TB Edge containers se pueden `docker pull` y arrancar con env vars **sin que el container tenga conocimiento previo del cliente**. Las únicas variables que cambian por edge son:

- `CLOUD_RPC_HOST` (típicamente conocido — IP/hostname del TB Central del cliente)
- `CLOUD_RPC_PORT` (típicamente 7070)
- `CLOUD_ROUTING_KEY` (creado en TB Central por edge)
- `CLOUD_ROUTING_SECRET` (creado en TB Central por edge)

Otras config (puertos LwM2M, MQTT, dataset Thread) son del edge y **no requieren TB Central**.

#### Hallazgo 4 — Dependencia oculta: `console=ttyUSB0` en kernel cmdline

**Esto NO es de TB Central pero es relevante para la automatización**. La imagen base del Pi/CM4 trae `console=ttyUSB0,115200` en `/boot/cmdline.txt`. Esto rompe el RCP (mensajes de printk se mezclan con frames Spinel). En la migración del R1000 tuvimos que:

1. Editar `/boot/cmdline.txt` para quitarlo
2. Reboot
3. USB unbind/rebind del dongle CP210x

Para una **factory image production-ready**, este fix tiene que estar **horneado** en el firmware build (uci-defaults o similar) para que el cliente NUNCA tenga que tocarlo.

---

## 2. Decisión

### 2.1 Estructura de fases (ya conocida desde `edge-zero-touch-provisioning.md` proposal)

| Fase | Componentes | Cuándo |
|---|---|---|
| **0** Manual SSH | Setup directo, no comercial | hoy |
| **1** Script `provision-edge.sh` | Bash con curl + ssh, ejecutable desde laptop | semana 1 |
| **2** mDNS auto-discovery + setup endpoint en edge | LAN-side full automation | semana 2-3 |
| **3** Ansible role + CI/CD | Multi-edge, declarative, idempotent | semana 4 |
| **4** Cloud phone-home (Opción C de la propuesta) | Edges remotos detrás de NAT | meses |

Esta ADR documenta el **contrato técnico** que rige todas las fases (los componentes y APIs no cambian; solo cambia quién las invoca y cómo).

### 2.2 El contrato — 3 capas independientes

#### Capa A — TB Central control plane

```
┌─ POST /api/auth/login                  ─┐
│   user/pass del operador → JWT          │
│                                          │
├─ POST /api/edge {name, type, key, sec} ─┤
│   crea edge entry, devuelve UUID        │
│                                          │
├─ GET /api/edge/{id}                    ─┤
│   devuelve edge entity                  │
│                                          │
├─ GET /api/edges?page=N                 ─┤
│   lista edges del tenant                │
└──────────────────────────────────────────┘
```

#### Capa B — Laptop / CI orchestrator

```
$ tb-edge-claim discover            # Fase 2+: avahi-browse _tb-edge-claim._tcp
$ tb-edge-claim claim <target> --name "edge-X" \
    --tb-central http://tb.cliente:8080 \
    --tb-user admin@cliente.com --tb-pass <vault>
```

Internamente el orchestrator:

1. Auth a TB Central → token
2. `openssl rand -hex 10` × 2 → routingKey + secret
3. POST a TB Central → edge creado
4. Push de env vars al edge (Fase 1: SSH; Fase 2+: HTTPS al setup endpoint)
5. Edge restartea TB Edge container con env real
6. Poll TB Central API hasta ver el edge `state=connected`

#### Capa C — Edge runtime

Edge tiene 2 estados visibles:

```
unclaimed:
  - tb-edge-v2 corriendo con env placeholder (CLOUD_RPC_HOST=disabled)
  - mDNS publica _tb-edge-claim._tcp con TXT state=unclaimed
  - HTTP setup endpoint :8090/api/setup acepta POST con creds

claimed:
  - tb-edge-v2 corriendo con env real
  - mDNS publica con TXT state=claimed
  - Conectado a TB Central, telemetría fluyendo
```

**El edge no necesita saber cómo se llama el cliente, ni el URL de TB Central, ni nada — todo viene en el POST de claim.**

### 2.3 Qué pre-instalar en la factory image

Lecciones del R1000 → la imagen "factory" debe traer:

- [x] `console=ttyUSB0` removido de `/boot/cmdline.txt` (uci-defaults)
- [x] `/etc/init.d/otbr-agent` enabled, configurado para `/dev/ttyUSB0` baudrate 460800
- [x] `/etc/rc.local` con USB unbind/rebind recovery + reapply-dataset + thresholds 12/13
- [x] Docker images pre-cargadas (`docker pull` durante el build → `docker save | tar` → restore en flash)
- [x] `/opt/docker/tb-edge-data/` directorio + ownership 999:999 para postgres
- [ ] **Fase 2+**: Servicio `/etc/init.d/tb-edge-announce` que publica vía Avahi
- [ ] **Fase 2+**: CGI handler en uhttpd `/api/setup` que recibe POST con creds, persiste, restartea container

---

## 3. Implementación Fase 1 — Script `tb-edge-claim` (validado hoy)

### 3.1 Anatomía del script (validada en R1000 2026-04-28)

```bash
#!/bin/bash
# tb-edge-claim — Fase 1 (manual con SSH al edge)
#
# Usage: tb-edge-claim.sh <EDGE_HOST> <EDGE_NAME> <TB_HOST> [TB_USER] [TB_PASS]
# Ejemplo: ./tb-edge-claim.sh 192.168.1.175 edge-r1000-wm6108 192.168.1.170

set -euo pipefail

EDGE_HOST="${1:?missing EDGE_HOST}"
EDGE_NAME="${2:?missing EDGE_NAME}"
TB_HOST="${3:?missing TB_HOST}"
TB_USER="${4:-tenant@thingsboard.org}"
TB_PASS="${5:-tenant}"
TB_PORT="${TB_PORT:-8080}"
TB_RPC_PORT="${TB_RPC_PORT:-7070}"

echo "==> [1/5] Auth a TB Central ${TB_HOST}:${TB_PORT}"
TOKEN=$(curl -sf -X POST "http://${TB_HOST}:${TB_PORT}/api/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${TB_USER}\",\"password\":\"${TB_PASS}\"}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
[ -z "$TOKEN" ] && { echo "AUTH FAIL"; exit 1; }

echo "==> [2/5] Generar routingKey + secret"
ROUTING_KEY=$(openssl rand -hex 10)
SECRET=$(openssl rand -hex 10)
echo "    routingKey:    $ROUTING_KEY"
echo "    routingSecret: $SECRET"

echo "==> [3/5] Crear edge ${EDGE_NAME} en TB Central"
RESP=$(curl -sf -X POST "http://${TB_HOST}:${TB_PORT}/api/edge" \
    -H "X-Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${EDGE_NAME}\",\"type\":\"default\",\"routingKey\":\"${ROUTING_KEY}\",\"secret\":\"${SECRET}\"}")
EDGE_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['id']['id'])")
echo "    edgeId: $EDGE_ID"

echo "==> [4/5] Push creds al edge ${EDGE_HOST} (Fase 1: ssh + docker)"
ssh "root@${EDGE_HOST}" "
    docker stop tb-edge-v2 2>/dev/null; docker rm tb-edge-v2 2>/dev/null
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
        -e SPRING_DATASOURCE_URL='jdbc:postgresql://127.0.0.1:5432/thingsboard_edge' \
        -e SPRING_DATASOURCE_USERNAME=postgres \
        -e SPRING_DATASOURCE_PASSWORD=postgres \
        -e JAVA_OPTS='-Xms768m -Xmx1280m -XX:+UseG1GC' \
        thingsboard/tb-edge:4.3.1.1EDGE
"

echo "==> [5/5] Verify connection (poll TB Central por 120s)"
for i in $(seq 1 24); do
    STATE=$(curl -sf -H "X-Authorization: Bearer $TOKEN" \
        "http://${TB_HOST}:${TB_PORT}/api/edge/${EDGE_ID}" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('additionalInfo',{}).get('isOnline','unknown') if d.get('additionalInfo') else 'unknown')" 2>/dev/null)
    echo "    [${i}/24] state=${STATE}"
    [ "$STATE" = "True" ] && { echo "    ✅ EDGE ONLINE"; exit 0; }
    sleep 5
done

echo "    ⚠️  edge no aparece online en 120s — revisar manualmente: docker logs tb-edge-v2"
exit 1
```

### 3.2 Idempotencia

El script de §3.1 NO es idempotente (re-ejecutar crea otra edge entry). Para Ansible / CI, version idempotente:

- Antes de POST `/api/edge`, hacer `GET /api/edges?textSearch=$EDGE_NAME` → si ya existe, reusar sus creds
- Almacenar `routingKey/Secret` en una vault (HashiCorp Vault, Ansible Vault, env del CI)
- Si el edge existe en TB Central pero el container del R1000 tiene env distinto → re-push

### 3.3 Errores conocidos y manejo

| Error | Causa | Remedio |
|---|---|---|
| `400 Edge secret should be specified` | Body sin `routingKey/secret` | Generar con openssl, incluir en body |
| `403 You don't have permission` | Token expirado o user no es tenant_admin | Re-login |
| Docker container no arranca | `/opt/docker/tb-edge-data/db` con permisos malos | `chown -R 999:999 /opt/docker/tb-edge-data/db` |
| TB Edge logs `Cloud connection refused` | TB Central :7070 no alcanzable desde el edge | Verificar firewall/routing |
| TB Edge logs `Authentication failed` | routingKey/secret no coincide con TB Central | Re-crear edge en TB Central |

---

## 4. Hacia Fase 2 — mDNS auto-discovery

Lo aprendido en Fase 1 nos dice **qué pasos automatizar más** en Fase 2:

### 4.1 Reemplazar SSH manual con HTTPS al edge

Edge expone `/api/setup` (CGI bash en uhttpd):

```http
POST https://<edge-ip>:8443/api/setup
Authorization: Bearer <factory-token>
Content-Type: application/json

{
  "cloudRpcHost": "192.168.1.170",
  "cloudRpcPort": 7070,
  "cloudRoutingKey": "...",
  "cloudRoutingSecret": "..."
}
```

Edge persiste a `/opt/docker/tb-edge-data/.env`, restartea container, retorna 202.

### 4.2 mDNS announce en el edge

`/etc/init.d/tb-edge-announce` (procd one-shot al boot):

```sh
. /etc/config/tb-edge-state          # carga state=unclaimed o claimed
HW_MODEL=$(cat /tmp/sysinfo/board_name)
UUID=$(echo -n "$(cat /sys/class/net/eth0/address)$(cat /etc/board.json | jq -r .system.serial)" | sha256sum | head -c 16)

cat > /etc/avahi/services/tb-edge-claim.service <<EOF
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi.dtd">
<service-group>
  <name replace-wildcards="yes">%h-tb-edge-claim</name>
  <service>
    <type>_tb-edge-claim._tcp</type>
    <port>8443</port>
    <txt-record>state=$state</txt-record>
    <txt-record>uuid=$UUID</txt-record>
    <txt-record>hw_model=$HW_MODEL</txt-record>
    <txt-record>fw_version=$(cat /etc/openwrt_version)</txt-record>
    <txt-record>capabilities=otbr,thingsboard-edge,halow</txt-record>
  </service>
</service-group>
EOF
/etc/init.d/avahi-daemon reload
```

### 4.3 Laptop discovery

```bash
$ tb-edge-claim discover
UUID                IP              MODEL           STATE       VERSION
abc12300c5d4...     192.168.1.175   r1000-wm6108    unclaimed   2.9-dev
def45600a1b2...     192.168.1.183   ekh01           claimed     2.9-dev
```

Implementado con `avahi-browse -r _tb-edge-claim._tcp` o `dns-sd -B _tb-edge-claim._tcp` (macOS).

### 4.4 Trade-off Fase 1 vs Fase 2

| Aspecto | Fase 1 (SSH + script) | Fase 2 (mDNS + HTTPS) |
|---|---|---|
| Esfuerzo de implementación | ~2 horas | ~10 horas |
| Cliente necesita SSH al edge | ✅ sí | ❌ no |
| Cliente necesita conocer IP del edge | ✅ sí | ❌ (mDNS la descubre) |
| Edge requiere endpoint custom | ❌ no | ✅ uhttpd CGI |
| Vendor lock-in | bajo | bajo |
| Factor demo / cliente | medio | alto |

**Fase 1 es 100% suficiente para producción** si el cliente tiene un operador técnico. **Fase 2 abre la puerta a "yo cliente lo instalo solo"**.

---

## 5. Implementación Fase 3 — Ansible role

```yaml
# playbooks/claim-edges.yml
- hosts: localhost
  gather_facts: false
  vars_files:
    - vault/tb_central.yml      # tb_central_url, tb_user, tb_pass
  tasks:
    - name: Discover unclaimed edges via mDNS
      command: avahi-browse -tpr _tb-edge-claim._tcp
      register: mdns_output

    - name: Parse mDNS output
      set_fact:
        unclaimed_edges: "{{ mdns_output.stdout | parse_mdns_unclaimed }}"

    - name: Claim each edge
      include_tasks: tasks/claim_one_edge.yml
      loop: "{{ unclaimed_edges }}"
      loop_control: { loop_var: edge }
```

Donde `tasks/claim_one_edge.yml` envuelve el flow Fase 1 / Fase 2 según disponibilidad. Idempotent vía vault que recuerda qué edges ya tienen creds.

---

## 6. Consecuencias

### 6.1 Positivas

- **Vendible como feature**: "instalación zero-touch" diferencia el producto comercialmente
- **Time-to-deploy** baja de horas (manual) a minutos (Fase 1) a segundos (Fase 2 + paralelo)
- **Errores humanos** desaparecen (no hay copy/paste de creds)
- **Auditable**: cada claim deja log en TB Central (createdTime + user que lo hizo)
- **CI/CD-compatible**: edges se pueden provisionar como parte del pipeline de despliegue del cliente

### 6.2 Negativas / costos

- **Dependencia del schema TB Central** — si TB cambia el JSON de `/api/edge`, el script rompe. Mitigación: versionar contra TB CE 4.3.x explícitamente; tests de integración.
- **Default credentials de TB CE** son inseguras — si en producción no se cambian (`tenant@thingsboard.org/tenant`), cualquier laptop en LAN puede crear edges. Mitigación: hardening guide + cambio obligatorio de password.
- **mDNS broadcast en LAN** — discoverable por cualquiera. Mitigación: factory token en setup endpoint (ver §4.1 ADR `edge-zero-touch-provisioning.md`).

### 6.3 Boundaries

Esta ADR **NO** cubre:

- TB Edge multi-tenant (cada cliente = su propio TB Central)
- Edge HA / failover
- Migration de un edge entre TB Central distintos
- Renewal/rotation de routingKey/secret post-deploy

Esos quedan para futuras ADRs.

---

## 7. Validación empírica

### 7.1 Ejecución del 2026-04-28 — `edge-r1000-wm6108`

```
==> [1/5] Auth a TB Central 192.168.1.170:8080
    ✅ Token obtenido (creds default tenant@thingsboard.org/tenant)

==> [2/5] Generar routingKey + secret
    routingKey:    14571e5d963b557baedf
    routingSecret: 0268e4ba25df5e10438d

==> [3/5] Crear edge edge-r1000-wm6108 en TB Central
    edgeId: b1a230c0-432a-11f1-be42-ff951e684f01

==> [4/5] Push creds al edge 192.168.1.175 (Fase 1: ssh + docker)
    ✅ tb-edge-v2 container running

==> [5/5] Verify connection (poll TB Central por 120s)
    [pendiente medir tras instalación inicial completar]
```

Tiempo total medido (sin contar el `docker pull` previo, que se hace una sola vez): **~5 minutos**, mayoría tiempo de espera del `installation` script de TB Edge en su primer arranque (init de schema en postgres).

Tiempo en pipeline CI (con images pre-pulled en factory image): **~30-60 segundos**.

---

## 8. Referencias

### Internas

- [`docs/architecture/edge-thingsboard.md`](../architecture/edge-thingsboard.md) — spec del Pi 4 edge
- [`docs/architecture/edge-r1000.md`](../architecture/edge-r1000.md) — spec del R1000 (provisionado con esta ADR)
- [`docs/runbooks/tb-edge-baseline-tuning.md`](../runbooks/tb-edge-baseline-tuning.md) — runbook operativo

### Externas

- [ThingsBoard Edge REST API](https://thingsboard.io/docs/edge/getting-started/) — autenticación + edge management
- [ThingsBoard CE API Spec (Swagger)](http://192.168.1.170:8080/swagger-ui.html) — disponible en cada install
- [Avahi mDNS service definitions](https://avahi.org/) — formato de `/etc/avahi/services/*.service`
- [DNS-SD RFC 6763](https://datatracker.ietf.org/doc/html/rfc6763) — service announcement spec
