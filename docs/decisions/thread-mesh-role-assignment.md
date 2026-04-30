# Asignación de roles en mesh Thread para deployments de 30+ nodos

**Audiencia:** ingeniería de firmware/red diseñando o operando un edge UNAL-Thread con más de 16 nodos provisionados.
**Estado:** Decidido — 2026-04-27. Validado empíricamente sobre el edge `192.168.1.111` (EKH01) con 30 nodos LwM2M activos. Plan de implementación: flashear todos los nodos como **MED** y discoverar el backbone por observación.
**Supersedes:** ninguna decisión previa — esta es la primera ADR sobre topología de mesh.
**Complementa:** [`lwm2m-update-rate-and-mesh-capacity.md`](lwm2m-update-rate-and-mesh-capacity.md) — esta ADR cubre la dimensión **topológica** del scaling (cuántos routers caben). La hermana cubre la dimensión de **tráfico** (cuántos mensajes caben). Las dos juntas dan la imagen completa.

> **Resumen de una línea:** OpenThread limita una partition a 32 routers por especificación Thread 1.x. Para 30+ nodos sostenibles necesitamos diferenciar **router-eligible (REED)** vs **end-device (MED)** en el firmware. El leader/OTBR no puede forzar ese rol remotamente.

---

## 1. Contexto

### 1.1 Estado inicial observado

El edge `192.168.1.111` (Pi 4 + EKH01 hat + OTBR + ThingsBoard Edge) opera 30 nodos provisionados con stack **Thread + LwM2M**. Snapshot del 2026-04-27, ANTES de cualquier intervención:

- `ot-ctl router table` reportaba **16 routers en mesh** (cap default OpenThread)
- `ot-ctl history router` mostraba el mismo router re-attached 2-3 veces en ventanas de 25 minutos (`fa86ae95...` y `52dbf8f5...` y `6a414aac...` cada uno re-attached 3 veces)
- Eventos `CostChanged` / `NextHopChanged` cada pocos segundos
- MAC counters en 60s sample reportaban:
  - `TxDirectMaxRetryExpiry = 148` (paquetes perdidos por max retries en 802.15.4)
  - `TxErrAbort = 30`
  - `TxErrCca = 6`, `TxErrBusyChannel = 6`
  - `RxErrNoUnknownNeighbor = 111`
- TB Edge confirmaba los 30 devices activos en BD pero con visible disrupción de sesiones LwM2M

### 1.2 La limitación dura del protocolo Thread

OpenThread implementa la spec **Thread 1.x** que define **MAX_ROUTERS = 32 por partition**. No es una decisión de implementación — el `Router-ID` es un campo de 6 bits con 64 valores totales, de los cuales solo 32 se usan para routers activos (los otros 32 están reservados para `REUSE_DELAY` de 200s tras downgrade, evitando conflictos con tablas de ruteo en propagación).

Defaults de OpenThread:

```
ot-ctl routerupgradethreshold   → 16    (target: leader promueve hasta tener 16 routers)
ot-ctl routerdowngradethreshold → 23    (con >23 routers, los excedentes se degradan)
```

Estos defaults asumen mesh **típico residencial/hogar de 8-16 nodos**. Para deployment industrial de 30-60 nodos quedan obsoletos.

### 1.3 Por qué los 30 nodos peleaban por slot

Los 30 nodos están flasheados con `mode rdn` = **Full-Thread Device Router-Eligible (FTD/REED)**:

| Bit | Valor | Significado |
|---|---|---|
| `r` | 1 | RxOnWhenIdle — radio siempre encendido |
| `d` | 1 | DeviceType=FTD — Full-Thread Device, capaz de rutear |
| `n` | 1 | NetworkData=Full — recibe la network data completa |

Con esa configuración, **cada nodo intenta promoverse a router** después de un delay random (`routerselectionjitter ≈ 120s`). El leader OTBR otorgaba router-IDs hasta el threshold (16), rechazaba el resto, y los routers existentes se degradaban cuando no eran "los 16 mejores" → ciclo permanente de promote/demote.

### 1.4 Mitigación interim aplicada en sesión 2026-04-27

Para parar el sangrado inmediato sin tocar firmware, se subieron los thresholds del leader al máximo del protocolo:

```sh
ot-ctl routerupgradethreshold 32
ot-ctl routerdowngradethreshold 33
```

Resultado MAC counter en 60s sample post-fix:

| Counter | Pre-fix | Post-fix |
|---|---|---|
| `TxDirectMaxRetryExpiry` | 148 | **0** |
| `TxErrAbort` | 30 | **0** |
| `TxErrCca` | 6 | **0** |
| `TxErrBusyChannel` | 6 | **0** |
| `RxErrNoUnknownNeighbor` | 111 | **0** |

Persistido en `/etc/rc.local` (OpenThread no guarda estos en NVS).

Este fix **arregla el caso 30 pero no escala a 60**. Con 60 REED y threshold=32, vuelven a competir 60 nodos por 32 slots.

---

## 2. Decisión

### 2.1 Política de roles

Para edges con **> 16 nodos provisionados**, los nodos se diferencian en **dos clases** asignadas en el firmware del nodo:

| Clase | Cantidad | Mode | `routereligible` | Propósito |
|---|---|---|---|---|
| **Backbone** | ⌈total/5⌉ con techo 12 | `rdn` | enable | Routers candidatos — el leader los auto-promueve hasta `routerupgradethreshold` |
| **Leaf** | resto | `rn` | disable | Children siempre — nunca compiten por slot, nunca routean |

Para **60 nodos**: 12 backbone + 47 leaves + 1 OTBR (leader) = 60 devices + 1 border router.

`routereligible disable` en los leaves es belt-and-suspenders: `mode rn` ya implica que no pueden ser routers, pero el flag explícito previene side-effects si en el futuro alguien cambia el `mode`.

### 2.2 Una sola partition, un solo OTBR

Mantenemos **un solo OTBR** por edge. Razones:

- Un solo SRP server publicando `_coap._udp.default.service.arpa` y similares
- Un solo dataset que mantener
- Un solo dominio de fallo (si cae el OTBR, cae todo el edge — pero con backbone redundante esto es manejable)
- Operacionalmente más simple

Multi-partition (varios OTBRs activos) se considera **out of scope** — ver §4.3 para por qué se descartó.

### 2.3 Discovery del backbone por observación empírica

**Esta es la parte clave de la decisión.** Antes de pre-asignar qué nodos son backbone, ejecutamos un **bootstrap empírico**:

#### Fase 1 — Flash all-MED
Flashear los 60 nodos con `mode rn` + `routereligible disable`. Resultado esperado: solo el OTBR es router. Cada MED se conecta como child del OTBR si tiene línea radio directa, **se queda detached si no**.

#### Fase 2 — Observación
Esperar 15-30 min y mirar:

```sh
ot-ctl child table         # children directos del leader
ot-ctl neighbor table      # vecinos radio del leader
# en TB Edge: select count(*) from device where last_activity > now()-interval '5 min';
```

Los nodos que **no aparecen** son los que no tienen línea radio directa al OTBR — esos son los que necesitan un relay.

#### Fase 3 — Promoción selectiva
Tomar la lista de nodos detached + un mapa físico del deployment y elegir N nodos backbone tales que:

1. Cada nodo detached pueda alcanzar al menos un backbone
2. Cada backbone alcance al menos al OTBR o a otro backbone
3. Los backbones estén **alimentados por mains** (radio always-on consume batería)

Reflashear esos N nodos con `mode rdn` + `routereligible enable`. Subir los thresholds del leader a `N+1 / N+2`.

#### Fase 4 — Validación
Esperar 15-30 min, repetir el chequeo. Iterar si todavía hay detached. Documentar el N final en el spec del edge (§5.6 de `edge-thingsboard.md`).

### 2.4 Por qué empezar all-MED y no all-REED con thresholds

| Estrategia | Pro | Contra |
|---|---|---|
| **All-REED** + threshold=N | Ya funciona en el edge actual | No revela qué nodos son críticos vs redundantes; OpenThread elige routers por orden de Address Solicit, no por posición |
| **All-MED** + promoción selectiva | Revela el grafo radio real; backbone determinístico y reproducible | Requiere proceso de discovery, dos firmwares |

