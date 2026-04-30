# Runbook — Test empírico de capacidad LwM2M (5-node baseline → scale-up)

**Cuándo usar este runbook:**
- Vas a poner en producción un edge nuevo y necesitas saber cuántos nodos aguanta
- Cambiaste el `lifetime` LwM2M o el rate de telemetría aplicación y quieres re-validar
- Sospechas que el deployment actual está saturado (síntoma: nodos `old_>1h` sin razón aparente, host idle, MAC counters limpios — ver ADR para diagnóstico)
- Vas a aceptar más nodos en un edge existente y quieres confirmar headroom

**Cuándo NO usar este runbook:**
- Si tu issue es de topología/coverage radio → ver [`thread-mesh-health.md`](thread-mesh-health.md) primero
- Si tu issue es presión de host (CPU/RAM postgres) → ver [`tb-edge-baseline-tuning.md`](tb-edge-baseline-tuning.md)
- Si todavía no sabes el `lifetime` y rate aplicación de tus nodos → primero averíguarlo (firmware team o `ot-ctl coap` GET de los Resources)

**Decisión arquitectural relevante:** [`docs/decisions/lwm2m-update-rate-and-mesh-capacity.md`](../decisions/lwm2m-update-rate-and-mesh-capacity.md)

**Pre-condiciones:**
- SSH al edge con root
- Acceso físico a los nodos para apagar/encender (o método remoto de power-cycle)
- TB Edge funcionando con los nodos provisionados
- Conocer el `lifetime` actual y el rate aplicación

---

## 1. Pre-flight (15 min)

### 1.1 Documentar configuración actual del firmware

```sh
# Si tu firmware expone LwM2M Object 1 (Server) como readable:
# leer Resource 1 (Lifetime) — esto es per-server
ot-ctl coap get <node_omr_addr> /1/0/1     # típicamente

# O verificar empíricamente: contar Updates en 5 min y dividir
```

Anotar en una hoja:

| Parámetro | Valor |
|---|---|
| `lifetime` LwM2M | _____ s |
| Rate aplicación esperado | _____ msg/s |
| `msg_rate` total esperado | _____ msg/s |
| `per_node_bps` predicho (fórmula ADR §2.3) | _____ |
| `N_max` teórico | _____ |

### 1.2 Snapshot del estado pre-test

```sh
EDGE_IP=192.168.1.111
DATE=$(date +%Y-%m-%d)

ssh root@$EDGE_IP "
  echo '## state'; ot-ctl state; ot-ctl partitionid
  echo '## counters mac (snapshot pre-test, NO reset)'; ot-ctl counters mac
  echo '## counters mle'; ot-ctl counters mle
  echo '## ts_kv last 5 min'; docker exec tb-edge-postgres psql -U postgres -d thingsboard_edge -c \"select count(*) from ts_kv where ts > (extract(epoch from now()-interval '5 min')*1000)::bigint;\"
  echo '## activity buckets'; docker exec tb-edge-postgres psql -U postgres -d thingsboard_edge -c \"with t as (select d.id, max(ts.ts) as last_ts from device d left join ts_kv_latest ts on ts.entity_id=d.id group by d.id) select case when last_ts is null then 'never_seen' when (extract(epoch from now())*1000 - last_ts) < 120000 then 'active_<2min' when (extract(epoch from now())*1000 - last_ts) < 600000 then 'recent_<10min' else 'stale' end as bucket, count(*) from t group by bucket;\"
" > docs/architecture/snapshots/edge-${EDGE_IP}-${DATE}-pretest.txt
```

### 1.3 Elegir los 5 nodos del baseline

Criterios:
- Nodos con buena conectividad radio al OTBR (RSSI mejor que -65 dBm en historial)
- Distribuidos físicamente (no los 5 pegados al OTBR)
- Idealmente 1 a cada esquina de la planta + 1 central

Anotar sus device names (e.g., `ami-esp32c6-XXXX`) y MAC extendido.

---

## 2. Fase A — Baseline de 5 nodos (≥ 1 hora)

### 2.1 Apagar los 25 nodos restantes

Métodos (de menos a más invasivo):

1. **Power-cycle físico** (más limpio): desconectar power de los 25 que NO son baseline
2. **Factory reset + dejar despareados**: si tu firmware vuelve a buscar la red al boot, no sirve
3. **Mover esos 25 a otro `network-name`**: requiere reflash, no práctico durante el test

**Si no puedes apagar físicamente**, este test no se puede ejecutar limpio. Procede con la cantidad que tienes y ajusta los cálculos.

Esperar 10 min para que la mesh se estabilice con solo los 5.

### 2.2 Verificar que los 5 están conectados

```sh
ot-ctl child table         # debe haber 5 (o algunos como children de routers, ver §1.5 thread-mesh-health.md)
docker exec tb-edge-postgres psql -U postgres -d thingsboard_edge -c "
  with t as (select d.id, max(ts.ts) as last_ts from device d
             left join ts_kv_latest ts on ts.entity_id=d.id group by d.id)
  select count(*) from t where (extract(epoch from now())*1000 - last_ts) < 120000;
"
# Resultado esperado: 5
```

