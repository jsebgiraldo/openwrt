# Edge ThingsBoard + OTBR — Architecture spec

**Status:** snapshot tomado en vivo desde `192.168.1.111` (`ekh01-de87`) el 2026-04-27.
**Propósito:** este documento describe la arquitectura completa del nodo "edge central" del proyecto UNAL-Thread, en un formato lo suficientemente preciso para que un agente (o humano) pueda **replicarlo en un nuevo edge `edge-X`** editando sólo los valores marcados como *per-edge* en §2 y siguiendo el procedimiento de §10.

> **⚠️ Secrets en este documento:** Network Key de Thread, PSKc, contraseña SAE de HaLow, y cloud routing key/secret de ThingsBoard. Trátalo como restringido. Para forks/repos públicos, mover los secrets a un `.env` no versionado y referenciarlos desde aquí por placeholder.

---

## 1. Overview

```
                      ┌──────────────────────────┐
                      │ Cloud (ThingsBoard CE)   │
                      │ 192.168.1.170:7070 (RPC) │
                      └────────────▲─────────────┘
                                   │ MQTT/RPC over LAN
                                   │
        ┌──────────────────────────┴───────────────────────────────┐
        │                Edge central (192.168.1.111)              │
        │                  Pi 4 + EKH01 HaLow hat                  │
        │  ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐  │
        │  │ tb-edge-v2   │ │ tb-edge-pg   │ │ promtail / prom  │  │
        │  │ MQTT :1883   │ │ Postgres     │ │ logs / metrics   │  │
        │  │ HTTP :8090   │ │ :5432 (loop) │ │                  │  │
        │  └──────┬───────┘ └──────────────┘ └──────────────────┘  │
        │         │  Docker (host net)                              │
        │  ┌──────┴───────────────────────────────────────────┐    │
        │  │ OpenWrt 23.05.5 + Morse 2.9-dev                  │    │
        │  │ ┌─────────┐  ┌──────────┐  ┌──────────────────┐  │    │
        │  │ │ br-lan  │  │ wlan0    │  │ wpan0 (Thread)   │  │    │
        │  │ │ eth0    │◄─┤ HaLow AP │  │ OTBR + SRP server│  │    │
        │  │ │+wlan0   │  │ S1G US   │  │ UNAL-Thread mesh │  │    │
        │  │ │+veth*   │  │ ch=auto  │  │ /64 OMR prefix   │  │    │
        │  │ └─────────┘  └──────────┘  └──────────────────┘  │    │
        │  └──────────────────────────────────────────────────┘    │
        └──────────┬─────────────────────────┬────────────────────┘
                   │                         │
            ┌──────▼─────┐         ┌─────────▼────────────┐
            │ Upstream   │         │ HaLow client nodes   │
            │ LAN gw     │         │ (R1000, sensors, …)  │
            │ 192.168.1.1│         │ vía wlan0 SAE        │
            └────────────┘         └──────────────────────┘
                                            │
                                   ┌────────▼─────────────┐
                                   │ Thread mesh routers  │
                                   │ (vía SiLabs RCP)     │
                                   └──────────────────────┘
```

**Servicios que este edge provee al resto del sistema:**

| Servicio | Endpoint | Visible desde |
|---|---|---|
| ThingsBoard MQTT broker | `[fdf5:bffd:bd6:ef74:eb7b:f1d1:874e:2b91]:1883` | Thread mesh (vía SRP), LAN (vía mDNS), LAN-IP `192.168.1.111:1883` |
| ThingsBoard HTTP UI | `192.168.1.111:8090` | LAN |
| ThingsBoard LwM2M | `*:5683/5685` UDP | LAN/Thread |
| OTBR DNS-SD proxy | `[fdf5:bffd:bd6:ef74:eb7b:f1d1:874e:2b91]:53` | Thread mesh |
| HaLow SAE AP `ekh01-de87` | S1G band, ch auto US | HaLow clients en rango |

---

## 2. Per-edge variables

Cuando repliques este spec en un edge nuevo (`edge-X`), cambia sólo estos valores:

| Variable | Valor en este edge | Notas |
|---|---|---|
| `EDGE_HOSTNAME` | `ekh01-de87` | Patrón: `<board>-<eth0_mac_suffix>`. Auto-derivado por OpenWrt si no se cambia. |
| `EDGE_LAN_IP` | `192.168.1.111` (DHCP) | Asignado por el router de upstream. Reservar por MAC en el DHCP server upstream. |
| `EDGE_ETH0_MAC` | `88:a2:9e:1c:de:87` | Inmutable (chip serial). |
| `HALOW_SSID` | `ekh01-de87` | Cambiar si quieres SSIDs distintos por edge. |
| `HALOW_SAE_KEY` | `jYNJ5MQ8` | Generar uno nuevo por edge si el deployment no comparte WLAN. |
| `CLOUD_RPC_HOST` | `192.168.1.170` | IP del ThingsBoard CE upstream. Igual entre edges del mismo cluster. |
| `CLOUD_RPC_PORT` | `7070` | Igual entre edges. |
| `CLOUD_ROUTING_KEY` | `a20260e0f6129d16f080` | **Único por edge** — generado por TB CE al provisionar el edge. |
| `CLOUD_ROUTING_SECRET` | `627aa0162bc2e05c6fd2` | **Único por edge** — par del routing key. |
| `TB_DATA_DIR` | `/opt/docker/tb-edge-data` | Volume mount; persiste estado del edge. Subdir `db/` contiene Postgres data. Vacío en deploy nuevo. |
| `LOKI_URL` | `http://loki:3100/loki/api/v1/push` | Endpoint de Loki para promtail. Resuelto por DNS de LAN/Thread. |
| `PROM_REMOTE_WRITE_URL` | `http://100.67.60.126:9090/api/v1/write` | Servidor Prometheus central (Tailscale/WG en este deployment). |
| `NODE_EXPORTER_PORT` | `9100` | Servido por OpenWrt `prometheus-node-exporter-lua`. |