La estrategia **all-MED** es lo que se hace en deployments industriales serios (e.g. Apple HomeKit, Nordic nRF Cloud) por la misma razón: **el grafo radio se descubre, no se asume**.

---

## 3. Consecuencias

### 3.1 Positivas

- **Cero churn protocolar**: con N backbone ≪ 32, OpenThread nunca degrada/promueve routers en runtime
- **Topología determinística**: el mismo set de N backbone produce el mismo árbol de ruteo
- **Escala lineal**: con `childmax=64` (default), 12 backbone soportan hasta 768 children teóricos. El cuello pasa a ser airtime 802.15.4, no protocolo
- **Predecible para reflashes**: factory reset + re-flash devuelve al mismo rol

### 3.2 Negativas / costos

- **Requiere fase de discovery** en cada deployment nuevo — 30-60 min de proceso semi-manual la primera vez
- **Dos firmwares** (`backbone.bin` + `leaf.bin`) o un firmware con flag por device-id en bootstrap
- **MEDs no relayean** — si cae un backbone, los leaves a su alrededor pueden quedar islados hasta que otro backbone los adopte (depende de RSSI a otros backbone)
- **Re-deployment a otro sitio** (mover el edge a otro edificio) requiere repetir Fase 1-4 — el grafo radio cambia con el ambiente

### 3.3 Boundaries de aplicabilidad

Esta decisión aplica cuando:

- ✅ El edge tiene **> 16 nodos provisionados** y la topología es estable (no IoT móvil)
- ✅ Los nodos pueden ser flasheados con dos firmwares distintos o reciben config por bootstrap
- ✅ El stack del nodo soporta `mode rn` (Thread + LwM2M con MED)

Esta decisión **NO** aplica cuando:

- ❌ Edges con < 16 nodos — los defaults de OpenThread bastan, no vale el esfuerzo de discovery
- ❌ Nodos móviles (su grafo radio cambia constantemente) — usar all-REED con thresholds altos es más resiliente aunque haya churn
- ❌ Stacks que solo soportan FTD (algunos vendor SDKs vienen así por default y requieren custom build)

### 3.4 Dependencia con la dimensión de tráfico

Esta ADR resuelve la pregunta **"¿caben los nodos en la mesh topológicamente?"** pero **NO** resuelve **"¿caben en airtime?"**. Si el `lifetime` LwM2M es agresivo (≤ 30s) o el rate de telemetría aplicación es alto (≥ 1 Hz/nodo), el deployment se va a saturar mucho antes de llegar al cap topológico — sin importar cuán bien esté distribuido el backbone.

La ADR hermana [`lwm2m-update-rate-and-mesh-capacity.md`](lwm2m-update-rate-and-mesh-capacity.md) provee el modelo de capacidad para predecir N_max desde el lado de tráfico. **Las dos ADRs deben aplicarse juntas** — la mesh más bonita topológicamente del mundo no aguanta si cada nodo manda 1 msg/s.

---

## 4. Alternativas consideradas

### 4.1 Subir `OPENTHREAD_CONFIG_MLE_MAX_ROUTERS` en compile-time (DESCARTADO)

OpenThread permite cambiar el cap a 64 vía `#define`. Descartado porque:

- Pierde Thread certification (es non-spec)
- Interop quebrado con devices estándar (commissioner, Apple HomePod, Nest, etc.)
- Más overhead MLE (cada router advertía cada 32s — con 64 routers = doble tráfico)
- OpenThread tiene paths internos que asumen ≤32 routers; rebuilds custom son frágiles

Si el deployment **nunca** va a interop con Thread comercial y la huella de tráfico es aceptable, técnicamente funciona. No es nuestro caso.

### 4.2 All-REED con threshold=32 + downgrade agresivo (PARCIAL)

Es el estado **interim actual del edge** post-fix de 2026-04-27. Funciona para 30 nodos pero:

- A 60 nodos, 28 quedan compitiendo por slot → vuelve el churn
- No revela cuáles son los 12 nodos críticos por posición
- Si un router cae, OpenThread elige el reemplazo "first-come", no el mejor posicionado

Sirve como **mitigación temporal** mientras se ejecuta el plan all-MED. No es destino final.

