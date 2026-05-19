# Edge R1000 — Spec viva (twin del Pi4 EKH01, channel 21, network UNAL-R1000)

**Audiencia:** ingeniería que opera o replicará este edge.
**Estado:** En migración 2026-04-28. R1000 target principal porque hardware más robusto que Pi 4 (CM4 + carrier industrial).
**Hermano:** [`edge-thingsboard.md`](edge-thingsboard.md) — el edge gemelo Pi 4 EKH01 en `192.168.1.111`. Misma arquitectura aplicacional, distinto HW + canal Thread distinto + dataset distinto.

> **Diferencias intencionales con `edge-thingsboard.md`:**
> - **Channel Thread**: 21 (limpio según scan 2026-04-27) — el Pi 4 está en 25 con un rogue PAN `0xe702` interferiendo
> - **Network**: `UNAL-R1000` con keys/PSKc/prefijos COMPLETAMENTE NUEVOS — no reutiliza credenciales del Pi 4
> - **Hardware**: Seeed reComputer R1000 + Wio-WM6108 HaLow + Sonoff Zigbee 3.0 USB Plus V2 (RCP)
> - **Mesh role policy**: aplica desde día 1 el plan de [`thread-mesh-role-assignment.md`](../decisions/thread-mesh-role-assignment.md) — backbone selectivo, no all-FTD
> - **LwM2M lifetime**: aplica desde día 1 el plan de [`lwm2m-update-rate-and-mesh-capacity.md`](../decisions/lwm2m-update-rate-and-mesh-capacity.md) — `lifetime ≥ 60s`

---

## 1. Overview

```
┌────────────────────────────────────────────────┐
│  TB Central (server)  192.168.1.170:7070       │
│  └── Edge: edge-r1000-wm6108                   │
│         routingKey:    <opaque>                │
│         routingSecret: <opaque>                │
└──────────────────▲─────────────────────────────┘
                   │ RPC over LAN
┌──────────────────┴─────────────────────────────┐
│  EDGE R1000  192.168.8.176                     │
│                                                 │
│  + OpenWrt 23.05.5 / morse 2.9-dev             │
│  + OTBR (canal 21, leader)                     │
│  + ThingsBoard Edge 4.3.1.1EDGE (Docker)       │
│  + HaLow AP (`r1000-wm6108-a3dd`)              │
└─────────────────────────────────────────────────┘
                   │ Thread mesh
                   ▼
        Nodos LwM2M (target: ≥30 con backbone)
```

---

## 2. Per-edge variables