Valores **compartidos por todos los edges del mismo Thread mesh** (no cambiar a menos que rotes el mesh):

| Variable | Valor |
|---|---|
| `THREAD_NETWORK_NAME` | `UNAL-Thread` |
| `THREAD_PANID` | `0x23ed` |
| `THREAD_EXTPANID` | `1a2578dd6ee3573b` |
| `THREAD_CHANNEL` | `25` |
| `THREAD_NETWORKKEY` | `5edebead64405b3e17193646c2942285` |
| `THREAD_PSKC` | `bb7e7aee56236ea96ac8dc65bba18351` |
| `THREAD_MESH_LOCAL_PREFIX` | `fdf5:bffd:bd6:ef74::/64` |
| `THREAD_OMR_PREFIX` | `fdee:f43f:d8b2:1::/64` (anunciado por el BR — un mesh suele tener uno solo) |
| `TB_EDGE_THREAD_ADDR` | `fdf5:bffd:bd6:ef74:eb7b:f1d1:874e:2b91` (el OMR-derived global de wpan0 en el host) |

---

## 3. Hardware

| Item | Valor |
|---|---|
| SoC | Raspberry Pi 4 / CM4 — `bcm27xx/bcm2711`, aarch64 Cortex-A72 |
| HaLow | EKH01 hat (MorseMicro MMx108-EKH01, **SDIO** — no SPI en este edge) |
| Thread RCP | SiLabs ZONFF dongle (USB CDC ACM, `/dev/ttyUSB1`, 460800 baud) |
| Storage | mmcblk0p2 (Pi4 SD), 64 GiB overlay → ~44 GiB libres |
| RAM | 1.85 GiB |

> **Nota sobre R1000:** la imagen R1000 (`recomputer-r1000-wm6108-spi-...`) usa la misma base firmware pero con HaLow **SPI** + carrier PCA9535 + polling-mode driver. Diferencias respecto a EKH01:
>
> - **Wireless `bcf`/`path`**: ver §4.2 (`bcf_fgh100mhaamd.bin` en R1000, `bcf_mf15457.bin` en EKH01).
> - **Ethernet roles**: el R1000 tiene 2 puertos físicos: `eth0` = CM4 GbE (BCM54210, gigabit) y `eth1` = LAN9512 USB-Eth (100M). La convención del firmware es **`eth0` = WAN uplink** (cable al router upstream para internet rápido) y **`eth1` = LAN** (en `br-lan`, para PLCs / sensores que no necesitan más de 100M). Definido en `target/linux/bcm27xx/base-files/etc/board.d/02_network` con `ucidef_set_interfaces_lan_wan "eth1" "eth0"`. Si flasheas un R1000, plug el cable de internet en `eth0` y los PLCs/dispositivos LAN en `eth1`.

---

## 4. OpenWrt UCI configs (verbatim)

### 4.1 `/etc/config/network`

```
config interface 'loopback'
    option device 'lo'
    option proto 'static'
    option ipaddr '127.0.0.1'
    option netmask '255.0.0.0'

config globals 'globals'
    option ula_prefix 'fd0f:0e50:0476::/48'

config device
    option name 'br-lan'
    option type 'bridge'
    list ports 'eth0'

config interface 'lan'
    option device 'br-lan'
    option proto 'dhcp'

config interface 'lan6'
    option device 'br-lan'
    option proto 'dhcpv6'

config interface 'wan'
    option proto 'dhcp'

config interface 'docker'
    option device 'docker0'
    option proto 'none'
    option auto '0'

config device
    option type 'bridge'
    option name 'docker0'
```

### 4.2 `/etc/config/wireless` (HaLow AP)

```
config wifi-device 'radio0'
    option type 'morse'
    option path 'platform/soc/fe300000.mmc/mmc_host/mmc1/mmc1:0001/mmc1:0001:2'  # SDIO; cambiar para SPI: platform/soc/fe204000.spi/spi_master/spi0/spi0.1
    option band 's1g'
    option hwmode '11ah'
    option reconf '0'
    option bcf 'bcf_mf15457.bin'      # EKH01-MM8108. Para R1000+WM6108 → bcf_fgh100mhaamd.bin
    option country 'US'
    option channel 'auto'              # En US 1 MHz: usar 27/29-35/37-49 (28 y 36 están excluidos por regulatorio)
    option s1g_chanbw '8'              # Ancho de canal en MHz; 1/2/4/8 según regulatorio + capacidades

config wifi-iface 'default_radio0'
    option mode 'ap'
    option wds '1'
    option device 'radio0'
    option network 'lan'
    option ssid 'ekh01-de87'           # → $EDGE_HOSTNAME por convención
    option encryption 'sae'
    option key 'jYNJ5MQ8'              # → $HALOW_SAE_KEY
```

### 4.3 `/etc/config/system`

```
config system
    option hostname 'ekh01-de87'       # → $EDGE_HOSTNAME
    option timezone 'UTC'
    option zonename 'Etc/UTC'
```

### 4.4 `/etc/config/firewall`

Default OpenWrt — `lan` zone ACCEPT all, `wan` zone REJECT input/forward + masq. **No reglas custom adicionales en este edge.** (Si quieres permitir SSH/HTTP desde WAN como en R1000, ver `/etc/uci-defaults/60-r1000-debug-ssh` en el repo.)