### 4.3 Multi-partition (varios OTBRs) (DESCARTADO PARA ESTE EDGE)

Distribuir 60 nodos en 2 partitions de 30 (Edge A en Pi 4, Edge B en R1000) sortea el cap de 32. Descartado **para este edge específico** porque:

- Duplica el SRP server (cada partition publica su propio `_coap._udp.default.service.arpa`)
- Doble dataset, doble commissioning, doble operación de mantenimiento
- Los nodos de partition A no ven a los de partition B en el dominio Thread (solo vía IPv6 routing externo)
- TB Edge tendría que conocer ambos OMR prefixes

Multi-partition queda como **arquitectura de escalabilidad para >120 nodos** (3+ partitions). Para 60 con un solo edge, no compensa la complejidad operacional.

### 4.4 SED (Sleepy End Device) en lugar de MED (CONSIDERADO PARCIALMENTE)

Para nodos battery-powered con duty cycle largo (>30s entre updates), SED ahorra batería con radio off durante sleep. Decisión: **MED por default**, SED solo case-by-case si el firmware lo expone y el nodo es battery-powered.

Trade-off:

| | MED | SED |
|---|---|---|
| Latencia downlink LwM2M | <100ms | segundos (depende de poll period) |
| Apto para `Observe`/`Notify` con baja latencia | ✅ | ⚠️ con delay |
| Consumo batería | medio (radio always rx) | muy bajo |

---

## 5. Validación empírica

### 5.1 Datos pre-decisión (2026-04-27, edge 192.168.1.111)

Ver §1.1 — 30 nodos REED, 16 routers, 148 packet drops/min.

### 5.2 Datos post-mitigación interim (mismo día, post bump de thresholds)

| Métrica | Valor |
|---|---|
| Routers en mesh | 17 (de 30 nodos REED) |
| Children del leader | 0 (los demás nodos son children de OTROS routers) |
| `TxDirectMaxRetryExpiry` (60s sample) | 0 |
| Devices activos en TB Edge | 30 / 30 (27 con last_activity <2 min, 3 con <10 min) |
| Pkts LwM2M únicos en 120s tcpdump | 20 (los otros 10 con update interval >120s) |

OpenThread auto-balanceó: 17 nodos pidieron router-id, 13 se quedaron como REED-children porque ya tenían parent estable. Esto es la mejor evidencia de que **la promoción a router se hace según necesidad de topología, no por igualdad** — y por eso la estrategia de pre-asignar backbone manualmente debería superar en estabilidad a esta auto-asignación.

### 5.3 Datos esperados post-implementación all-MED + 12 backbone

Predicción (a verificar tras Fase 4):

- Routers en mesh: 13 (12 backbone + leader) — invariante en runtime
- `ot-ctl history router` casi vacío (sin re-attaches)
- MAC counters: cero retries/aborts sostenido
- Topología reproducible tras reboot del OTBR

Si **alguno de los 47 leaves no encuentra parent**, indica que el backbone elegido no cubre toda la planta — añadir un backbone más en la zona muerta o reposicionar.

---

## 6. Métodos de medición

Estas son las pruebas que se ejecutan en cada Fase del rollout. Documentadas también en `runbooks/thread-mesh-health.md` para uso operativo.

### 6.1 Snapshot de mesh

```sh
ot-ctl router table       # routers actuales (incluye self)
ot-ctl child table        # children directos del leader (no incluye children de otros routers)
ot-ctl neighbor table     # vecinos radio directos
ot-ctl history router 50  # últimos eventos de promote/demote/cost change
```

### 6.2 MAC counters delta (60s sample)

```sh
ot-ctl counters mac reset
sleep 60
ot-ctl counters mac | grep -E 'TxTotal|TxErr|TxRetry|TxDirectMaxRetry|RxErr'
```

Valores objetivo post-decisión:

- `TxDirectMaxRetryExpiry`: 0
- `TxErrAbort`: 0
- `TxErrCca`: 0-3 (baseline natural)
- `RxErrNoUnknownNeighbor`: 0

### 6.3 LwM2M activity en TB Edge