| Variable | Valor para este edge | Fuente |
|---|---|---|
| `EDGE_LAN_IP` | `192.168.8.176` | DHCP del router LAN actual (subnet `192.168.8.0/24`, post-2026-05-06) |
| `EDGE_HOSTNAME` | `r1000-wm6108-a3dd` | UCI `system.@system[0].hostname` |
| `THREAD_NETWORK_NAME` | `UNAL-R1000` | dataset CH21 |
| `THREAD_CHANNEL` | `21` | scan 2026-04-27 confirmó canal limpio |
| `THREAD_PAN_ID` | `0x41ae` | random gen |
| `THREAD_EXT_PAN_ID` | `b68333bc101c7c53` | random gen |
| `THREAD_NETWORK_KEY` | `b31c1588a1b2f68c622401711f73afd0` | **SECRET**, random gen |
| `THREAD_PSKC` | `6c9b91f71e5936022a86af24b3c92cd3` | **SECRET**, random gen |
| `THREAD_MESH_LOCAL_PREFIX` | `fdf1:a391:6243:2a67::/64` | random gen — preserved across RCP swap |
| `OMR_PREFIX` | `fd95:786d:5a7f:1::/64` | OTBR-assigned post-Nordic-RCP (was `fd67:9823:5fe5:1::/64` with Sonoff) |
| `EDGE_OMR_ADDR` | `fd95:786d:5a7f:1:edec:40a5:203:e654` | published in SRP for `_lwm2m._udp` lookup |
| `EDGE_MLEID_CURRENT` | `fdf1:a391:6243:2a67:838:6daa:c59c:b491` | derived from Nordic RCP extaddr |
| `EDGE_MLEID_LEGACY_ALIAS` | `fdf1:a391:6243:2a67:2478:c089:bf5a:2554` | TRANSITIONAL alias added to `wpan0` so 25 nodes still on firmware <v0.6.0 (with hardcoded mleid in `CONFIG_AMI_LWM2M_SERVER_IPV6_PRIMARY`) keep reaching TB Edge during the v0.6.0 DNS-SD-only rollout. Re-asserted on every `wpan0 ifup` by `/etc/hotplug.d/iface/99-wpan0-undeprecate`. **Remove** when all 30 nodes are on v0.6.0+. |
| `RCP_DEVICE` | `/dev/openthread-rcp` (udev symlink) | Nordic nRF52840 Dongle (`1915:cafe`); was Sonoff CP210x with `/dev/ttyUSB0` until 2026-04-30 |
| `RCP_BAUDRATE` | `1000000` | Nordic ot-rcp default; Sonoff era used `460800` |
| `CLOUD_RPC_HOST` | `127.0.0.1` (decoupled) | TB Edge runs **standalone** since 2026-05-06; previously `192.168.1.170:7070` |
| `CLOUD_ROUTING_KEY` | `disabled` | uplink intentionally off — TB Central not currently used |
| `EDGE_ID_IN_TB` | `b1a230c0-432a-11f1-be42-ff951e684f01` | UUID returned by `POST /api/edge` (preserved from coupled era for re-attach later) |
| `EDGE_NAME_IN_TB` | `edge-r1000-wm6108` | TB Central registry name |
| `TB_EDGE_HTTP_PORT` | `8090` | (8080 ocupado por dppd HaLow) |

> **Migration log** (do not delete; cited by ADRs):
> - **2026-04-28**: initial deployment with Sonoff CP210x RCP, OMR `fd67:9823:5fe5:1::/64`, mleid IID ending `bf5a:2554`. LAN subnet `192.168.1.0/24`, edge IP `192.168.1.175`.
> - **2026-04-30**: Sonoff RCP → Nordic nRF52840 swap (Sonoff went radio-deaf under load — see [`runbooks/thread-mesh-health.md`](../runbooks/thread-mesh-health.md) §3.6). Triggered new OMR prefix and new mleid IID.
> - **2026-05-06**: LAN subnet migrated `192.168.1.0/24` → `192.168.8.0/24`; edge IP now `192.168.8.176`. TB Central uplink intentionally disabled (`CLOUD_ROUTING_KEY=disabled`) — TB Edge operates standalone for the v0.6.0 firmware soak.

---

## 3. Hardware

| Componente | Modelo | Notas |
|---|---|---|
| SBC | Seeed reComputer R1000 (CM4-IO-Board) | 4 GB RAM (CM4), 16 GB eMMC + 256 GB NVMe opcional |
| HaLow | Wio-WM6108 (mPCIe, MM6108) | Polling-mode driver — ver [`halow-carrier-compatibility.md`](../decisions/halow-carrier-compatibility.md) |
| RCP Thread | Sonoff Zigbee 3.0 USB Plus V2 (SiLabs CP210x) | USB ID `10c4:ea60`, mantiene firmware OpenThread RCP |
| Router central | OpenWrt en `192.168.1.1` | Da DHCP/DNS a R1000 |
| TB Central server | en `192.168.1.170` | Server TB CE expuesto en :7070 (RPC) y :8080 (UI) |

---

## 4. Configuraciones críticas aplicadas (verbatim)

### 4.1 Kernel cmdline.txt — eliminó `console=ttyUSB0`

`/boot/cmdline.txt`:

```
console=serial0 console=tty1 root=/dev/mmcblk0p2 rootfstype=squashfs,ext4 rootwait
```

