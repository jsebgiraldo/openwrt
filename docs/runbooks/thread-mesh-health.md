# Runbook — Thread mesh health diagnosis

**Cuándo usar este runbook:**
- Sospechas que la mesh está churning (re-attaches frecuentes, sesiones LwM2M flapping en TB Edge)
- TB Edge reporta devices marcados inactivos pero "deberían estar conectados"
- El edge se siente lento y quieres descartar congestión 802.15.4 antes de tocar TB Edge
- Quieres validar antes/después de un cambio de config en el OTBR (e.g., subir thresholds)

**Cuándo NO usar este runbook:**
- TB Edge fully down o postgres en crash → ver [`tb-edge-baseline-tuning.md`](tb-edge-baseline-tuning.md)
- LwM2M no funciona pero la mesh está sana → es problema de transport, no de Thread
- Bug de firmware en los nodos → este runbook valida el OTBR, no el firmware del nodo

**Pre-condiciones:**
- SSH al edge (`ssh root@<EDGE_IP>`)
- `ot-ctl` disponible (verificar con `which ot-ctl`)
- Nodos provisionados en TB Edge para correlación final

**Decisión arquitectural relevante:** [`docs/decisions/thread-mesh-role-assignment.md`](../decisions/thread-mesh-role-assignment.md)

---

## 1. Triage rápido (5 min)

### 1.1 Estado básico del OTBR

```sh
ot-ctl state           # debe ser: leader, router, o child
ot-ctl networkname     # debe coincidir con el dataset esperado (e.g., UNAL-Thread)
ot-ctl partitionid     # debe ser estable entre samples
ot-ctl br state        # debe ser: running
```

| Síntoma | Diagnóstico |
|---|---|
| `state=disabled` | OTBR no arrancó. `service otbr-agent status`. Verificar `/dev/ttyUSB*` y baudrate en `/etc/config/otbr-agent`. |
| `state=detached` | OTBR perdió la mesh. Probable: dataset corrupto o RCP desconectado. Revisar `journalctl -u otbr-agent` (si está en docker, `docker logs otbr-agent`). |
| `partitionid` cambia entre samples | Mesh se está reformando. Indica problema serio (RCP intermitente, interferencia). Pasar a §3. |
| `br state=stopped` | Border routing apagado. `ot-ctl br enable`. |

### 1.2 Tamaño de la mesh

```sh
echo "routers:    $(ot-ctl router table 2>/dev/null | grep -c '0x[0-9a-f]')"
echo "neighbors:  $(ot-ctl neighbor table 2>/dev/null | grep -c '0x[0-9a-f]')"
echo "children:   $(ot-ctl child table 2>/dev/null | grep -c '0x[0-9a-f]')"
```

> **Nota importante:** `ot-ctl child table` muestra solo los **children directos del leader**, no los children de otros routers. Para un mesh de 30 nodos con 17 routers, `child table` podría mostrar 0 — los demás están atrás de los routers, no del leader.

### 1.3 Thresholds actuales

```sh
ot-ctl routerupgradethreshold       # default OpenThread: 16
ot-ctl routerdowngradethreshold     # default OpenThread: 23
```

Si tu mesh > 16 nodos REED y los thresholds están en defaults → estás churning. Ver §4.1.

---

## 2. Diagnóstico profundo (30-60 min)

### 2.1 Histórico de eventos de routing

```sh
ot-ctl history router 100
```

Estructura del output:

```
| Age          | Event          | ID (RLOC16) | Next Hop    | Path Cost  |
|              | CostChanged    | 13 (0x3400) | 13 (0x3400) | 1 -> 2     |
|              | NextHopChanged | 49 (0xc400) | 33 (0x8400) | 2 -> 2     |
|              | Added          | 16 (0x4000) | none        | inf -> inf |
```

**Interpretación:**

| Evento | Qué significa | Cuándo es normal | Cuándo es síntoma |
|---|---|---|---|
| `Added` (con MAC válido) | Router nuevo se unió a la mesh | Tras boot o factory reset de un nodo | **Mismo MAC re-Added 2-3 veces en 30 min → churn** |
| `CostChanged` | El costo de ruta a ese router cambió | Esporádico tras carga radio variable | **Múltiples por minuto sostenido → contention** |
| `NextHopChanged` | El next-hop hacia ese router cambió | Tras un Added/Removed cercano | **Constante sin Added → routing oscillation** |
| `Removed` | Router perdido de la tabla | Tras factory reset / shutdown | **Frecuente con mismo MAC → flapping** |

