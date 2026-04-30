# Runbook — ThingsBoard Edge baseline tuning

**Cuándo usar este runbook:**
- El edge se siente lento (HTTP de LuCI lento, comandos `ot-ctl` lentos)
- TB Edge container reporta CPU >80% sostenido o RAM libre <100 MB
- Postgres acumula conexiones idle o D-state
- Vas a meter más carga (más nodos, más telemetría) y quieres preparar el baseline antes

**Cuándo NO usar este runbook:**
- TB Edge no arranca → es problema de credenciales/datos, no de tuning
- Mesh Thread con churn → ver [`thread-mesh-health.md`](thread-mesh-health.md), no es problema de TB Edge
- Disco lleno (`df -h /opt/docker`) → primero liberar espacio, después tunear

**Pre-condiciones:**
- SSH al edge con root
- `docker` y `docker exec` accesibles
- Conocer el password de postgres (default `postgres` en este deployment, ver `architecture/edge-thingsboard.md §6.4`)

---

## 1. Triage rápido (3 min)

### 1.1 Memoria del host

```sh
free -m
```

| Free RAM | Diagnóstico |
|---|---|
| > 500 MB | Sano. Si hay síntoma de lentitud, el problema NO es RAM — pasar a §1.2 |
| 100-500 MB | Aceptable, sin margen para spikes. Considerar §3.1 |
| < 100 MB | **Crítico** — sin swap configurado, próximo OOM. Aplicar §3.1 inmediatamente |

> **Nota:** "Available" en `free -m` es lo que importa, no "Used". Linux usa el resto en buff/cache que se libera bajo presión. Solo Available <500MB es señal real de presión.

### 1.2 Snapshot de containers

```sh
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.BlockIO}}'
```

Expectativas en idle (sin carga LwM2M / MQTT):

| Container | CPU% normal | Memoria | Síntoma de problema |
|---|---|---|---|
| `tb-edge-v2` | 5-15% | 1.0-1.5 GB RSS | sostenido >50% o RSS >2 GB |
| `tb-edge-postgres` | 2-10% | depende de queries | sostenido >100% (un core entero) |
| `edge-prom-agent` | 0-2% | ~50 MB | n/a |
| `promtail` | 0-2% | ~30 MB | n/a |

> **Importante:** `docker stats` sin `--no-stream` da el promedio de los últimos 2s. Un único snapshot puede ser engañoso si captura un GC pause o un burst de telemetría. Repetir 3 veces con 30s entre samples para confirmar tendencia sostenida.

### 1.3 Carga del sistema

```sh
uptime
# Para Pi 4 (4 cores), load average sano:
#   <1.0  → idle
#   1-2   → trabajo normal
#   2-4   → carga alta pero ok
#   >4    → saturado
```

---

## 2. Diagnóstico profundo

### 2.1 Postgres — conexiones idle y queries activas

```sh
docker exec tb-edge-postgres psql -U postgres -d thingsboard_edge -c \
    "select state, count(*) from pg_stat_activity group by state;"
```

| State | Cantidad esperada | Diagnóstico si excede |
|---|---|---|
| `active` | 0-5 | >10 sostenido → TB Edge bombardeando queries lentos |
| `idle` | 5-20 | >30 → connection pool sobre-dimensionado |
| `idle in transaction` | 0 | **>0 sostenido es bug** — TB Edge dejando transactions abiertas |

Para queries lentos:

```sh
docker exec tb-edge-postgres psql -U postgres -d thingsboard_edge -c \
    "select pid, state, wait_event_type, wait_event,
            now()-query_start as dur, left(query,80)
     from pg_stat_activity
     where state != 'idle'
     order by query_start
     limit 10;"
```

Si ves queries con `dur > 5s` repetidamente, es síntoma de:
- Tabla sin índice apropiado (raro — TB Edge schema viene tuneado)
- Disk IO saturado (SD card lenta) — verificar §2.3
- Lock contention — `select count(*) from pg_locks where not granted;` debe ser 0