> **Por qué**: el firmware de fábrica del Pi/CM4 trae `console=ttyUSB0,115200` en cmdline. Esto hace que el kernel use el dongle CP210x como consola de logs, lo que **rompe el protocolo Spinel del RCP** (mensajes de printk se mezclan con frames Spinel).
> **Cómo se identifica**: `/proc/consoles` lista `ttyUSB0` como consola activa.
> **Aplicado el 2026-04-28** durante migración del R1000.

### 4.2 UCI `otbr-agent`

```
otbr-agent.service.thread_if_name='wpan0'
otbr-agent.service.infra_if_name='eth0'
otbr-agent.service.uart_device='/dev/ttyUSB0'
otbr-agent.service.uart_baudrate='460800'
otbr-agent.service.uart_flow_control='0'
otbr-agent.service.auto_attach='1'
```

### 4.3 wpan0 mleid un-deprecate persistente (lección 2026-04-29)

**Crítico para LwM2M sobre Thread.** El otbr-agent asigna las mesh-local addresses a `wpan0` con `preferred_lft=0` (deprecated). Linux RFC 6724 rule 3 evita usarlas como source y usa la **OMR address** en su lugar. Resultado: cuando un nodo conecta UDP al mleid del border router (publicado vía SRP), el peer recibe respuestas con `src=OMR ≠ peer-connected mleid` → drop por mismatch en el cliente Zephyr LwM2M.

**Síntoma cascada del bug**: nodo conecta OK, recibe Observation Response del primer Read, pero a los ~3-5 min el `Registration Update` no recibe ACK (asimetría src/dst), y el cliente Zephyr cae al fallback estándar OMA-LwM2M-1.1: full `REGISTER` (`zephyr/subsys/net/lib/lwm2m/lwm2m_rd_client.c:613-622, do_update_timeout_cb`). TB Edge interpreta el segundo REGISTER como nueva sesión y cierra la vieja → ciclo Re-REGISTER cada lifetime.

**Hallazgo clave**: el hotplug `99-wpan0-undeprecate` (§8) sí se ejecuta al `ifup` de wpan0, pero **algo posterior re-marca la EID como deprecated dentro del primer minuto**. Sospechosos:
- otbr-agent address-management refresh interno
- Kernel timer del valid_lft/preferred_lft original que asignó otbr-agent
- Router Advertisement procesado que recalcula address lifetimes

**Fix aplicado**: cron cada minuto en R1000 (UCI-equivalent — OpenWrt usa busybox crond, no systemd):

```sh
# /etc/crontabs/root
* * * * * EID=$(ot-ctl ipaddr mleid 2>/dev/null | head -1 | tr -d '\r'); [ -n "$EID" ] && ip -6 addr change "${EID}/64" dev wpan0 preferred_lft forever valid_lft forever 2>/dev/null
```

`/etc/crontabs/root` agregado a `/etc/sysupgrade.conf`. crond se enabled con `/etc/init.d/cron enable`.

**Por qué cron y no systemd timer**: OpenWrt usa procd, no systemd. crond ya viene en busybox del firmware. Reuse de la lógica del hotplug script (extracción dinámica del mleid vía `ot-ctl ipaddr mleid`) — robusto si el dataset cambia.

**Alternativa más invasiva** (no aplicada todavía): parchar otbr-agent en `src/agent/ncp_openthread.cpp` para que mesh-local EID nunca quede `preferred_lft=0`. Es el fix correcto upstream pero requiere build custom de otbr-agent. Se considera para próxima rev del firmware OpenWrt.

### 4.4 Firewall — zone `thread` para `wpan0` (lección 2026-04-28)

**Crítico**: el firewall fw4/nft de OpenWrt tiene `policy drop` en chain `input` con jumps explícitos solo para `lo`, `br-lan`, `eth0`, `docker0`. **Cualquier paquete que entra al host por `wpan0` cae en `handle_reject` y es rechazado** — incluyendo CoAP/LwM2M/DNS-SD desde nodos Thread.