Heurística rápida: si en `history router 100` ves más de 3 `Added` del mismo Extended MAC, es churn confirmado.

### 2.2 Histórico de eventos de neighbor

```sh
ot-ctl history neighbor 50
```

Mismo principio: re-Added del mismo MAC indica que el nodo pierde y recupera el link constantemente.

### 2.3 MAC counters delta

Esta es la prueba **canónica** para confirmar contention 802.15.4. Es un sample con reset:

```sh
ot-ctl counters mac reset
sleep 60
ot-ctl counters mac
```

Counters relevantes (en 60s):

| Counter | Significado | Valor objetivo (mesh sana) | Valor de alarma |
|---|---|---|---|
| `TxTotal` | Paquetes intentados transmitir | >> 0 (depende de carga) | (n/a, es referencia) |
| `TxRetry` | Retransmisiones por NACK | 0-10 | >50 sostenido |
| `TxErrCca` | Carrier-Sense Multiple Access falló (canal ocupado) | 0-3 | >10 |
| `TxErrBusyChannel` | Backoff hit max sin canal libre | 0-3 | >10 |
| `TxErrAbort` | Tx abortado (reset o timeout) | 0 | >5 |
| `TxDirectMaxRetryExpiry` | **Max retries hit → packet drop** | 0 | **cualquier valor >0 sostenido es síntoma serio** |
| `RxErrFcs` | CRC inválido (interferencia / colisión) | 0 | >0 |
| `RxErrNoUnknownNeighbor` | Recibido de neighbor desconocido | 0 | >10 |

### 2.3.5 Verificar SRP host registrado con `mleid` (NO `OMR`)

**Síntoma del bug**: nodos hacen `REGISTER` LwM2M exitoso (TB Edge los marca `Active`) pero **ningún `Update` ni `Notify` llega a TB Edge** después. Causa: el SRP host está publicado con la OMR del border router en lugar de la mleid → cuando TB Edge responde, el kernel selecciona `src=mleid` (longest-prefix-match contra el dst del nodo) que **no coincide con `peer-connected=OMR`** del socket UDP del cliente → drop por mismatch.

**Cómo verificar**:

```sh
# 1. Ver qué address tiene el SRP host
ot-ctl srp server service | grep -A2 'host:' | grep addresses

# 2. Compararlo con la mleid del border router
ot-ctl ipaddr mleid

# Si las direcciones NO coinciden → tienes este bug.
```

| Address en `addresses:` | Diagnóstico |
|---|---|
| Igual a `mleid` (`fdf1:...:2554` en R1000) | ✅ correcto |
| OMR (`fd67:...:b221` en R1000, prefijo `/64` distinto al mesh-local) | ❌ bug — re-registrar con mleid (ver §4.6) |
| Más de una address con OMR + mleid | ⚠️ funcional pero impredecible — limpiar a solo mleid |

**Detección preventiva**: ejecutar este script post-boot para alertar si hay drift:

```sh
EXPECTED=$(ot-ctl ipaddr mleid | head -1 | tr -d '\r')
PUBLISHED=$(ot-ctl srp server service | awk -F'[][]' '/addresses:/ {print $2; exit}')
[ "$EXPECTED" = "$PUBLISHED" ] \
    && echo "OK: SRP host publishes mleid ($EXPECTED)" \
    || echo "BUG: SRP host publishes [$PUBLISHED], expected [$EXPECTED]"
```

> El regex `[0-9a-f:]+` no funciona aquí porque las letras `a`/`d` matchean dentro de la palabra "addresses". Usar `awk -F'[][]'` que extrae todo entre los `[...]` literales del output `ot-ctl`.

### 2.4 Tráfico aplicación (LwM2M / CoAP / MQTT)

Para confirmar que el problema está en Thread y no en aplicación:

```sh
# Captura 60s de LwM2M
(tcpdump -i any -nn 'udp port 5683 and ip6' 2>&1 > /tmp/cap.txt) &
sleep 60
kill %1 2>/dev/null

# Unique sources
awk '/wpan0 In/{print $5}' /tmp/cap.txt | sed 's/\.[0-9]*$//' | sort -u | wc -l
```

Comparar con número de nodos esperados. Diferencia se explica por:

1. **Update interval del nodo** > 60s — captura más tiempo (300s) y revisa
2. **Nodo realmente detached** — confirmar con TB Edge `ts_kv_latest`
3. **Nodo perdió OMR address** — `ot-ctl ipaddr` debe listar OMR para los routers; los children obtienen vía RA del border router

### 2.5 Correlación con TB Edge

```sh
docker exec tb-edge-postgres psql -U postgres -d thingsboard_edge -c "
  with t as (select d.id, max(ts.ts) as last_ts
             from device d left join ts_kv_latest ts on ts.entity_id=d.id
             group by d.id)
  select case when last_ts is null then 'never_seen'
              when (extract(epoch from now())*1000 - last_ts) < 120000 then 'active_<2min'
              when (extract(epoch from now())*1000 - last_ts) < 600000 then 'recent_<10min'
              when (extract(epoch from now())*1000 - last_ts) < 3600000 then 'stale_<1h'
              else 'old_>1h'
         end as bucket, count(*)
  from t group by bucket order by bucket;
"
```

| Bucket | Interpretación |
|---|---|
| `active_<2min` | Nodo enviando telemetría regular |
| `recent_<10min` | Nodo con update interval largo o churn ocasional |
| `stale_<1h` | Nodo posiblemente detached, falló reattach |
| `old_>1h` | Nodo apagado, perdido, o requirement de re-commissioning |
| `never_seen` | Provisionado pero nunca conectó (verificar credenciales LwM2M) |

---

## 3. Casos canónicos de fallo

### 3.1 "Mesh con 16 routers fijos pero hay 30 nodos provisionados"

**Síntomas:**
- `ot-ctl router table` reporta exactamente 16
- `ot-ctl history router` muestra re-Added del mismo MAC
- MAC counters: `TxDirectMaxRetryExpiry > 50` en 60s
- TB Edge: nodos flapping entre `active` e `inactive`

**Diagnóstico:** caso clásico de cap default OpenThread (16) demasiado bajo para tu mesh.

**Remediación corta (mitigación interim):**

```sh
ot-ctl routerupgradethreshold 32
ot-ctl routerdowngradethreshold 33
```

Persistir en `/etc/rc.local`. Validar con MAC counters reset/sample (debe ir a 0 errors).

**Remediación a fondo (escala >30 nodos):** seguir el plan de [`docs/decisions/thread-mesh-role-assignment.md`](../decisions/thread-mesh-role-assignment.md) — flashear como MED + backbone selectivo.

### 3.2 "Partition ID cambia entre samples"

**Síntomas:**
- `ot-ctl partitionid` retorna distinto cada minuto
- Mesh se ve "amnésica" — children re-registrando con TB Edge cada pocos minutos

**Diagnóstico:** el OTBR está perdiendo la mesh, posiblemente por:
- RCP (USB dongle) desconectándose intermitentemente — verificar `dmesg | grep -i usb` y `ls /dev/ttyUSB*`
- Baudrate equivocado en `/etc/config/otbr-agent` (debe ser 460800 para SiLabs CP210x estándar, 115200 para algunos otros)
- Otro OTBR en el mismo network-name compitiendo (verificar `ot-ctl scan`)

**Remediación:**
- Verificar conexión física del RCP
- Verificar `uci get otbr-agent.service.uart_device` — si el dongle se renombra (`ttyUSB0` → `ttyUSB1`), apuntar al correcto y `service otbr-agent restart`
- Revisar logs: `journalctl -u otbr-agent -n 200`

### 3.3 "Border routing dice running pero no hay tráfico saliendo a TB Edge"

**Síntomas:**
- `ot-ctl br state` = running
- `ot-ctl br omrprefix` reporta un Local prefix válido
- Pero `tcpdump -i wpan0` no muestra paquetes outbound de nodos

**Diagnóstico:** los nodos no tienen OMR address, o no encuentran al border router.