### 2.2 TB Edge — JVM

```sh
TB_PID=$(pgrep -f 'tb-edge.jar' | head -1)
cat /proc/$TB_PID/status | grep -E 'VmRSS|VmSize|Threads|voluntary'
```

| Métrica | Valor sano | Alarma |
|---|---|---|
| `VmRSS` (memoria real) | 1.0-1.5 GB | >2 GB sostenido |
| `VmSize` (reservada) | 5-6 GB | (cosmético, no aloca) |
| `Threads` | 200-260 | >300 sin razón clara |

JVM gc log (si está habilitado):

```sh
docker exec tb-edge-v2 sh -c 'tail -5 /var/log/tb-edge/gc.log 2>/dev/null'
```

Buscar líneas `Pause Young (G1 Evacuation)` con tiempo. Pauses >500ms sostenidos indican heap presión.

### 2.3 Disco SD — IO sostenido

```sh
# Snapshot ts1
awk '/mmcblk0p2/{print $4, $8}' /proc/diskstats > /tmp/io_t1
sleep 60
awk '/mmcblk0p2/{print $4, $8}' /proc/diskstats > /tmp/io_t2
paste /tmp/io_t1 /tmp/io_t2 | awk '{
    print "reads/min:", ($3-$1)
    print "writes/min:", ($4-$2)
}'
```

Pi 4 con SD card típica:

| Writes/min | Diagnóstico |
|---|---|
| < 100 | Idle, sin presión |
| 100-1000 | Carga normal de TB Edge en idle (postgres autovacuum + WAL) |
| 1000-10000 | Telemetría intensa, sostenible |
| > 10000 | **Riesgo de wear acelerado**. Considerar mover postgres a USB SSD. |

Dirty pages:

```sh
awk '/Dirty:|Writeback:/' /proc/meminfo
# Dirty grande sostenido → IO no drena, SD lenta
```

### 2.4 Tráfico de red en host

```sh
# 30s de muestra
ip -s link show eth0 | head -10
sleep 30
ip -s link show eth0 | head -10
```

Comparar `RX bytes` y `TX bytes`. Para TB Edge en idle: <1 MB/min normal. >10 MB/min indica carga de TB Cloud sync (`tb-edge-v2` syncing con TB Cloud central) o promtail forwardeando logs.

---

## 3. Acciones operativas

### 3.1 Liberar RAM rápido (sin restart de servicios críticos)

Pausar containers no críticos para diagnóstico/baseline:

```sh
docker stop edge-prom-agent promtail
```

**Efecto medido en este edge (2026-04-27):** liberó ~80 MB de RAM, redujo CPU baseline en ~3%.

Para reactivar después:

```sh
docker start edge-prom-agent promtail
```

> **Trade-off:** mientras estén apagados, no hay métricas push a Prometheus central ni logs push a Loki. Si tu observabilidad central depende de eso, no apagarlos en producción.

### 3.2 Postgres tuning vía SIGHUP (sin restart)

Aplicable: `work_mem`, `maintenance_work_mem`, `effective_cache_size`, `random_page_cost`, `autovacuum_vacuum_cost_delay`.
NO aplicable (requieren restart): `shared_buffers`, `max_connections`, `autovacuum_max_workers`.

```sh
# Aplicar uno por uno (psql -c con varios statements falla por "ALTER SYSTEM cannot run in transaction")
for s in \
  "work_mem='2MB'" \
  "maintenance_work_mem='32MB'" \
  "effective_cache_size='1GB'" \
  "random_page_cost=1.5" \
  "autovacuum_vacuum_cost_delay='20ms'"; do
    docker exec tb-edge-postgres psql -U postgres -d thingsboard_edge -c "ALTER SYSTEM SET $s;"
done
docker exec tb-edge-postgres psql -U postgres -d thingsboard_edge -c "SELECT pg_reload_conf();"

# Verificar
docker exec tb-edge-postgres psql -U postgres -d thingsboard_edge -c \
    "select name, setting, unit from pg_settings
     where name in ('work_mem','maintenance_work_mem','effective_cache_size','random_page_cost')
     order by name;"
```