**Síntoma del bug**: nodo se une al mesh OK (`ot-ctl child table` lo muestra), pero TB Edge **NUNCA** recibe el `REGISTER` LwM2M. `tcpdump -i wpan0` no captura nada saliendo o entrando del host (porque el firewall lo rechaza antes de que llegue al socket Java).

**Fix aplicado** (UCI persistent):

```sh
uci add firewall zone
uci set firewall.@zone[-1].name='thread'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='ACCEPT'
uci set firewall.@zone[-1].device='wpan0'
uci commit firewall
/etc/init.d/firewall reload
```

Resultado: chain `input` ahora tiene `iifname "wpan0" jump input_thread` antes de `handle_reject`, y `input_thread` jumps a `accept_from_thread`. Verificable con `nft list ruleset | grep wpan0`.

`/etc/config/firewall` agregado a `/etc/sysupgrade.conf` para preservar la zone tras reflashes.

**Por qué Pi 4 no tenía el bug**: el otro edge probablemente tiene `firewall.@defaults[0].input='ACCEPT'` o una zone equivalente desde alguna configuración temprana no documentada. **Replicar este fix en todos los edges nuevos desde día 1**.

### 4.4 Bridge eth0/eth1 swap

R1000 expone `eth0` (CM4 onboard GbE) y `eth1` (USB-Eth via LAN9512). Configurado:
- `eth0` → WAN (DHCP, 192.168.8.176)
- `eth1` → LAN (br-lan, 10.42.0.1/24)

Ver [`02_network`](../../target/linux/bcm27xx/base-files/etc/board.d/02_network) sección `seeed,r1000-wm6108`.

---

## 5. Thread / OTBR

### 5.1 Active dataset

Persistido en `/etc/otbr/active-dataset.tlvs` y `/etc/otbr/active-dataset.txt`. **Preservado a través de sysupgrade** (ver §9).

```
Active Timestamp: 1
Channel: 21
Wake-up Channel: 26
Channel Mask: 0x07fff800
Ext PAN ID: b68333bc101c7c53
Mesh Local Prefix: fdf1:a391:6243:2a67::/64
Network Key: b31c1588a1b2f68c622401711f73afd0       # SECRET
Network Name: UNAL-R1000
PAN ID: 0x41ae
PSKc: 6c9b91f71e5936022a86af24b3c92cd3                # SECRET
Security Policy: 672 onrc 0
```

Raw TLV (lo que entra en `ot-ctl dataset set active <hex>`):

```
0e0800000000000100004a0300001a35060004001fffe00208b68333bc101c7c530708fdf1a39162432a670510b31c1588a1b2f68c622401711f73afd0010241ae04106c9b91f71e5936022a86af24b3c92cd30003000015030a554e414c2d52313030300c0402a0f778
```

### 5.2 Border Router state (snapshot inicial 2026-04-28)

```
ot-ctl state           → leader
ot-ctl br state        → running
ot-ctl br omrprefix    → Local: fd67:9823:5fe5:1::/64    Favored: same prf:low
ot-ctl partitionid     → 552377921
ot-ctl rloc16          → d800
```

### 5.3 Router thresholds (aplicado desde día 1)

```sh
ot-ctl routerupgradethreshold 12     # planeado para hasta 12 routers backbone
ot-ctl routerdowngradethreshold 13
```

Persistido en `/etc/rc.local` (ver §8). Esta es **la diferencia más importante con el Pi 4** — desde el inicio aplicamos la decisión arquitectural de `thread-mesh-role-assignment.md` (backbone selectivo) en vez de mitigación reactiva (32/33).

### 5.4 LwM2M update interval policy

Los nodos que se conecten a este edge **DEBEN** tener `lifetime ≥ 60s`. Ver [`lwm2m-update-rate-and-mesh-capacity.md`](../decisions/lwm2m-update-rate-and-mesh-capacity.md) para por qué (modelo de capacidad airtime).