**Remediación:**
- Verificar que el OTBR esté anunciando RA: `tcpdump -i wpan0 'icmp6 and ip6[40] == 134'` debe mostrar Router Advertisements
- Verificar `addr-lifetime guard` está vivo: `service otbr-addr-guard status`
- Si las direcciones OMR de wpan0 tienen `preferred_lft` finito, el guard no está corriendo → reactivarlo

### 3.4 "Children no aparecen en `ot-ctl child table` pero TB Edge los ve activos"

**Esto NO es un fallo.** `ot-ctl child table` muestra solo los children **directos del leader**. Children de otros routers no aparecen ahí. Para verlos, hay que pedir el child table de cada router individualmente (no es trivial vía CLI).

Indicador alternativo de que están vivos: `ts_kv_latest` en TB Edge muestra actualizaciones recientes.

### 3.5 "El nodo manda REGISTER (visible en `ot-ctl history rx`) pero TB Edge no lo procesa, y `ot-ctl history tx` muestra `ICMP6(Unreach)`"

**Síntomas:**
- `ot-ctl history rx` muestra UDP a `[OMR/mleid]:5683` desde un peer del nodo
- `ot-ctl history tx` muestra `ICMP6(Unreach)` ~50 ms después
- `tcpdump -i wpan0 'udp port 5683'` captura **cero** paquetes
- TB Edge logs no muestran ningún `UDPConnector ... received` desde la dirección del nodo
- Probaste tests locales (`python3 -c "socket.sendto(... OMR ... 5683)"`) → Java sí los recibe

**Diagnóstico**: la zona `thread` para `wpan0` falta en el firewall (`uci show firewall | grep thread` retorna nada o solo coincide en strings). El chain `input` por default es `policy drop` — sin un `iifname "wpan0" jump input_thread` en el chain, **todo** el tráfico de wpan0 se rechaza con ICMPv6 Unreachable. Esto incluye el caso donde la zona estaba puesta pero `fw4 reload` no se ejecutó tras editarla.

Verificación rápida:

```sh
nft list chain inet fw4 input | grep wpan0      # debe haber: iifname "wpan0" jump input_thread
uci show firewall | grep -E 'thread|wpan0'      # debe listar la zone con device wpan0
```

**Remediación:**

```sh
uci add firewall zone
uci set firewall.@zone[-1].name='thread'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='ACCEPT'
uci add_list firewall.@zone[-1].device='wpan0'
uci commit firewall
fw4 reload
nft list chain inet fw4 input        # confirm: iifname "wpan0" jump input_thread
```

`/etc/config/firewall` ya está en `/etc/sysupgrade.conf` por default, así que esto sobrevive sysupgrade. Verifica con `grep firewall /etc/sysupgrade.conf`.

**Por qué se confunde con un bug del stack OT**: `ot-ctl history rx/tx` instrumenta el ip6 stack interno de OpenThread, **antes** de que el paquete (o la ICMPv6 Unreach) crucen el TUN al kernel. Cuando el firewall hace drop al input del kernel, el stack OT ya entregó su parte y el TUN parece silente — pero el log del kernel (vía `dmesg` o nft counters) muestra el reject. **No** confundir con el receive filter del OT (`ip6.cpp:986`, `IsPortInUse`) — ese filter **solo** se aplica si algún componente OT-internal bindeó el puerto, lo cual no es el caso para 5683 en operación normal de SRP/Border Agent.

ADR relacionado: [`../decisions/openthread-host-udp-delivery.md`](../decisions/openthread-host-udp-delivery.md).

---

## 4. Acciones operativas comunes

### 4.1 Subir router thresholds (mitigación interim)

```sh
ot-ctl routerupgradethreshold 32
ot-ctl routerdowngradethreshold 33

# Persistir en /etc/rc.local (OpenThread no guarda en NVS)
cat >> /etc/rc.local <<'EOF'
( sleep 12 && ot-ctl routerupgradethreshold 32 && ot-ctl routerdowngradethreshold 33 ) >> /tmp/otbr-router-thresholds.log 2>&1 &
EOF
```

Aplicable solo si todos tus nodos son FTD/REED y la mesh tiene 16-30 nodos. Ver `decisions/thread-mesh-role-assignment.md` §4 para casos donde NO basta.