**Aplicado en `192.168.1.111` (2026-04-27).** Effecto medido: marginal en idle (postgres ya estaba en 4-7% CPU), pero protege headroom para spikes.

### 3.3 TB Edge — restringir JVM heap

> **Disruptivo** — los 30+ nodos LwM2M van a perder sesión durante ~30-60s del restart.
> Solo aplicar si hay evidencia clara de presión (RSS sostenido >1.8 GB o GC pauses frecuentes).

```sh
docker stop tb-edge-v2
docker rm tb-edge-v2
docker run -d --name tb-edge-v2 \
    --network host \
    --restart unless-stopped \
    -v /opt/docker/tb-edge-data:/data \
    -e JAVA_OPTS="-Xms768m -Xmx1280m -XX:+UseG1GC -XX:MaxGCPauseMillis=200" \
    -e <todas las demás env vars del original — sacarlas con docker inspect> \
    thingsboard/tb-edge:4.3.1.1EDGE
```

> **Antes de hacer esto:**
> 1. `docker inspect tb-edge-v2 | jq '.[0].Config.Env'` para sacar todas las env vars
> 2. Documentar el comando completo en `architecture/edge-thingsboard.md §6.2`
> 3. Hacer en ventana de mantenimiento

**No aplicado en este edge** — el RSS de 1.32 GB sostenido no justifica el restart. Documentado solo como referencia preventiva.

### 3.4 Postgres — restart completo (si requirió shared_buffers o max_connections)

> **Disruptivo** — TB Edge perderá la conexión a postgres durante ~10-20s y va a re-conectar. Las sesiones LwM2M activas en TB Edge sobreviven (TB Edge tiene buffer interno) pero las queries pendientes pueden fallar.

```sh
# Aplicar configs que requieren restart
docker exec tb-edge-postgres psql -U postgres -d thingsboard_edge -c \
    "ALTER SYSTEM SET shared_buffers='96MB';"
docker exec tb-edge-postgres psql -U postgres -d thingsboard_edge -c \
    "ALTER SYSTEM SET max_connections=50;"

docker restart tb-edge-postgres
sleep 10
docker exec tb-edge-postgres pg_isready -U postgres
```

### 3.5 Limpiar telemetría histórica (si /opt/docker se llena)

> **Destructivo — borra datos.** Solo usar si confirmas que la retención necesaria ya pasó.

```sh
# Ver tamaño actual
docker exec tb-edge-postgres psql -U postgres -d thingsboard_edge -c \
    "select pg_size_pretty(pg_database_size('thingsboard_edge'));"

# Borrar telemetría >30 días (TB Edge debería hacer esto pero a veces se atrasa)
docker exec tb-edge-postgres psql -U postgres -d thingsboard_edge -c \
    "delete from ts_kv where ts < (extract(epoch from now()-interval '30 days')*1000)::bigint;"

# Vacuum agresivo para liberar espacio en disco
docker exec tb-edge-postgres psql -U postgres -d thingsboard_edge -c \
    "vacuum full ts_kv;"
```

`vacuum full` lockea la tabla — hacer en ventana.

---

## 4. Casos canónicos de fallo

### 4.1 "El edge se siente lento, pero TB Edge dice que va bien"

**Síntomas:**
- HTTP de LuCI tarda >5s en responder
- `ot-ctl` toma 1-2s en lugar de instantáneo
- `docker stats` muestra TB Edge en CPU% bajo (<20%)

**Probable causa:** uhttpd (servidor LuCI) bloqueado por procesos zombie de helpers de status. Revisar:

```sh
ps | grep -c '<defunct>'
ps | grep otbr-srp | wc -l    # si hay >5, hay pile-up
```

**Remediación:** ya está en el firmware (ver `build_deps/ot-br-posix/src/openwrt/otbr-srp-status` con flock). Si vuelve a aparecer, verificar que ese script tenga el guard de single-instance.