Si se reciben nodos con `lifetime < 60s`, el edge se va a saturar igual que pasó con el Pi 4 (10 detached por airtime contention).

---

## 6. ThingsBoard Edge stack (Docker)

### 6.1 Containers (planeado)

```
NAMES               IMAGE                              ROLE
tb-edge-v2          thingsboard/tb-edge:4.3.1.1EDGE    Edge core (Java + Spring)
tb-edge-postgres    postgres:15-alpine                 DB del edge (sólo 127.0.0.1:5432)
```

> NO se incluyen `edge-prom-agent` ni `promtail` desde día 1 — se agregan solo si la operación los requiere (lecciones del Pi 4 muestran que liberar RAM ayuda a tener más headroom).

### 6.2 tb-edge env vars

```
CLOUD_RPC_HOST=192.168.1.170
CLOUD_RPC_PORT=7070
CLOUD_ROUTING_KEY=<TBD>
CLOUD_ROUTING_SECRET=<TBD>
HTTP_BIND_PORT=8090                       # 8080 ocupado por dppd
MQTT_BIND_ADDRESS=0.0.0.0
MQTT_BIND_PORT=1883
LWM2M_BIND_PORT=5683
LWM2M_SECURITY_BIND_PORT=5684
LWM2M_ENABLED=true
COAP_ENABLED=false
COAP_SERVER_ENABLED=false
LWM2M_ENABLED_BS=false
SPRING_DATASOURCE_URL=jdbc:postgresql://127.0.0.1:5432/thingsboard_edge
SPRING_DATASOURCE_USERNAME=postgres
SPRING_DATASOURCE_PASSWORD=postgres
JAVA_OPTS="-Xms768m -Xmx1280m -XX:+UseG1GC -XX:MaxGCPauseMillis=200"
```

### 6.3 Volumes

| Container | Mount | Host path |
|---|---|---|
| tb-edge-v2 | `/data` | `/opt/docker/tb-edge-data` (bind) |
| tb-edge-postgres | `/var/lib/postgresql/data` | `/opt/docker/tb-edge-data/db` (bind, owner 999:999) |

### 6.4 Postgres tuning aplicado desde día 1 (lecciones Pi 4)

```sql
ALTER SYSTEM SET work_mem = '2MB';
ALTER SYSTEM SET maintenance_work_mem = '32MB';
ALTER SYSTEM SET effective_cache_size = '1GB';
ALTER SYSTEM SET random_page_cost = 1.5;
ALTER SYSTEM SET autovacuum_vacuum_cost_delay = '20ms';
SELECT pg_reload_conf();
```

---

## 7. mDNS + SRP

Mismo patrón que el Pi 4:

- Avahi publica `_coap._udp.local` con port 5683 + TXT records (LAN-side discovery)
- OTBR SRP server publica `_coap._udp` y `_lwm2m._udp` en `default.service.arpa.` (mesh-side)
- dnsmasq forwarder mapea `thingsboard-edge.local` → IPv4/IPv6

### 7.1 SRP server addresses — `MLEID`, NO `OMR` (lección 2026-04-28)

**Crítico**: el SRP host `thingsboard-edge` se publica con la **mesh-local EID** del border router, NUNCA con la OMR address.

```
✅ Correcto:   addresses: [fdf1:a391:6243:2a67:2478:c089:bf5a:2554]   ← mleid
❌ Bug:        addresses: [fd67:9823:5fe5:1:1061:43d9:fa54:b221]      ← OMR
```

**Por qué importa**: el cliente LwM2M (Zephyr/OpenThread en el nodo) hace `connect()` UDP al address que devuelve el SRP. Cuando TB Edge responde, Linux selecciona source address por **longest-prefix-match contra el dst del paquete saliente**. Como el destino es la mesh-local del nodo (`fdf1:a391:6243:2a67::/64`), el match más largo es la **mleid** del border router (64 bits compartidos), no la OMR (0 bits compartidos con `fd67::/64`).