### 4.5 `/etc/config/dhcp`

Default OpenWrt — dnsmasq + odhcpd. La parte custom (registros estáticos para `thingsboard-edge.local`) está **fuera** de UCI, en `/etc/dnsmasq.conf` (§7).

### 4.6 `/etc/config/otbr-agent`

```
config otbr-agent 'service'
    option thread_if_name 'wpan0'
    option infra_if_name 'eth0'
    option uart_device '/dev/ttyUSB1'  # SiLabs ZONFF — verificar con `dmesg | grep tty`
    option uart_baudrate '460800'
    option uart_flow_control '0'
    option auto_attach '1'
```

### 4.7 `/etc/config/otbr-network`

Mirror del Thread dataset (la fuente de verdad runtime es OpenThread; este UCI sirve para reconstruir si el dataset se pierde). Ver §5 para los valores reales.

### 4.8 `/etc/config/otbr-srp`

```
config srp 'config'
    option enabled '1'
    option startup_delay '5'

# (en este edge la registración manual está hardcoded en /etc/rc.local; opcionalmente
#  reemplazar por la sección service de abajo, lo que hace que /etc/init.d/otbr-srp
#  se haga cargo y rc.local pueda quedar limpio)
config service 'thingsboard_edge'
    option enabled '1'
    option name 'ThingsBoard-Edge'
    option type '_mqtt._tcp'
    option port '1883'
    option host 'thingsboard-edge'
```

---

## 5. Thread / OTBR

### 5.1 Active dataset

Persistido en `/etc/otbr/active-dataset.tlvs` y `/etc/otbr/active-dataset.txt`. **Preservado a través de sysupgrade** (ver §9).

```
Active Timestamp: 1
Channel: 25
Wake-up Channel: 15
Channel Mask: 0x07fff800
Ext PAN ID: 1a2578dd6ee3573b
Mesh Local Prefix: fdf5:bffd:bd6:ef74::/64
Network Key: 5edebead64405b3e17193646c2942285        # SECRET
Network Name: UNAL-Thread
PAN ID: 0x23ed
PSKc: bb7e7aee56236ea96ac8dc65bba18351                # SECRET
Security Policy: 672 onrc 0
```

Raw TLV (lo que entra en `ot-ctl dataset set active <hex>`):

```
0e0800000000000100004a0300000f35060004001fffe002081a2578dd6ee3573b0708fdf5bffd0bd6ef7405105edebead64405b3e17193646c2942285010223ed0410bb7e7aee56236ea96ac8dc65bba183510c0402a0f7f8030b554e414c2d5468726561640003000019
```

### 5.2 Border Router state (snapshot)

```
ot-ctl state           → leader
ot-ctl br state        → running
ot-ctl br omrprefix    → Local: fdee:f43f:d8b2:1::/64    Favored: same prf:low
ot-ctl br onlinkprefix → Local: fd1a:2578:dd6e:573b::/64 Favored: 2800:484:8f7e:32f0::/64 (LAN delegated)
ot-ctl partitionid     → 1200248003
ot-ctl rloc16          → dc00
```

### 5.3 SRP server + client (ambos en este nodo)

```
ot-ctl srp server state   → running
ot-ctl srp server domain  → default.service.arpa.
ot-ctl srp client state   → Enabled
ot-ctl srp client server  → [fdf5:bffd:bd6:ef74:eb7b:f1d1:874e:2b91]:53536  (sí mismo)
ot-ctl srp client host    → name:"thingsboard-edge", state:Registered, addrs:[fdf5:bffd:bd6:ef74:eb7b:f1d1:874e:2b91]
ot-ctl srp client service → instance:"ThingsBoard-Edge", name:"_mqtt._tcp", state:Registered, port:1883
```

### 5.4 DNS-SD proxy (browse desde cualquier nodo Thread)

```
ot-ctl dns config         → Server: [fdf5:bffd:bd6:ef74:eb7b:f1d1:874e:2b91]:53
                            ServiceMode: srv_txt_opt
ot-ctl dns browse _mqtt._tcp.default.service.arpa
  → ThingsBoard-Edge  Port:1883  Host:thingsboard-edge.default.service.arpa.
                      HostAddress: fdf5:bffd:bd6:ef74:eb7b:f1d1:874e:2b91
```

### 5.5 Address-lifetime guard

`/etc/init.d/otbr-addr-guard` (START=96) corre `/usr/sbin/otbr-addr-lifetime-guard` — pinea las direcciones OMR/EID en `wpan0` con `preferred_lft=forever` para que RFC 6724 no las degrade y deje de poderlas usar como source-address. Hace una pasada inicial al boot + monitorea con `ip -6 monitor address` para re-publish events. Built into the firmware (parte del paquete openthread-br).

### 5.6 Router upgrade/downgrade thresholds (mesh tuning para 30+ nodos FTD)

> **Decisión arquitectural completa:** ver [`docs/decisions/thread-mesh-role-assignment.md`](../decisions/thread-mesh-role-assignment.md).
> Esta sección documenta solamente el **estado actual aplicado en este edge** (mitigación interim).

#### Estado actual — mitigación interim 2026-04-27

Los 30 nodos están flasheados como FTD/REED (`mode rdn`). Se subió el cap del leader al máximo del protocolo Thread (32):

```sh
ot-ctl routerupgradethreshold 32      # default OpenThread: 16
ot-ctl routerdowngradethreshold 33    # default OpenThread: 23
```