### 4.2 "TB Edge OOM-kill durante un spike"

**Síntomas:**
- `dmesg | grep -i 'killed process'` muestra entries recientes
- Container `tb-edge-v2` reiniciado por docker (ver `docker ps -a` con tiempo distinto al expected)
- TB Edge JVM RSS había llegado a >2 GB antes del kill

**Remediación:**
1. Aplicar §3.1 (apagar prom-agent + promtail) para ganar 80 MB
2. Aplicar §3.3 con `-Xmx1280m` para acotar heap

**Prevención:** monitorear con alerta si `free -m` baja de 100 MB sostenido.

### 4.3 "Postgres consumiendo CPU >100% sostenido"

**Síntomas:**
- `docker stats` reporta `tb-edge-postgres` >100% CPU sostenido (>5 min)
- Queries en `pg_stat_activity` con dur >10s

**Causas probables:**
- Autovacuum agresivo en una tabla grande (`ts_kv` típicamente)
- TB Edge bombardeando queries N+1 por bug de versión

**Diagnóstico:**

```sh
docker exec tb-edge-postgres psql -U postgres -d thingsboard_edge -c \
    "select relname, n_live_tup, n_dead_tup, last_autovacuum
     from pg_stat_user_tables
     where n_dead_tup > 1000
     order by n_dead_tup desc limit 10;"
```

Si `ts_kv` o `attribute_kv` tienen `n_dead_tup` muy alto, es presión de autovacuum.

**Remediación:**
- Forzar `vacuum analyze` manualmente fuera de horas de carga
- Ajustar `autovacuum_naptime`, `autovacuum_vacuum_scale_factor` según carga

---

## 5. Métricas de salud — definir SLOs

Para definir cuándo "el edge está sano":

| Métrica | SLO objetivo | Cómo medir |
|---|---|---|
| Free RAM (5 min avg) | > 100 MB | `free -m` |
| Available RAM (5 min avg) | > 1.5 GB | `free -m` |
| Load avg (5 min) | < 2.0 | `uptime` |
| Postgres CPU | < 30% sostenido | `docker stats` |
| TB Edge CPU | < 30% sostenido | `docker stats` |
| TB Edge JVM RSS | < 1.5 GB sostenido | `cat /proc/<pid>/status` |
| LwM2M devices `active_<2min` | ≥ 95% del total | `select bucket, count(*) from ts_kv...` (ver §1.5 de thread-mesh-health.md) |
| MAC counters errors (60s sample) | 0 retry/abort/CCA | `ot-ctl counters mac` |

Si todos los SLOs se cumplen sostenidamente, el edge está sano para su carga actual y tiene margen para spikes.

---

## 6. Reportar resultados

Después de aplicar cambios, capturar evidencia en `architecture/snapshots/edge-<IP>-<DATE>-baseline-tuning.txt`:

```sh
EDGE_IP=192.168.1.111
DATE=$(date +%Y-%m-%d)

ssh root@$EDGE_IP "$(cat <<'EOF'
echo '## free'; free -m
echo '## load'; uptime
echo '## docker'; docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'
echo '## postgres connections'; docker exec tb-edge-postgres psql -U postgres -d thingsboard_edge -c "select state,count(*) from pg_stat_activity group by state;"
echo '## postgres settings (post-tune)'; docker exec tb-edge-postgres psql -U postgres -d thingsboard_edge -c "select name,setting,unit from pg_settings where name in ('work_mem','maintenance_work_mem','effective_cache_size','random_page_cost','shared_buffers','max_connections') order by name;"
echo '## tb-edge env'; docker exec tb-edge-v2 sh -c 'env | grep -E "JAVA_OPTS|XMX|XMS"'
EOF
)" > docs/architecture/snapshots/edge-${EDGE_IP}-${DATE}-baseline-tuning.txt
```

---

## 6.5 TB CE auto-genera prefix/sufijo random en `resourceKey` y `device.name`