Resultado del bug:
1. Nodo conecta UDP socket con `peer = OMR fd67:…:b221`
2. REGISTER llega al server ✓
3. Server responde con `src = mleid fdf1:…:2554` (selección automática del kernel)
4. Nodo recibe paquete con `src ≠ peer-connected` → **drop por mismatch**
5. Síntoma: REGISTER aparenta OK pero ningún `ObserveRequest`/`Update` pasa

**Cómo se aplica correctamente** (en `/etc/rc.local`, ver §8):

```sh
MLEID=$(ot-ctl ipaddr mleid 2>/dev/null | head -1 | tr -d '\r')
ot-ctl srp client host name thingsboard-edge
ot-ctl srp client host address $MLEID         # ← explícito, NO usar 'auto'
ot-ctl srp client service add ThingsBoard-Edge _coap._udp 5683 0 0
ot-ctl srp client service add ThingsBoard-Edge _lwm2m._udp 5683 0 0
ot-ctl srp client autostart enable
```

> ⚠️ NO usar `ot-ctl srp client host address auto` — OpenThread elige una de las direcciones publicadas (típicamente OMR) y eso reproduce el bug.

**Cómo se diagnostica**: `ot-ctl srp server service` muestra el campo `addresses:`. Si tiene la OMR (prefix `fd67::/64` típicamente, o cualquier prefijo distinto al mesh-local), está mal.

### 7.2 Verificar simetría src/dst para nodos Thread

Desde el OTBR, después de aplicar el fix:

```sh
# El address que ve el cliente debe coincidir con el mleid del host
ot-ctl srp server service | grep -A2 'host:' | grep addresses
ot-ctl ipaddr mleid    # debe match
```

Para verificar que las respuestas del kernel salen con `src = mleid`:

```sh
# En el OTBR durante un test de un nodo:
tcpdump -i any -nn 'host <node_mesh_local>' -c 10
# El src de los paquetes salientes desde el OTBR debe ser la mleid
```

---

## 8. Boot scripts (`/etc/rc.local`)

```bash
#!/bin/sh -e

# OTBR-RCP-RECOVERY: USB unbind/rebind del dongle si después de boot el spinel falla
# Lección R1000 (2026-04-28): el chip CP210x a veces queda en estado corrupto post-boot
( sleep 5
  if ! ot-ctl state >/dev/null 2>&1; then
    echo "$(date): rc.local: spinel not responding, USB-resetting cp210x dongle" >> /tmp/otbr-rcp-recovery.log
    /etc/init.d/otbr-agent stop
    sleep 2
    killall -9 otbr-agent 2>/dev/null
    sleep 2
    CP_PATH=$(for d in /sys/bus/usb/devices/*/idVendor; do
      [ -e "$d" ] && [ "$(cat $d)" = '10c4' ] && basename "${d%/idVendor}"
    done)
    [ -n "$CP_PATH" ] && {
        echo "$CP_PATH" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null
        sleep 2
        echo "$CP_PATH" > /sys/bus/usb/drivers/usb/bind 2>/dev/null
        sleep 5
    }
    /etc/init.d/otbr-agent start
  fi
) >> /tmp/otbr-rcp-recovery.log 2>&1 &

# OTBR-REAPPLY: reapply Thread dataset si OT en disabled/detached
( sleep 18 && /etc/otbr/reapply-dataset.sh >> /tmp/otbr-reapply.log 2>&1 ) &

# OTBR-THRESHOLDS: backbone selectivo de hasta 12 routers
( sleep 25 && \
  ot-ctl routerupgradethreshold 12 && \
  ot-ctl routerdowngradethreshold 13 ) >> /tmp/otbr-router-thresholds.log 2>&1 &

# SRP-THINGSBOARD: register TB Edge en Thread SRP server con MLEID (no OMR).
# Crítico: usar mleid explícito, NO 'auto'. Ver §7.1 para por qué.
( sleep 30 && \
  MLEID=$(ot-ctl ipaddr mleid 2>/dev/null | head -1 | tr -d '\r') && \
  [ -n "$MLEID" ] && \
  ot-ctl srp client host name thingsboard-edge && \
  ot-ctl srp client host address $MLEID && \
  ot-ctl srp client service add ThingsBoard-Edge _coap._udp 5683 0 0 && \
  ot-ctl srp client service add ThingsBoard-Edge _lwm2m._udp 5683 0 0 && \
  ot-ctl srp client autostart enable ) >> /tmp/srp-thingsboard.log 2>&1 &

exit 0
```