Persistido en `/etc/rc.local` (OpenThread no guarda estos en NVS, ver §8).

Antes/después del fix (60s sample con `ot-ctl counters mac reset`):

| MAC counter | Pre-fix | Post-fix |
|---|---|---|
| `TxDirectMaxRetryExpiry` (paquetes perdidos) | 148 | **0** |
| `TxErrAbort` | 30 | **0** |
| `TxErrCca` | 6 | **0** |
| `TxErrBusyChannel` | 6 | **0** |
| `RxErrNoUnknownNeighbor` | 111 | **0** |

OpenThread auto-balanceó la mesh: 17 de los 30 nodos pidieron router-id, 13 se quedaron como REED-children porque ya tenían parent estable.

#### Limitación de esta config

Esta mitigación **funciona para 30 nodos pero no escala a 60**. La razón: Thread 1.x cap MAX_ROUTERS=32 es un límite del protocolo (Router-ID es 6 bits). Con 60 REED competirían 60 nodos por 32 slots → vuelve el churn.

#### Plan a futuro (cuando se escale a 60)

Cambio de estrategia documentado en [`docs/decisions/thread-mesh-role-assignment.md`](../decisions/thread-mesh-role-assignment.md):

1. Reflashear todos los nodos como **MED** (`mode rn` + `routereligible disable`)
2. Discovery empírico: ver cuáles quedan detached del OTBR
3. Reflashear ~12 nodos backbone como **REED** (`mode rdn`) cubriendo las zonas muertas
4. Bajar `routerupgradethreshold` a 12 (al tamaño del backbone)

Mientras eso no se ejecute, mantener los 32/33 actuales — es la mejor mitigación posible sin tocar firmware.

#### Aplicabilidad a otros edges

| Tamaño del edge | Recomendación |
|---|---|
| < 16 nodos FTD | Usar defaults OpenThread (16/23). No tocar. |
| 16-30 nodos FTD/REED | Aplicar 32/33 como en este edge. Mitigación suficiente. |
| 30-60 nodos | Plan all-MED + backbone selectivo (ver ADR). 32/33 solo como interim. |
| > 60 nodos | Considerar multi-partition (varios OTBRs). Ver ADR §4.3. |

### 5.7 Capacidad del mesh — modelo de tráfico (airtime)

> **Decisión arquitectural completa:** ver [`docs/decisions/lwm2m-update-rate-and-mesh-capacity.md`](../decisions/lwm2m-update-rate-and-mesh-capacity.md).
> Esta sección documenta el **modelo aplicado a este edge específico**.

#### Por qué la topología no es suficiente

§5.6 cubre cuántos routers caben (cap protocolar de 32). Pero **eso es ortogonal a cuántos mensajes caben en airtime**. Un mesh topológicamente perfecto se satura igual si cada nodo manda 50 msg/min (lo que vimos en el deployment actual).

#### Modelo cuantitativo (resumen, ver ADR para derivación)

```
N_max ≈ 70_kbps × 0.30 ÷ per_node_bps

per_node_bps = msg_rate × 85 B × 1.5 hops × 1.05 retx × 1.10 overhead × 8
```

| Configuración | `lifetime` LwM2M | Rate aplicación | `per_node_bps` | **N_max teórico** |
|---|---|---|---|---|
| Actual (deployment problemático) | 5s | ~50 msg/min | ~980 bps | **~21 nodos** |
| Recomendado para 30 nodos | 60s | ≤ 1 msg/min | ~20 bps | **~1,000 nodos** |
| Real-time crítico (alarmas) | 30s | 1 msg/seg | ~1,225 bps | ~17 nodos |

#### Estado actual del edge (2026-04-28, pre-mitigación de rate)

| Métrica | Valor |
|---|---|
| Nodos provisionados | 30 |
| Nodos activos sostenidos en TB Edge | 20 |
| Nodos detached >1h | 10 |
| Rate observado por nodo | 45-55 msg/min (~0.85 Hz) |
| Rate agregado | ~25 msg/s |
| `ts_kv` writes/hora | ~58,800 |
| `per_node_bps` calculado | ~980 |
| Predicción modelo `N_max` | ~21 |
| Empírico `N_max` | **20** ← coincide con el modelo |

El modelo predijo correctamente la saturación. **Para escalar, hay que bajar `lifetime` o el rate aplicación**, no agregar más routers.

#### Plan de medición empírica

Documentado en [`docs/runbooks/lwm2m-capacity-test.md`](../runbooks/lwm2m-capacity-test.md). Ejecutar **antes** de cualquier cambio de firmware en producción.

---

## 6. ThingsBoard Edge stack (Docker)

### 6.1 Containers

Todos en `network: host`, restart `unless-stopped`.

```
NAMES               IMAGE                              ROLE
tb-edge-v2          thingsboard/tb-edge:4.3.1.1EDGE    Edge core (Java + Spring)
tb-edge-postgres    postgres:15-alpine                 DB del edge (sólo escucha en 127.0.0.1:5432)
edge-prom-agent     prom/prometheus:latest             Métricas locales
promtail            grafana/promtail:3.0.0             Forward de logs a Loki
```

### 6.2 tb-edge env vars (clave)