```sh
docker exec tb-edge-postgres psql -U postgres -d thingsboard_edge -c "
  with t as (select d.id, max(ts.ts) as last_ts
             from device d left join ts_kv_latest ts on ts.entity_id=d.id
             group by d.id)
  select case when last_ts is null then 'never_seen'
              when (extract(epoch from now())*1000 - last_ts) < 120000 then 'active_<2min'
              when (extract(epoch from now())*1000 - last_ts) < 600000 then 'recent_<10min'
              else 'stale'
         end as bucket, count(*)
  from t group by bucket;
"
```

Valor objetivo: **0 en `never_seen` y `stale`**, 100% en `active_<2min`.

---

## 7. Plan de implementación

### 7.1 Pre-flight (sin disrupción)

- [ ] Backup del firmware actual de los nodos (por si hay rollback)
- [ ] Mapa físico de los 60 nodos con coordenadas o ubicación nominal
- [ ] Identificación de nodos mains-powered vs battery-powered (los backbone deben ser mains)
- [ ] Build de dos firmwares: `node-backbone.bin` (mode `rdn`) y `node-leaf.bin` (mode `rn`)
- [ ] Restablecer threshold del leader temporalmente al valor planeado (ver Fase 3)

### 7.2 Fase 1 — Flash all-leaf

- [ ] Flashear los 60 nodos con `node-leaf.bin`
- [ ] En el leader: `ot-ctl routerupgradethreshold 1` (solo permite leader como router, los REED leftover no pueden subir)
- [ ] Sample de 30 min

### 7.3 Fase 2 — Discovery

- [ ] `ot-ctl child table` → lista de nodos conectados directamente al OTBR
- [ ] Lista de nodos provisionados en TB Edge sin actividad → estos son los detached
- [ ] Cruzar con mapa físico → identificar zonas muertas
- [ ] Elegir 8-12 nodos para backbone basado en cubrir las zonas muertas + redundancia

### 7.4 Fase 3 — Promoción selectiva

- [ ] Reflashear los 8-12 elegidos con `node-backbone.bin`
- [ ] En el leader: `ot-ctl routerupgradethreshold N` y `routerdowngradethreshold N+1`
- [ ] Persistir en `/etc/rc.local`
- [ ] Sample de 30 min

### 7.5 Fase 4 — Validación final

- [ ] `ot-ctl router table` reporta exactamente N+1 routers (N backbone + leader)
- [ ] `ot-ctl history router 100` muestra solo eventos de los primeros 5 min post-Fase 3
- [ ] MAC counters delta = 0 errores
- [ ] TB Edge: 60/60 con `active_<2min`
- [ ] Documentar el N final en `architecture/edge-thingsboard.md §5.6`

### 7.6 Reverso de emergencia

Si Fase 1-2 dejan demasiados nodos detached y no es práctico iterar:

```sh
# En el leader, restaurar la mitigación interim del 2026-04-27:
ot-ctl routerupgradethreshold 32
ot-ctl routerdowngradethreshold 33
```

Y reflashear los 60 nodos con `node-backbone.bin`. Esto vuelve al estado all-REED auto-balanceado — funciona para 30, pero no escala a 60. Es plan B si el discovery se rompe.

---

## 8. Referencias

### Internas

- [`docs/architecture/edge-thingsboard.md §5.6`](../architecture/edge-thingsboard.md) — config actual del edge (router thresholds aplicados)
- [`docs/runbooks/thread-mesh-health.md`](../runbooks/thread-mesh-health.md) — runbook operativo de diagnóstico
- [`docs/architecture/snapshots/edge-192.168.1.111-2026-04-27.txt`](../architecture/snapshots/) — evidencia de estado pre-fix

### Externas

- [Thread 1.3 spec, §4.7 Router-IDs](https://www.threadgroup.org/) — definición del cap de 32 routers
- [OpenThread CLI reference: `mode`](https://github.com/openthread/openthread/blob/main/src/cli/README.md#mode) — `rdn`, `rn`, `-`
- [OpenThread CLI reference: `routereligible`](https://github.com/openthread/openthread/blob/main/src/cli/README.md#routereligible) — toggle per-node
- [OpenThread thresholds (`routerupgradethreshold`, `routerdowngradethreshold`)](https://github.com/openthread/openthread/blob/main/src/cli/README.md#routerupgradethreshold)