> **Trampa repetible**. Aplica tanto a Pi 4 como R1000 — solo se manifiesta cuando el caller no especifica el key/name explícito o cuando hay name conflict.

### Síntomas

| Entity | Síntoma | Resultado broken |
|---|---|---|
| `device.name` | POST `/api/device` con name que ya existe | `ami-esp32c6-1494` → `ami-esp32c6-1494_<14char_random>` |
| `resourceKey` (LWM2M_MODEL) | POST `/api/resource` sin pasar `resourceKey` explícito | `10242_1.0` → `<15char_random>_10242_1.0` |

Síntoma observable en runtime:

```
ERROR Tenant hasn't such the resource: Object model with id [10242] version [1.0]
```

LwM2mVersionedModelProvider falla parsing TLVs porque busca el key canónico pero TB Edge tiene `<random>_10242_1.0`. Resultado: nodo aparece `Active` pero **0 telemetría se persiste a timeseries**.

### Detección

```sh
# Drift check: cualquier resourceKey con prefix random?
TOKEN=$(curl -s -X POST http://127.0.0.1:8090/api/auth/login \
    -H 'Content-Type: application/json' \
    -d '{"username":"tenant@thingsboard.org","password":"tenant"}' \
    | sed 's/.*"token":"\([^"]*\)".*/\1/')

curl -s -H "X-Authorization: Bearer $TOKEN" \
    'http://127.0.0.1:8090/api/resource?pageSize=50&page=0' \
    | sed 's/{/\n{/g' \
    | grep -oE '"resourceKey":"[^"]*"' \
    | grep -E '"[A-Za-z0-9]{14,16}_[0-9]+_'
# Sin output = OK; output = devices con prefix random a limpiar
```

```sh
# Drift check devices con sufijo random
curl -s -H "X-Authorization: Bearer $TOKEN" \
    'http://127.0.0.1:8090/api/tenant/devices?pageSize=100&page=0' \
    | sed 's/{/\n{/g' \
    | grep -oE '"name":"[^"]*_[A-Za-z0-9]{14,16}"'
```

### Fix manual (resource broken)

```sh
# 1. Get the broken resource (tiene `data` field con base64 del XML)
RES_ID="<broken-resource-uuid>"
curl -s -H "X-Authorization: Bearer $TOKEN" \
    "http://127.0.0.1:8090/api/resource/$RES_ID" > /tmp/broken-res.json

XML_DATA=$(sed 's/.*"data":"\([^"]*\)".*/\1/' /tmp/broken-res.json)

# 2. DELETE broken
curl -s -X DELETE -H "X-Authorization: Bearer $TOKEN" \
    "http://127.0.0.1:8090/api/resource/$RES_ID"

# 3. POST clean con resourceKey explícito
cat > /tmp/new-res.json <<EOF
{
  "title": "3-Phase Power Meter id=10242 v1.0",
  "resourceType": "LWM2M_MODEL",
  "resourceKey": "10242_1.0",
  "fileName": "10242.xml",
  "data": "$XML_DATA"
}
EOF
curl -s -X POST -H "X-Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' -d @/tmp/new-res.json \
    'http://127.0.0.1:8090/api/resource'
```

### Prevención (cliente-side)

| Patrón broken | Patrón correcto |
|---|---|
| Upload via UI multipart-form sin pasar resourceKey | POST JSON con `"resourceKey": "<canonical>"` explícito |
| `provision_node.py` con retry-on-error sin idempotency check | Buscar device existente con `GET /api/device/credentials?credentialsId=<endpoint>`, reusar; o `DELETE` + recreate |
| Auto-create del LwM2M handler al recibir REGISTER de device desconocido | Pre-registrar device + credentials antes del REGISTER del nodo |

### NOTA IMPORTANTE — el bug NO es local del edge, es de TB Central multi-edge