```
CLOUD_RPC_HOST=192.168.1.170             # → $CLOUD_RPC_HOST
CLOUD_RPC_PORT=7070                       # → $CLOUD_RPC_PORT
CLOUD_ROUTING_KEY=a20260e0f6129d16f080    # → $CLOUD_ROUTING_KEY  (único por edge)
CLOUD_ROUTING_SECRET=627aa0162bc2e05c6fd2 # → $CLOUD_ROUTING_SECRET
INTEGRATIONS_RPC_PORT=10090
HTTP_BIND_PORT=8090
MQTT_BIND_ADDRESS=0.0.0.0
MQTT_BIND_PORT=1883
LWM2M_SECURITY_BIND_PORT=5684
SPRING_DATASOURCE_URL=jdbc:postgresql://127.0.0.1:5432/thingsboard_edge
SPRING_JPA_DATABASE_PLATFORM=org.hibernate.dialect.PostgreSQLDialect
```

### 6.3 Volumes (realidad medida en este edge)

| Container | Mount | Host path |
|---|---|---|
| tb-edge-v2 | `/data` | `/opt/docker/tb-edge-data` (bind) |
| tb-edge-postgres | `/var/lib/postgresql/data` | `/opt/docker/tb-edge-data/db` (bind, subdir bajo el de TB) |
| edge-prom-agent | `/etc/prometheus/prometheus.yml` | `/opt/docker/prometheus-agent/prometheus-agent.yml` (read-only) |
| promtail | `/etc/promtail/promtail.yml` | `/opt/docker/promtail/promtail.yml` (read-only) |
| promtail | `/var/log` | `/var/log:ro` (read-only) |

`/opt/docker` está en el overlay (rw), persiste a través de reboot pero **NO** sobrevive a `sysupgrade -n` (factory reset). Backup recomendado antes de re-flashear:

```sh
tar -czf /tmp/edge-backup.tar.gz \
    -C / opt/docker/tb-edge-data \
    -C / opt/docker/prometheus-agent \
    -C / opt/docker/promtail
```

### 6.4 Container start commands (realidad medida)

```
tb-edge-v2:
  image:      thingsboard/tb-edge:4.3.1.1EDGE
  cmd:        [start-tb-edge.sh]
  network:    host
  restart:    unless-stopped
  binds:      /opt/docker/tb-edge-data:/data

tb-edge-postgres:
  image:      postgres:15-alpine
  cmd:        [postgres]
  entrypoint: [docker-entrypoint.sh]
  network:    bridge          # ← OJO: bridge, no host (escucha sólo en 127.0.0.1:5432 vía PG_LISTEN)
  restart:    unless-stopped
  binds:      /opt/docker/tb-edge-data/db:/var/lib/postgresql/data
  env:        POSTGRES_DB=thingsboard_edge
              POSTGRES_USER=postgres
              POSTGRES_PASSWORD=postgres   # ← cambiar por edge en producción
              PGDATA=/var/lib/postgresql/data

edge-prom-agent:
  image:      prom/prometheus:latest
  cmd:        --config.file=/etc/prometheus/prometheus.yml
              --web.listen-address=0.0.0.0:9092
              --storage.tsdb.path=/prometheus
              --storage.tsdb.retention.time=7d
  network:    host
  restart:    unless-stopped
  binds:      /opt/docker/prometheus-agent/prometheus-agent.yml:/etc/prometheus/prometheus.yml:ro

promtail:
  image:      grafana/promtail:3.0.0
  cmd:        [-config.file=/etc/promtail/promtail.yml]
  network:    host
  restart:    unless-stopped
  binds:      /opt/docker/promtail/promtail.yml:/etc/promtail/promtail.yml:ro
              /var/log:/var/log:ro
```

### 6.5 prometheus-agent.yml (mount actual)

```yaml
# /opt/docker/prometheus-agent/prometheus-agent.yml
global:
  scrape_interval: 15s
  external_labels:
    cluster: edge
    node: raspberry-pi          # → cambiar por $EDGE_HOSTNAME en deploy nuevo
    location: edge-openwrt

scrape_configs:
  - job_name: openwrt_system
    static_configs:
      - targets: ["192.168.1.111:9100"]    # → $EDGE_LAN_IP:9100  (OpenWrt node-exporter-lua)
        labels: { device: raspberry-pi, os: openwrt }

  - job_name: prometheus_agent
    static_configs:
      - targets: ["127.0.0.1:9092"]

  - job_name: promtail
    static_configs:
      - targets: ["127.0.0.1:9080"]

remote_write:
  - url: "http://100.67.60.126:9090/api/v1/write"   # central Prometheus
    queue_config:
      max_samples_per_send: 1000
      batch_send_deadline: 5s
      min_backoff: 100ms
      max_backoff: 5s
    metadata_config:
      send: true
      send_interval: 1m
```

### 6.6 promtail.yml (mount actual)

```yaml
# /opt/docker/promtail/promtail.yml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push       # cambiar por la dirección del Loki central

scrape_configs:
  - job_name: system
    static_configs:
      - targets: [localhost]
        labels:
          job: varlogs
          __path__: /var/log/*log
```

### 6.7 Compose canónico (recomendado para nuevos edges)

Este edge no tiene un compose visible — los containers fueron creados con `docker run` directo. **Plantilla canónica para deploys nuevos:**