Si no son 5 (alguno detached) → re-cycle ese nodo, esperar otros 10 min.

### 2.3 Iniciar el sample de 60 min

```sh
ssh root@$EDGE_IP "
  ot-ctl counters mac reset
  ot-ctl counters mle reset
  date > /tmp/test-start.txt
" && echo 'Sample iniciado, esperar 60 min'

# 60 min después:
ssh root@$EDGE_IP "
  echo '## end of sample'
  date
  echo '## mac counters'
  ot-ctl counters mac
  echo '## mle counters'
  ot-ctl counters mle
  echo '## history router'
  ot-ctl history router 200 | head -100
" > docs/architecture/snapshots/edge-${EDGE_IP}-${DATE}-phaseA.txt
```

### 2.4 Métricas de salud durante el sample

Cada 10 min, capturar:

```sh
ssh root@$EDGE_IP "
  echo '=== \$(date) ==='
  ot-ctl counters mac | grep -E 'TxTotal|TxRetry|TxErrCca|TxDirectMaxRetry'
  docker exec tb-edge-postgres psql -U postgres -d thingsboard_edge -c \"
    select count(*) as msgs_last_10min from ts_kv where ts > (extract(epoch from now()-interval '10 min')*1000)::bigint;
  \"
  ot-ctl history router 30 2>/dev/null | grep -c 'CostChanged\|NextHopChanged\|Added\|Removed'
"
```

Armar tabla:

| Tiempo | TxTotal Δ | TxDirectMaxRetryExpiry | msgs/10min | router events |
|---|---|---|---|---|
| 10 min | _____ | _____ | _____ | _____ |
| 20 min | _____ | _____ | _____ | _____ |
| 30 min | _____ | _____ | _____ | _____ |
| 40 min | _____ | _____ | _____ | _____ |
| 50 min | _____ | _____ | _____ | _____ |
| 60 min | _____ | _____ | _____ | _____ |

### 2.5 Criterio de pass para Fase A

| Indicador | Pass | Fail |
|---|---|---|
| `TxDirectMaxRetryExpiry` total en 60 min | ≤ 5 | > 50 |
| `TxErrCca` total en 60 min | ≤ 10 | > 50 |
| TB Edge `active_<2min` | 5/5 sostenido toda la hora | < 5 en algún momento |
| Eventos `ot-ctl history router` totales | ≤ 5 (idealmente 0) | > 30 |
| Disparidad msgs/10min (max - min) | < 10% | > 30% |

**Si Fase A NO PASA con 5 nodos**: el `lifetime` o el rate aplicación están demasiado agresivos para tu hardware/canal. Subir `lifetime` (al menos 60s) y repetir. **No pases a Fase B**.

### 2.6 Calcular `per_node_bps` empírico

```
per_node_bps_empírico = (TxTotal × 85 B × 8) ÷ (3600 s × 5 nodos)
                       = TxTotal × 0.0378
```

Para Pi 4 + Sonoff RCP en canal limpio, valores típicos:

| `lifetime` | rate aplicación | TxTotal/hora esperado (5 nodos) | per_node_bps esperado |
|---|---|---|---|
| 5s | 50 msg/min | ~15,000 | ~570 |
| 60s | 1 msg/min | ~360 | ~14 |
| 60s | 1 msg/seg | ~18,000 | ~680 |

Si tu `per_node_bps` empírico difiere >50% del modelo §2.3 de la ADR → ajustar las constantes (`overhead_factor`, `hops`) y documentar.

---

## 3. Fase B — Scale-up controlado (≥ 5 horas para llegar a 30)

### 3.1 Procedimiento

Solo si Fase A pasó:

```
Sub-fase | Nodos | Duración | Criterio de pass
B.1     | 10    | 60 min   | mismo que Fase A pero con 10
B.2     | 15    | 60 min   | "
B.3     | 20    | 60 min   | "
B.4     | 25    | 60 min   | "
B.5     | 30    | 60 min   | "
```

En cada sub-fase:

1. Encender 5 nodos más (de los 25 apagados)
2. Esperar 10 min para estabilización
3. Sample de 60 min con métricas idénticas a §2.4
4. Evaluar criterio de pass (§2.5)
5. Si pasa → continuar; si NO pasa → este es tu `N_max` empírico, **detener**

### 3.2 Captura de evidencia

Por cada sub-fase exitosa:

```sh
ssh root@$EDGE_IP "...captura igual a §2.3..." \
    > docs/architecture/snapshots/edge-${EDGE_IP}-${DATE}-phaseB-${N}nodos.txt
```

### 3.3 Cuando se rompe — qué documentar

Cuando una sub-fase falla, capturar **inmediatamente** sin esperar a que se "recupere":