### 4.2 Reset de MAC counters para sample limpio

```sh
ot-ctl counters mac reset
ot-ctl counters mle reset
sleep 60
ot-ctl counters mac
ot-ctl counters mle
```

### 4.3 Forzar reattach del OTBR a la mesh

> **Disruptivo** — los 30+ nodos van a perder conexión durante ~30s.

```sh
ot-ctl thread stop
sleep 5
ot-ctl thread start
```

Solo usar si la mesh está en mal estado y otros remedios no han funcionado. Considerar ventana de mantenimiento.

### 4.4 Reaplicar dataset (si OT está disabled/detached)

```sh
/etc/otbr/reapply-dataset.sh    # script ya presente en el edge
ot-ctl state                     # debe pasar a leader o router
```

### 4.5 Restaurar thresholds a defaults

```sh
ot-ctl routerupgradethreshold 16
ot-ctl routerdowngradethreshold 23
```

Y editar `/etc/rc.local` para quitar la línea de persistencia. Útil si vuelves a un edge con <16 nodos.

### 4.6 Verificar/agregar zone `thread` en firewall para `wpan0`

**Síntoma**: nodos joinean Thread OK pero `REGISTER` LwM2M no llega al socket de TB Edge. `tcpdump -i wpan0` no muestra paquetes hacia/desde el host. Causa: chain `input` del nft tiene `policy drop` con jumps solo para `lo`, `br-lan`, `eth0`, `docker0` — no para `wpan0`.

**Diagnóstico**:

```sh
nft list ruleset | awk '/chain input {/,/^\}/'
# Buscar línea: iifname "wpan0" jump input_thread
# Si NO aparece → bug; si aparece → OK
```

**Fix** (si falta):

```sh
uci add firewall zone
uci set firewall.@zone[-1].name='thread'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='ACCEPT'
uci set firewall.@zone[-1].device='wpan0'
uci commit firewall
/etc/init.d/firewall reload

# Persistir
grep -q '/etc/config/firewall' /etc/sysupgrade.conf \
    || echo '/etc/config/firewall' >> /etc/sysupgrade.conf

# Validar
nft list ruleset | grep 'iifname "wpan0"' | head -3
# Esperado: input_thread, forward_thread, helper_thread + counter packets
```

### 4.7 Persistir un-deprecate de mleid en wpan0 (cron-based)

**Cuándo aplicar**: nodos LwM2M caen en ciclo Re-REGISTER cada ~3-5 min después de funcionar bien al inicio. TB Edge logs muestran `Closing old session ... Client has different registration` cada lifetime.

**Causa raíz**: otbr-agent re-marca la EID como `deprecated` dentro del primer minuto post-`ifup`. El hotplug `99-wpan0-undeprecate` corre solo al `ifup`, no es suficiente.

**Diagnóstico rápido**:

```sh
# 1. Ver address state actual:
ip -6 addr show wpan0 | grep -F "$(ot-ctl ipaddr mleid | head -1 | tr -d '\r')"
# OK:   "scope global ... preferred_lft forever"
# BUG:  "scope global nodad deprecated"

# 2. Ver source que el kernel elige para mesh-local:
ip -6 route get fdf1:a391:6243:2a67:1:2:3:4
# OK:   src=<mleid>          (simétrico con SRP)
# BUG:  src=<OMR address>    (asimétrico — rompe LwM2M)

# 3. Esperar 60s sin tocar nada, repetir paso 1-2:
sleep 60 && ip -6 addr show wpan0 | grep deprecated
# Si muestra "deprecated" → el bug está activo, aplicar el fix
```

**Fix persistente** (OpenWrt — busybox crond, no systemd):

```sh
# 1. Crear cron entry
cat > /etc/crontabs/root <<'EOF'
* * * * * EID=$(ot-ctl ipaddr mleid 2>/dev/null | head -1 | tr -d '\r'); [ -n "$EID" ] && ip -6 addr change "${EID}/64" dev wpan0 preferred_lft forever valid_lft forever 2>/dev/null
EOF
chmod 600 /etc/crontabs/root

# 2. Enable + start crond
/etc/init.d/cron enable
/etc/init.d/cron start

# 3. Persistir
grep -q '/etc/crontabs/root' /etc/sysupgrade.conf || echo '/etc/crontabs/root' >> /etc/sysupgrade.conf

# 4. Verificar después de 2-3 min:
ip -6 addr show wpan0 | grep -F "$(ot-ctl ipaddr mleid | head -1 | tr -d '\r')"
# Esperado: "preferred_lft forever" (NO "deprecated")
```