```yaml
# /etc/otbr/tb-edge-compose.yml — TEMPLATE (no instalado actualmente)
services:
  tb-edge:
    image: thingsboard/tb-edge:4.3.1.1EDGE
    container_name: tb-edge-v2
    restart: unless-stopped
    network_mode: host
    environment:
      CLOUD_RPC_HOST: ${CLOUD_RPC_HOST}
      CLOUD_RPC_PORT: ${CLOUD_RPC_PORT:-7070}
      CLOUD_ROUTING_KEY: ${CLOUD_ROUTING_KEY}
      CLOUD_ROUTING_SECRET: ${CLOUD_ROUTING_SECRET}
      HTTP_BIND_PORT: 8090
      MQTT_BIND_ADDRESS: 0.0.0.0
      MQTT_BIND_PORT: 1883
      LWM2M_SECURITY_BIND_PORT: 5684
      SPRING_DATASOURCE_URL: jdbc:postgresql://127.0.0.1:5432/thingsboard_edge
      SPRING_JPA_DATABASE_PLATFORM: org.hibernate.dialect.PostgreSQLDialect
    volumes:
      - /opt/docker/tb-edge-data:/data
    depends_on:
      - tb-edge-postgres

  tb-edge-postgres:
    image: postgres:15-alpine
    container_name: tb-edge-postgres
    restart: unless-stopped
    # bridge net: postgres only reachable via 127.0.0.1:5432 (matches reality)
    ports:
      - "127.0.0.1:5432:5432"
    environment:
      POSTGRES_DB: thingsboard_edge
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres        # ← cambiar por edge en producción
      PGDATA: /var/lib/postgresql/data
    volumes:
      - /opt/docker/tb-edge-data/db:/var/lib/postgresql/data

  edge-prom-agent:
    image: prom/prometheus:latest
    container_name: edge-prom-agent
    restart: unless-stopped
    network_mode: host
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --web.listen-address=0.0.0.0:9092
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=7d
    volumes:
      - /opt/docker/prometheus-agent/prometheus-agent.yml:/etc/prometheus/prometheus.yml:ro

  promtail:
    image: grafana/promtail:3.0.0
    container_name: promtail
    restart: unless-stopped
    network_mode: host
    command: [-config.file=/etc/promtail/promtail.yml]
    volumes:
      - /opt/docker/promtail/promtail.yml:/etc/promtail/promtail.yml:ro
      - /var/log:/var/log:ro
```

---

## 7. Service-discovery layer (mDNS + SRP)

### 7.1 mDNS para clientes LAN — `/etc/dnsmasq.conf`

dnsmasq reescribe queries para resolver el broker desde clientes que NO están en el mesh Thread:

```conf
# Direcciones del broker — ambos prefixes (mesh-local fdf5 y OMR fdee)
address=/thingsboard-edge.local/fdf5:bffd:bd6:ef74:eb7b:f1d1:874e:2b91
address=/thingsboard-edge.local/fdee:f43f:d8b2:1:1df:6a9:934e:99a5

# DNS-SD records (PTR + SRV + TXT) en .local
ptr-record=_mqtt._tcp.local,ThingsBoard-Edge._mqtt._tcp.local
srv-host=ThingsBoard-Edge._mqtt._tcp.local,thingsboard-edge.local,1883,0,0
txt-record=ThingsBoard-Edge._mqtt._tcp.local,"version=4.3.1","type=edge"

# DNS-SD records en default.service.arpa (espejo del SRP server) para clientes LAN
# que apunten su resolver a este nodo
address=/thingsboard-edge.default.service.arpa/fdf5:bffd:bd6:ef74:eb7b:f1d1:874e:2b91
address=/thingsboard-edge.default.service.arpa/fdee:f43f:d8b2:1:1df:6a9:934e:99a5
ptr-record=_mqtt._tcp.default.service.arpa,ThingsBoard-Edge._mqtt._tcp.default.service.arpa
srv-host=ThingsBoard-Edge._mqtt._tcp.default.service.arpa,thingsboard-edge.default.service.arpa,1883,0,0
txt-record=ThingsBoard-Edge._mqtt._tcp.default.service.arpa,"version=4.3.1","type=edge"
```

**Preservado** vía `/etc/sysupgrade.conf`.

### 7.2 avahi para clients .local en LAN — `/etc/avahi/services/thingsboard-mqtt.service`

```xml
<?xml version="1.0" standalone="no"?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">ThingsBoard Edge</name>
  <service>
    <type>_mqtt._tcp</type>
    <port>1883</port>
    <txt-record>version=4.3.1</txt-record>
    <txt-record>type=edge</txt-record>
    <txt-record>cloud=192.168.1.170:7070</txt-record>
  </service>
</service-group>
```

**Preservado** vía `/etc/sysupgrade.conf`.

### 7.3 SRP para clients dentro del Thread mesh

Manejado por el OTBR del propio edge. Ver §5.3. La registración inicial está hardcoded en `/etc/rc.local` (§8) — cuando migres al `otbr-srp` UCI-based (§4.8) el rc.local puede quedar limpio.

---

## 8. Boot scripts (`/etc/rc.local`)

```bash
#!/bin/sh -e

# 1. Reaplicar dataset si OT está disabled/detached al boot (ver script §8.1)
( sleep 8 && /etc/otbr/reapply-dataset.sh >> /tmp/otbr-reapply.log 2>&1 ) &

# 2. Registrar TB Edge en SRP (lo hace el central; nodos cliente sólo browsean)
( sleep 15 && \
  ot-ctl srp client host name thingsboard-edge && \
  ot-ctl srp client host address fdf5:bffd:bd6:ef74:eb7b:f1d1:874e:2b91 && \
  ot-ctl srp client service add ThingsBoard-Edge _mqtt._tcp 1883 0 0 && \
  ot-ctl srp client autostart enable ) >> /tmp/srp-thingsboard.log 2>&1 &

# 3. Subir router thresholds para mesh con 30+ nodos FTD (ver §5.6)
( sleep 12 && ot-ctl routerupgradethreshold 32 && ot-ctl routerdowngradethreshold 33 ) >> /tmp/otbr-router-thresholds.log 2>&1 &

exit 0
```