```sh
ssh root@$EDGE_IP "
  echo '=== FAILURE at \$N nodos, \$(date) ==='
  ot-ctl counters mac
  ot-ctl counters mle
  ot-ctl history router 200
  ot-ctl router table
  ot-ctl child table
  docker exec tb-edge-postgres psql -U postgres -d thingsboard_edge -c \"
    with t as (select d.id, max(ts.ts) as last_ts from device d
               left join ts_kv_latest ts on ts.entity_id=d.id group by d.id)
    select substring(d.name,1,30), to_timestamp(max(ts.ts)/1000)::text as last_seen
    from device d left join ts_kv_latest ts on ts.entity_id=d.id
    group by d.id, d.name order by max(ts.ts) nulls first;
  \"
" > docs/architecture/snapshots/edge-${EDGE_IP}-${DATE}-phaseB-FAILURE-${N}nodos.txt
```

---

## 4. Fase C — Re-validación con `lifetime` saneado (opcional, ≥ 5 horas)

### 4.1 Cuándo hacerlo

- Solo si Fase B encontró un `N_max < 30` con el `lifetime` original
- Y si el firmware team puede reflashear los nodos con un `lifetime` más alto

### 4.2 Procedimiento

1. Reflashear los N nodos elegidos con `lifetime = 60s`
2. Repetir Fase A (5 nodos baseline) y Fase B (scale-up)
3. Comparar:
   - `N_max` empírico anterior vs nuevo
   - `per_node_bps` empírico anterior vs nuevo
   - Modelo predicho vs real

### 4.3 Resultado esperado

Según el modelo, `lifetime: 5s → 60s` reduce `per_node_bps` ~12-50× (depende del rate aplicación residual). El `N_max` debería subir proporcionalmente, hasta toparse con el cap topológico (32 routers).

---

## 5. Reporte y archivado

### 5.1 Crear el reporte consolidado

Plantilla en `docs/architecture/snapshots/edge-${IP}-${DATE}-capacity-report.md`:

```markdown
# Capacity test — edge ${IP} — ${DATE}

## Configuración pre-test
- Firmware version: ___
- LwM2M lifetime: ___
- Rate aplicación esperado: ___
- Modelo predijo N_max = ___

## Fase A — 5 nodos (PASS / FAIL)
[tabla §2.4]
- per_node_bps empírico: ___

## Fase B — scale-up
[tabla con cada sub-fase y verdict]
- N_max empírico = ___

## Fase C — re-validación con lifetime=___
[tabla]
- N_max empírico nuevo = ___

## Diferencia modelo vs empírico
- Δ N_max: __%
- Constantes a ajustar en ADR §2.3: [ninguno | overhead_factor | hops | ...]

## Recomendaciones
- ___
- ___
```

### 5.2 Actualizar la ADR si el modelo está mal

Si el `N_max` empírico difiere > 20% de lo predicho, abrir issue/PR para actualizar `docs/decisions/lwm2m-update-rate-and-mesh-capacity.md`:

- §2.3 fórmula constante específica (e.g., subir `BW_effective` de 70 a 80 kbps)
- §2.4 ejemplos numéricos
- §3 plan de validación con la lección aprendida

---

## 6. Casos comunes

### 6.1 "Fase A falla con 5 nodos"

**Síntomas:** TxDirectMaxRetryExpiry > 50 en 60 min, o nodos detached.

**Diagnóstico:** el `lifetime` y/o rate aplicación están demasiado agresivos incluso para 5 nodos. NO continuar a Fase B.

**Remediación:**
- Subir `lifetime` (de 5s a 60s o más)
- Reducir rate aplicación si es posible
- Repetir Fase A

### 6.2 "Fase B se rompe en N=15-20"

**Diagnóstico:** se está hitting el régimen de saturación. Es el comportamiento esperado del modelo §2.3. Documentar el N exacto y proceder a Fase C con `lifetime` saneado.

### 6.3 "Fase B llega a 30 sin problemas"

**Diagnóstico:** el deployment tiene headroom. Documentar y considerar añadir más nodos si la aplicación lo requiere — el límite real puede ser el cap topológico (ver `thread-mesh-role-assignment.md`).

### 6.4 "Modelo predijo 21 pero empírico fue 28"

**Diagnóstico:** el modelo está conservador (positivo — falla en el lado seguro). Revisar `overhead_factor` (puede estar sobreestimado). Actualizar constantes en la ADR.

### 6.5 "Modelo predijo 30 pero empírico fue 18"

**Diagnóstico:** algo no modelado está consumiendo airtime — investigar:
- Rogue PAN (otro Thread network en mismo canal): `ot-ctl scan`
- Interferencia WiFi: `iw scan` en banda 2.4 GHz
- DTLS handshake costoso (LwM2M con certificates): chequear si `psk` está habilitado en lugar de DTLS-PSK

Actualizar `BW_effective` en la ADR para reflejar entorno con interferencia esperada.

---

## 7. Referencias

- ADR: [`../decisions/lwm2m-update-rate-and-mesh-capacity.md`](../decisions/lwm2m-update-rate-and-mesh-capacity.md)
- ADR hermana (topología): [`../decisions/thread-mesh-role-assignment.md`](../decisions/thread-mesh-role-assignment.md)
- Runbook diagnóstico: [`thread-mesh-health.md`](thread-mesh-health.md)
- Spec del edge: [`../architecture/edge-thingsboard.md §5.7`](../architecture/edge-thingsboard.md)
- IEEE 802.15.4-2020 spec, sección 8.2 (CSMA-CA)