### 8.1 `/etc/otbr/reapply-dataset.sh`

```bash
#!/bin/sh
TLV=$(cat /etc/otbr/active-dataset.tlvs 2>/dev/null)
[ -z "$TLV" ] && exit 1
STATE=$(ot-ctl state 2>/dev/null | head -1)
if [ "$STATE" = 'disabled' ] || [ "$STATE" = 'detached' ]; then
    echo "$(date): reapplying dataset (state=$STATE)"
    ot-ctl dataset set active $TLV
    ot-ctl ifconfig up
    ot-ctl thread start
fi
```

---

## 9. Persistence — `/etc/sysupgrade.conf`

```
/etc/config/otbr-agent
/etc/otbr/active-dataset.tlvs
/etc/otbr/active-dataset.txt
/etc/otbr/reapply-dataset.sh
/etc/rc.local
```

> **Pendiente agregar** después del setup TB Edge:
> - `/opt/docker/tb-edge-data/.env` (creds CLOUD_ROUTING_*)
> - Otros configs que se generen

---

## 10. Replay procedure (TBD — a documentar conforme avanzamos)

Este es el procedimiento para provisionar otro edge gemelo. Se completará cuando termine la migración del R1000.

---

## 11. Health checks (mismos que Pi 4)

Ver [`edge-thingsboard.md §11`](edge-thingsboard.md). Aplicables sin cambios.

Métricas adicionales específicas R1000:

```sh
# RCP recovery — verificar que NO se haya disparado
cat /tmp/otbr-rcp-recovery.log
# (vacío = ok; con entradas = el dongle se resetea seguido, problema HW)
```

---

## 12. TODOs abiertos

### Completados 2026-04-28
- [x] Crear edge en TB Central + obtener creds (vía REST API, ver ADR `edge-zero-touch-provisioning.md`)
- [x] Validar TB Edge conecta y procesa cloud events (gRPC uplink/downlink fluyendo)
- [x] Configurar SRP register (`ThingsBoard-Edge._coap._udp.default.service.arpa`) ✓
- [x] Configurar mDNS LAN announce (`_coap._udp.local`) ✓
- [x] Snapshot baseline OTBR + TB Edge en `snapshots/edge-192.168.1.175-2026-04-28-otbr-up.txt`

### Pendientes
- [ ] Configurar mesh role policy desde día 1 — firmware nodos = MED, backbone = REED (ver `thread-mesh-role-assignment.md`)
- [ ] Configurar LwM2M lifetime ≥ 60s en firmware nodos antes de commissionarlos (ver `lwm2m-update-rate-and-mesh-capacity.md`)
- [ ] Provisionar primer batch de nodos al mesh `UNAL-R1000` para validar capacidad real
- [ ] Capacity test empírico Fase A (5 nodos) según runbook `lwm2m-capacity-test.md`
- [ ] Eventualmente: implementar Fase 2 zero-touch (mDNS auto-discovery + setup endpoint en uhttpd) — ver `edge-zero-touch-provisioning.md` §4

---

## 13. Snapshot inicial 2026-04-28

Capturado al final de la migración OTBR. Ver [`snapshots/edge-192.168.1.175-2026-04-28-otbr-up.txt`](snapshots/) (a crear).