> **Recomendado migrar (§10.5)** la parte (2) al servicio `otbr-srp` (UCI-driven) para que sea declarativo y consultable vía LuCI.

### 8.1 `/etc/otbr/reapply-dataset.sh`

```bash
#!/bin/sh
TLV=$(cat /etc/otbr/active-dataset.tlvs)
STATE=$(ot-ctl state 2>/dev/null | head -1)
if [ "$STATE" = "disabled" ] || [ "$STATE" = "detached" ]; then
    echo "$(date): reapplying dataset (state=$STATE)"
    ot-ctl dataset set active $TLV
    ot-ctl ifconfig up
    ot-ctl thread start
else
    echo "$(date): Thread already running (state=$STATE), no action needed"
fi
```

---

## 9. Persistence — `/etc/sysupgrade.conf`

```
/etc/otbr/
/etc/rc.local
/etc/dnsmasq.conf
/etc/avahi/services/
```

Plus las defaults del firmware (`/etc/dropbear/`, `/etc/config/*`, etc.).

> **Importante para Docker**: `/opt/docker/` NO está en sysupgrade.conf. Si se usa `sysupgrade -n`, se borran TB-Edge data + Postgres. **Backup recomendado antes de reflashear**: `tar -czf /tmp/tb-edge-backup.tar.gz -C / opt/docker`. Restaurar después con `tar -xzf` y `docker compose up -d`.

---

## 10. Replay procedure — provisionar `edge-X` desde cero

### 10.1 Hardware

- Pi 4 (≥ 2 GiB RAM, recomendado 4 GiB) + microSD ≥ 16 GiB.
- EKH01 HaLow hat **o** R1000 carrier con WM6108 mPCIe (cambia `option path` y `option bcf` en §4.2).
- SiLabs ZONFF dongle USB para Thread RCP (en USB-A bus 2 si es R1000 — no bus 1 que va por LAN9512 con latencia que rompe Spinel).
- (Opcional pero recomendado) IP estática reservada en el DHCP del LAN para que el edge tenga `192.168.1.X` predecible.

### 10.2 Flash imagen base

Usar la imagen del repo correspondiente al hardware:
- EKH01 → `bin/targets/bcm27xx/bcm2711/openwrt-morse-2.9-dev-mm6108-ekh01-spi-squashfs-sysupgrade.img.gz`
- R1000+WM6108 → `bin/targets/bcm27xx/bcm2711/openwrt-morse-2.9-dev-recomputer-r1000-wm6108-spi-squashfs-sysupgrade.img.gz`

Boot inicial → uci-defaults aplican config base → SSH habilitado vía LAN.

### 10.3 Set hostname + agregar SSH key

```sh
ssh root@<EDGE_LAN_IP>
uci set system.@system[0].hostname='<EDGE_HOSTNAME>'
uci commit system
echo '<TU_PUBKEY>' >> /etc/dropbear/authorized_keys
/etc/init.d/dropbear restart
```

### 10.4 Aplicar dataset Thread (igual que el central)

```sh
mkdir -p /etc/otbr
cat > /etc/otbr/active-dataset.tlvs <<'EOF'
0e0800000000000100004a0300000f35060004001fffe002081a2578dd6ee3573b0708fdf5bffd0bd6ef7405105edebead64405b3e17193646c2942285010223ed0410bb7e7aee56236ea96ac8dc65bba183510c0402a0f7f8030b554e414c2d5468726561640003000019
EOF
chmod 600 /etc/otbr/active-dataset.tlvs

# Copiar reapply-dataset.sh de §8.1
cat > /etc/otbr/reapply-dataset.sh <<'EOF'
#!/bin/sh
TLV=$(cat /etc/otbr/active-dataset.tlvs)
STATE=$(ot-ctl state 2>/dev/null | head -1)
if [ "$STATE" = "disabled" ] || [ "$STATE" = "detached" ]; then
    ot-ctl dataset set active $TLV
    ot-ctl ifconfig up
    ot-ctl thread start
fi
EOF
chmod +x /etc/otbr/reapply-dataset.sh

# Aplicar inmediatamente
/etc/otbr/reapply-dataset.sh
```

### 10.5 Configurar SRP (declarativo via UCI)

```sh
uci set otbr-srp.config.enabled=1
uci set otbr-srp.thingsboard_edge.enabled=1
uci set otbr-srp.thingsboard_edge.name='ThingsBoard-Edge'
uci set otbr-srp.thingsboard_edge.type='_mqtt._tcp'
uci set otbr-srp.thingsboard_edge.port='1883'
uci set otbr-srp.thingsboard_edge.host='thingsboard-edge'
uci commit otbr-srp
/etc/init.d/otbr-srp enable
/etc/init.d/otbr-srp restart
```

> Si vas a tener **más de un edge** publicando el mismo servicio, usa nombres únicos (`R1000-Edge`, `Pi4-Edge`, etc.) o el SRP server rechazará el segundo registrante.

### 10.6 Levantar TB Edge stack (Docker)

```sh
mkdir -p /opt/docker/tb-edge-data /opt/docker/tb-edge-postgres-data /etc/otbr
cat > /etc/otbr/tb-edge.env <<EOF
CLOUD_RPC_HOST=192.168.1.170
CLOUD_RPC_PORT=7070
CLOUD_ROUTING_KEY=<TU_ROUTING_KEY>          # generado por TB CE al crear el edge
CLOUD_ROUTING_SECRET=<TU_ROUTING_SECRET>
EOF

# Plantilla compose en §6.4 — copiar a /etc/otbr/tb-edge-compose.yml y:
docker compose -f /etc/otbr/tb-edge-compose.yml --env-file /etc/otbr/tb-edge.env up -d
```