**Hallazgo 2026-04-29**: Cuando un device con el mismo `name` ya existe en otro edge del mismo tenant en TB Central, el `POST /api/device` al edge nuevo es **silenciosamente renombrado** con suffix random (`<canonical>_<14char>`). Esto ocurre incluso si el device "duplicate" está en otro edge — TB Central enforces global uniqueness del `device.name` dentro del tenant.

**Test rápido para confirmar**:

```sh
# En TB Central, buscar si el name canónico ya existe:
curl -s -H "X-Authorization: Bearer $C_TOKEN" \
    "http://<TB_CENTRAL>:8080/api/tenant/devices?pageSize=10&page=0&textSearch=<canonical_name>"
# Si aparece otro device con el mismo name → causa del rename
```

**Fix correcto: re-assign device en lugar de duplicar**

Si el device `ami-esp32c6-XXXX` ya existe en TB Central asignado a Pi4 edge y quieres moverlo a R1000:

```sh
PI4_EDGE='a0d51540-3377-11f1-a6bc-0324a9cfbb29'
R1000_EDGE='b1a230c0-432a-11f1-be42-ff951e684f01'
DEV_ID='<existing-canonical-device-uuid>'

# 1. Borrar device duplicado (con suffix) si existe en R1000:
curl -X DELETE -H "X-Authorization: Bearer $C_TOKEN" \
    "http://<TB_CENTRAL>:8080/api/device/<suffixed-uuid>"

# 2. Unassign canonical de Pi4:
curl -X DELETE -H "X-Authorization: Bearer $C_TOKEN" \
    "http://<TB_CENTRAL>:8080/api/edge/$PI4_EDGE/device/$DEV_ID"

# 3. Assign canonical a R1000:
curl -X POST -H "X-Authorization: Bearer $C_TOKEN" \
    "http://<TB_CENTRAL>:8080/api/edge/$R1000_EDGE/device/$DEV_ID"

# 4. Esperar ~15s para sync gRPC. R1000 ahora tiene el device canonical.
```

**Implicación operacional**: cada nodo físico debe tener **un solo device en TB Central**, asignado al edge donde está actualmente. Cuando un nodo migra (Pi4 → R1000), unassign del edge viejo + assign al nuevo. Esto:

- ✅ Conserva el UUID del device (history, attributes, telemetry intacto)
- ✅ Evita el suffix random
- ✅ Evita el problema del LwM2M handler creando devices duplicate

**Para `provision_node.py` (cliente-side)**: idempotency check debe consultar **TB Central** por el name canónico ANTES de POST al edge. Si existe en otro edge, hacer un re-assign en lugar de POST nuevo.

```python
def provision_or_reassign(endpoint, target_edge_id, central_url, central_token):
    # 1. Check if device exists in Central
    r = requests.get(f"{central_url}/api/tenant/devices?textSearch={endpoint}",
                     headers={"X-Authorization": f"Bearer {central_token}"})
    for dev in r.json().get('data', []):
        if dev['name'] == endpoint:
            # Found canonical — re-assign to target edge
            dev_id = dev['id']['id']
            requests.post(f"{central_url}/api/edge/{target_edge_id}/device/{dev_id}",
                          headers={"X-Authorization": f"Bearer {central_token}"})
            return dev_id  # done — no creation needed
    # 2. Doesn't exist — create at edge level (current behavior)
    ...
```

### Por qué pasa más visible en R1000 que Pi 4

Pi 4 tuvo más tiempo para que sus devices estuvieran sincronizados con TB Central. R1000 es nuevo + tuvo el firewall cerrado los primeros días → flow LwM2M con timeouts → retries del client → name conflicts encadenados → many devices con suffixes.

---

## 7. Referencias

- Spec del edge: [`../architecture/edge-thingsboard.md §6`](../architecture/edge-thingsboard.md)
- Postgres tuning docs: https://www.postgresql.org/docs/15/runtime-config.html
- TB Edge docs (env vars, JVM): https://thingsboard.io/docs/edge/
- Mesh-side troubleshooting: [`thread-mesh-health.md`](thread-mesh-health.md)