**Validación** (15 min sample sin disconnects):

```sh
# Cada 60s durante 15 min:
for i in $(seq 1 15); do
  echo "=== sample $i ==="
  ip -6 route get fdf1:a391:6243:2a67:1:2:3:4 | head -1
  ot-ctl child table 2>/dev/null | grep '0x' || echo 'no children'
  sleep 60
done > /tmp/validation.log

# PASS si: "src <mleid>" en TODAS las consultas (la EID nunca pierde el preferred)

# Lado TB Edge:
docker logs --since 20m tb-edge-v2 | grep -E 'register|Closing old|delete registration' | wc -l
# PASS si: aparece UN "initialized new client" + N "update after Registration" sin "Closing old"
```

### 4.8 Re-registrar SRP host con mleid (fix asimetría src/dst)

Cuándo aplicar: el síntoma de §2.3.5 (REGISTER OK pero Updates desaparecen).

```sh
# 1. Detener SRP client + limpiar
ot-ctl srp client autostart disable
ot-ctl srp client stop
ot-ctl srp client service clear ThingsBoard-Edge _coap._udp
ot-ctl srp client service clear ThingsBoard-Edge _lwm2m._udp
ot-ctl srp client host clear

# 2. Re-registrar con mleid EXPLÍCITO (NO 'auto')
MLEID=$(ot-ctl ipaddr mleid | head -1 | tr -d '\r')
ot-ctl srp client host name thingsboard-edge
ot-ctl srp client host address $MLEID
ot-ctl srp client service add ThingsBoard-Edge _coap._udp 5683 0 0
ot-ctl srp client service add ThingsBoard-Edge _lwm2m._udp 5683 0 0
ot-ctl srp client autostart enable

# 3. Verificar (en 5-10s)
ot-ctl srp client state                     # Enabled
ot-ctl srp client host                       # state:Registered, addrs:[mleid]
ot-ctl srp server service                    # addresses: [mleid]
```

> ⚠️ Aplica también a `/etc/rc.local` para que persista en boot. **NUNCA usar `ot-ctl srp client host address auto`** — OpenThread elige una de las direcciones (típicamente OMR) que reproduce el bug.

---

## 5. Reportar resultados

Después de un diagnóstico, dejar evidencia en `docs/architecture/snapshots/edge-<IP>-<YYYY-MM-DD>-<context>.txt`:

```sh
EDGE_IP=192.168.1.111
DATE=$(date +%Y-%m-%d)
CONTEXT=mesh-health-check    # o post-threshold-fix, etc.

ssh root@$EDGE_IP "$(cat <<'EOF'
echo '## state'; ot-ctl state; ot-ctl networkname; ot-ctl partitionid; ot-ctl br state
echo '## thresholds'; ot-ctl routerupgradethreshold; ot-ctl routerdowngradethreshold
echo '## tables'
ot-ctl router table
ot-ctl neighbor table
ot-ctl child table
echo '## history'
ot-ctl history router 50
echo '## counters'
ot-ctl counters mac reset; sleep 60; ot-ctl counters mac
EOF
)" > docs/architecture/snapshots/edge-${EDGE_IP}-${DATE}-${CONTEXT}.txt
```

Esto permite hacer diff vs futuros snapshots y reconstruir el "antes" si algo se rompe.

---

## 6. Referencias

- ADR: [`../decisions/thread-mesh-role-assignment.md`](../decisions/thread-mesh-role-assignment.md)
- Spec del edge: [`../architecture/edge-thingsboard.md §5`](../architecture/edge-thingsboard.md)
- OpenThread CLI: https://github.com/openthread/openthread/blob/main/src/cli/README.md
- Thread spec public summary: https://www.threadgroup.org/Portals/0/documents/support/Thread_Spec_v1.1.1.pdf