### 10.7 mDNS + dnsmasq inject (LAN side)

Reemplazar `<TB_EDGE_THREAD_ADDR>` por la dirección OMR de wpan0 del edge (sale de `ot-ctl ipaddr | grep -E "^fdf5"` la línea que empieza con un host ID, no `0:ff:fe00:`):

```sh
cat >> /etc/dnsmasq.conf <<'EOF'
address=/thingsboard-edge.local/<TB_EDGE_THREAD_ADDR>
ptr-record=_mqtt._tcp.local,ThingsBoard-Edge._mqtt._tcp.local
srv-host=ThingsBoard-Edge._mqtt._tcp.local,thingsboard-edge.local,1883,0,0
txt-record=ThingsBoard-Edge._mqtt._tcp.local,"version=4.3.1","type=edge"
EOF
/etc/init.d/dnsmasq restart

cat > /etc/avahi/services/thingsboard-mqtt.service <<'EOF'
<?xml version="1.0" standalone="no"?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">ThingsBoard Edge</name>
  <service>
    <type>_mqtt._tcp</type>
    <port>1883</port>
    <txt-record>version=4.3.1</txt-record>
    <txt-record>type=edge</txt-record>
  </service>
</service-group>
EOF
/etc/init.d/avahi-daemon restart
```

### 10.8 Persistencia — `/etc/sysupgrade.conf`

```sh
cat > /etc/sysupgrade.conf <<'EOF'
/etc/otbr/
/etc/rc.local
/etc/dnsmasq.conf
/etc/avahi/services/
EOF
```

### 10.9 Validación

```sh
# Thread up + dataset correct
ot-ctl state                          # → leader/router/child
ot-ctl networkname                    # → UNAL-Thread

# Border routing
ot-ctl br state                       # → running
ot-ctl br omrprefix                   # → fdee:f43f:d8b2:1::/64

# SRP — ver el servicio publicado por este edge
ot-ctl srp client service             # → state:Registered

# Browse desde otro nodo Thread (debería verse desde cualquier R1000)
ot-ctl dns browse _mqtt._tcp.default.service.arpa

# TB Edge respondiendo
curl -fs -o /dev/null http://localhost:8090/login && echo "TB UI ok"
mosquitto_sub -h localhost -t '$SYS/broker/version' -C 1 -W 5 || true

# LuCI Thread → SRP page debería listar los servicios + permitir browse
echo "abrir http://<EDGE_LAN_IP>/cgi-bin/luci/admin/network/thread → botón SRP"
```

---

## 11. Health checks recurrentes

Agendar (cron del edge o monitor externo):

```sh
# Thread sano
ot-ctl state                 # esperar leader/router/child, NUNCA disabled/detached
ot-ctl br state              # esperar running

# OMR address pinned by addr-guard
ip -6 addr show dev wpan0 | grep "preferred_lft forever" || \
    echo "WARN: OMR not pinned"

# TB Edge alive
docker ps --filter name=tb-edge-v2 --format '{{.Status}}' | grep -q "^Up" || \
    echo "WARN: tb-edge container down"

# SRP server alive
ot-ctl srp server state | grep -q running || \
    echo "WARN: SRP server not running"
```

---

## 12. Decisiones / TODOs abiertos

- [ ] Migrar registración SRP en `/etc/rc.local` → UCI `otbr-srp` (§4.8 + §10.5). El UCI ya está en el firmware; falta sustituir el bloque manual.
- [ ] Versionar `/etc/otbr/tb-edge-compose.yml` y `/etc/otbr/tb-edge.env.example` en el repo y bake-in vía paquete o uci-defaults.
- [ ] Documentar el procedimiento de rotación de Thread Network Key (cuándo + cómo + impacto a sleeps).
- [ ] Postgres backup automatizado de `tb-edge-postgres` antes de reboot/sysupgrade.
- [ ] Si en el futuro hay >1 edge publicando MQTT, decidir si:
  - cada edge se announce con instance-name diferente (`R1000-Edge`, etc.) y el cliente elige
  - O sólo uno de los edges es el "MQTT primary" y los otros publican como fallback con `priority` DNS-SD distinto (campo `priority` en SRP service).

---

## 13. Apéndice — comandos para extraer este snapshot

Si quieres re-extraer el estado actual de cualquier edge para regenerar este documento:

```sh
ssh root@<EDGE_LAN_IP> '
    echo "## identity"; uci get system.@system[0].hostname; cat /tmp/sysinfo/board_name; uname -r
    echo "## net"; ip -br link; ip -4 -br addr; ip -6 -br addr; brctl show
    echo "## uci"; for c in network wireless firewall dhcp system otbr-agent otbr-network otbr-srp; do echo "---$c---"; uci export $c; done
    echo "## thread"; ot-ctl state; ot-ctl networkname; ot-ctl dataset active; ot-ctl br state; ot-ctl br omrprefix
    echo "## srp"; ot-ctl srp server state; ot-ctl srp server service; ot-ctl srp client host; ot-ctl srp client service
    echo "## docker"; docker ps -a; for c in $(docker ps --format "{{.Names}}"); do docker inspect "$c"; done
    echo "## persist"; cat /etc/rc.local; cat /etc/dnsmasq.conf; cat /etc/sysupgrade.conf
    echo "## otbr-files"; ls /etc/otbr/; for f in /etc/otbr/*; do echo "--- $f"; cat "$f"; done
    echo "## avahi"; for f in /etc/avahi/services/*.service; do echo "--- $f"; cat "$f"; done
'
```
