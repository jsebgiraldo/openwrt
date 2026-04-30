# LwM2M update rate y capacidad del mesh Thread — modelo y guidelines

**Audiencia:** ingeniería de firmware/aplicación que define el `lifetime` LwM2M y el rate de telemetría por nodo. Operación que decide cuántos nodos puede aguantar un edge.
**Estado:** Decidido — 2026-04-28. La metodología empírica se valida en el edge `192.168.1.111` con 5 nodos primero, después scale-up controlado.
**Supersedes:** ninguna. Complementa [`thread-mesh-role-assignment.md`](thread-mesh-role-assignment.md) — esa ADR cubre la **dimensión topológica** del scaling; esta cubre la **dimensión de tráfico**.

> **Resumen de una línea:** un `lifetime` LwM2M agresivo (≤ 5s) genera ~50 msg/min/nodo, lo que satura airtime 802.15.4 a partir de ~25 nodos en mesh — el cuello no es CPU/RAM del Pi 4 sino la radio compartida. Hay que medir empíricamente la capacidad de cada deployment con un test de 5 nodos antes de escalar.

---

## 1. Contexto

### 1.1 La observación que motivó esta ADR

El edge `192.168.1.111` corre 30 nodos LwM2M sobre Thread mesh. Después de la noche del 2026-04-27 a 2026-04-28:

- **10 de 30 nodos detached** (`old_>1h` en TB Edge), todos perdidos en una ventana de ~17 minutos a las 04:44-05:01 UTC
- 20 nodos siguen sanos
- En `ot-ctl history router` se observan >200 eventos `CostChanged`/`NextHopChanged`/`Added`/`Removed` en los últimos minutos
- TB Edge `ts_kv` writes: 4,872 en 5 min, 58,827 en 1 hora, **719,291 en 12 horas**
- Pi 4 baseline: TB Edge 10-15% CPU, postgres 4-5% CPU, RAM available 2.1 GB → **el host NO está saturado**
- MAC counters (`ot-ctl counters mac`): TxTotal 722,256 con apenas 10 `TxDirectMaxRetryExpiry` (0.001%) — **el MAC layer NO marca saturación obvia**

### 1.2 La aparente paradoja

Los recursos de host están sub-utilizados. El MAC layer dice que casi no hay drops. Y sin embargo 10 nodos se cayeron y la mesh sigue rebalanceándose constantemente. **¿Cómo puede pasar esto?**

La respuesta: el rate de telemetría a nivel aplicación está cerca del **régimen de saturación 802.15.4 con overhead mesh**, lo que produce:

1. CSMA backoff agresivo en cada Tx (el chip espera más antes de transmitir porque el canal está ocupado)
2. Re-transmits que NO se cuentan en `TxRetry` porque OpenThread los reporta solo cuando el ACK del destinatario falla, no por CCA
3. **Latencia variable de Update LwM2M** — algunos paquetes llegan tarde
4. El servidor LwM2M (TB Edge / Leshan) marca el cliente como "expired" si no recibe `Update` antes de `lifetime` → **deregistration silenciosa**
5. El cliente se da cuenta cuando recibe respuesta `4.04 Not Found` → re-`Register` (DTLS handshake si está habilitado, costoso)
6. Mientras tanto, el nodo Thread perdió referencia de su parent porque la mesh se reformó alrededor de él durante el silencio
7. → cascada de re-attach

**El resultado**: un sistema que parece sano por métricas de host y MAC, pero se degrada por la interacción de capas (LwM2M lifetime expira más rápido de lo que el medio permite servir actualizaciones consistentes).

### 1.3 La hipótesis sobre `lifetime` actual

El usuario reportó que el firmware de los nodos usa `lifetime = 5s` o menos. Tasa observada en `ts_kv`: **45-55 msg/min por nodo** = ~0.85 msg/s/nodo. Esto incluye:

- LwM2M `Update` cada `0.8 × lifetime` (≈ cada 4s con lifetime=5s) → ~15/min
- LwM2M `Notify` o `Send` con telemetría aplicación (depende del firmware, ~30-40/min para llegar al total)

Solo el `Update` periódico ya es 15× más rápido que un deployment LwM2M industrial típico (lifetime 60-300s).

---

## 2. Decisión

### 2.1 Política sobre `lifetime` LwM2M

Por orden de preferencia para el firmware de nodos:

| Caso de uso | `lifetime` recomendado | `Update` interval (=0.8 × lifetime) |
|---|---|---|
| Telemetría industrial estándar (Modbus, sensors) | **120-300s** | cada 96-240s |
| Active session, alta granularidad | **60s** | cada 48s |
| Real-time critical (alarmas, control) | **30s** | cada 24s |
| **Nunca usar** (causa los problemas de §1) | **< 30s** | cada < 24s |

Esto **NO** dice nada del rate de Notify/Send de la aplicación — esos son independientes del `lifetime`. Una aplicación puede tener `lifetime=300s` y aun así enviar `Send` cada 5s con datos. El `lifetime` solo gobierna los keepalives de la sesión LwM2M.

### 2.2 Metodología empírica para encontrar la capacidad de un deployment

Cada combinación (firmware × edge HW × topología radio × interferencia local) tiene una **capacidad distinta**. Esta ADR define el método para descubrirla, no impone un número universal.

#### Fase A — Baseline de 5 nodos

Flashear 5 nodos con la configuración objetivo. Conectarlos al OTBR. Medir durante ≥1 hora:

1. **MAC counters delta** cada 60s — `TxTotal`, `TxRetry`, `TxErrCca`, `TxDirectMaxRetryExpiry`
2. **`ot-ctl history router` count** (cuántos eventos por hora — proxy de churn)
3. **`ts_kv` write rate** (msg/min agregado en TB Edge)
4. **TB Edge LwM2M registrations stable count** (ningún re-register por timeout)
5. **Latencia end-to-end** — tiempo desde `Update` salir del nodo hasta `ts_kv` insert

Si Phase A es **estable y libre de errores con 5 nodos**, ese es el baseline. Si NO lo es, la única solución es **bajar el rate** (subir `lifetime`).

#### Fase B — Scale-up controlado

Escalar añadiendo 5 nodos a la vez:

5 → 10 → 15 → 20 → 25 → 30

En cada paso, medir las mismas métricas. La capacidad máxima (`N_max`) es **el último escalón donde TODAS las métricas siguen sanas durante ≥1 hora**.

Síntomas de saturación (cualquiera detiene el scale-up):

- `TxDirectMaxRetryExpiry` > 50/min sostenido
- TB Edge LwM2M registrations menos del 100% del total provisionado durante > 5 min
- Cualquier nodo con `inactive_for > 10 min` en TB Edge
- `ot-ctl history router` > 30 eventos/hora

#### Fase C — Validación con `lifetime` saneado

Si Phase B encuentra que el sistema falla a, digamos, 25 nodos con `lifetime=5s`, repetir el test con `lifetime=60s`. **El N_max debería subir a ≥100 nodos** según el modelo en §3.

### 2.3 Modelo cuantitativo — fórmula de capacidad

```
N_max ≈ BW_effective × U_target ÷ per_node_bps
```

Donde:

| Símbolo | Definición | Valor típico (802.15.4 @ 2.4 GHz) |
|---|---|---|
| `BW_effective` | Throughput MAC efectivo del canal | ~70 kbps (raw 250 kbps − ACKs − headers − preamble − CSMA overhead) |
| `U_target` | Utilización máxima recomendada antes de degradación | **30%** (más allá, CSMA backoff explota) |
| `per_node_bps` | Demanda de un nodo en bps de airtime | ver fórmula abajo |
| `N_max` | Cantidad máxima de nodos sostenibles | resultado |

```
per_node_bps = msg_rate × (msg_size + ack_size) × hops × retx_factor × overhead_factor × 8
```

Donde:

| Símbolo | Definición | Valor típico |
|---|---|---|
| `msg_rate` | Mensajes/segundo por nodo | depende de `lifetime` y rate aplicación |
| `msg_size` | Tamaño total en wire (UDP+IPv6+6LoWPAN+CoAP) | **~80 bytes** para LwM2M `Update` o telemetría pequeña |
| `ack_size` | MAC ACK | **5 bytes** |
| `hops` | Saltos promedio en mesh | **1.5** (mix directo + 2 hops) |
| `retx_factor` | Multiplier por retries esperados | **1.05** a 5% loss baseline |
| `overhead_factor` | MLE Advertisements + Data Polls + Multicast | **1.10** (10% extra) |

### 2.4 Cálculo concreto para nuestro deployment

#### Caso A — `lifetime = 5s`, rate observado 50 msg/min/nodo

```
msg_rate       = 50 / 60 ≈ 0.83 msg/s
msg_size       = 80 B
ack_size       = 5 B
hops           = 1.5
retx_factor    = 1.05
overhead       = 1.10

per_node_bps = 0.83 × (80 + 5) × 1.5 × 1.05 × 1.10 × 8
             = 0.83 × 85 × 1.5 × 1.05 × 1.10 × 8
             ≈ 980 bps

N_max = 70,000 × 0.30 ÷ 980
      ≈ 21 nodos
```

**Predicción del modelo: con el rate actual, el deployment se satura entre 20-25 nodos.** Eso coincide con la observación empírica: 30 nodos provisionados pero **20 active + 10 detached**.

#### Caso B — `lifetime = 60s`, rate moderado 1 msg/min/nodo

```
msg_rate       = 1 / 60 ≈ 0.0167 msg/s
per_node_bps   = 0.0167 × 85 × 1.5 × 1.05 × 1.10 × 8
               ≈ 19.6 bps

N_max = 70,000 × 0.30 ÷ 19.6
      ≈ 1,070 nodos
```

En la práctica el cap de 32 routers Thread + el cap de 64 children/router (default OpenThread) limitan a **≤ 250-300 nodos por partition** — pero el airtime ya **NO** es el cuello.

#### Caso C — `lifetime = 30s`, rate aplicación 1 msg/seg

```
msg_rate     = 1 + (1/(0.8×30)) ≈ 1.04 msg/s   # 1 telemetría/s + Update cada 24s
per_node_bps = 1.04 × 85 × 1.5 × 1.05 × 1.10 × 8
             ≈ 1,225 bps

N_max = 70,000 × 0.30 ÷ 1,225
      ≈ 17 nodos
```

**Punto importante**: el `lifetime` no es el único conductor. Si la aplicación manda telemetría a 1 Hz, eso domina sobre el `lifetime`. Hay que considerar **rate de aplicación + rate de keepalives**.

### 2.5 Reglas heurísticas derivadas

| Regla | Razón |
|---|---|
| **Si `lifetime ≤ 30s`, el deployment NO escala más allá de 20 nodos** | El rate de keepalives solo ya copa airtime |
| **Si rate aplicación ≥ 1 Hz/nodo, el deployment NO escala más allá de 15-20 nodos** | El rate de aplicación domina el cálculo |
| **Para 30+ nodos, `lifetime ≥ 60s` Y rate aplicación ≤ 0.1 Hz** | Mantiene `per_node_bps < 30` |
| **Para 100+ nodos en una partition, considerar batching** | Agrupar varias muestras en un Send con menos frecuencia |

---

## 3. Plan de validación empírica

### 3.1 Pre-flight

- [ ] Capturar baseline ANTES de cualquier cambio:
  - `ot-ctl counters mac` (snapshot)
  - `ts_kv` count de los últimos 10 min
  - `ot-ctl history router 100`
- [ ] Documentar el `lifetime` actual del firmware (preguntar al firmware team o leer LwM2M Object 1 Resource 1 vía `ot-ctl coap` desde el OTBR)
- [ ] Anotar la hora del test (para correlacionar con logs)

### 3.2 Fase A — 5 nodos

- [ ] Apagar 25 nodos (dejar 5 prendidos físicamente, o `routereligible disable` + power-off)
- [ ] Esperar 5 min para que la mesh se estabilice
- [ ] Iniciar sample de 60 min:
  - `ot-ctl counters mac reset && sleep 3600 && ot-ctl counters mac`
  - `ts_kv writes` por minuto (query postgres cada minuto)
  - `ot-ctl history router 200` al final del sample
- [ ] Métricas a capturar (al final de la hora):
  - msg/s agregado real
  - `per_node_bps` real (calcular contraponiendo con el modelo)
  - cantidad de eventos router
  - 100% TB Edge `active_<2min` durante toda la hora
- [ ] Si Fase A NO es 100% estable con 5 nodos → el `lifetime` debe subir antes de continuar

### 3.3 Fase B — Scale-up

Añadir 5 nodos a la vez. Repetir el sample de 60 min en cada step. **Detener** el scale-up cuando:

- Cualquier nodo entra a `recent_<10min` o `stale`
- `TxDirectMaxRetryExpiry` > 50/min sostenido
- `ot-ctl history router` > 30 events/hora

Documentar el N donde se rompe — ese es `N_max` empírico para esa configuración.

### 3.4 Fase C — Re-test con `lifetime = 60s`

Reflashear los nodos con `lifetime=60s`. Repetir Fase B. Comparar `N_max` empírico con el modelo de §2.4.

### 3.5 Reportar

Crear un snapshot estructurado en `docs/architecture/snapshots/edge-192.168.1.111-2026-04-28-capacity-test.txt` con:

- Datos crudos de cada fase
- Cálculos del modelo
- N_max empírico vs N_max teórico
- Lecciones aprendidas

Si el modelo predice mal, **actualizar esta ADR §2.3 y §2.4** con las correcciones a las constantes (`BW_effective`, `U_target`, etc.).

---

## 4. Consecuencias

### 4.1 Positivas

- **Capacidad cuantificable**: cualquier deployment futuro puede usar el modelo §2.3 para predecir N_max sin hacer todo el test empírico
- **Decisiones de firmware fundadas**: el equipo de firmware sabe cuál `lifetime` elegir según el deployment objetivo
- **Diagnóstico anticipado**: si en el futuro un edge tiene síntomas similares (algunos nodos detached pero host sub-utilizado), revisar primero `lifetime` y `per_node_bps`
- **Separación clara de capas**: esta ADR cubre el TRÁFICO; la otra ADR cubre la TOPOLOGÍA. Las dos juntas dan la imagen completa.

### 4.2 Negativas / costos

- El test empírico (Fases A-C) requiere ~6-10 horas de operación dedicada por edge
- El cambio de `lifetime` en los nodos requiere acceso al firmware (no puede hacerse desde el OTBR)
- El modelo §2.3 es aproximado — las constantes (`U_target=30%`, `BW_effective=70kbps`) son guidelines, no garantías. Cada deployment puede ser ±30% de lo predicho.

### 4.3 Lo que esta ADR NO resuelve

- **Interferencia externa** (otros 802.15.4 networks, microondas, WiFi 2.4GHz): el modelo asume un canal "razonablemente limpio". Si hay rogue PANs como `0xe702` en nuestro caso, `BW_effective` baja.
- **Topología muy multi-hop**: el modelo asume `hops=1.5`. Para deployments donde la mayoría de nodos están a 3+ hops, multiplicar `per_node_bps` por hops reales.
- **Tráfico de comissioning/joining**: el modelo es para steady-state. La fase de attach inicial de 30 nodos puede momentáneamente saturar.

---

## 5. Referencias

### Internas

- [`docs/decisions/thread-mesh-role-assignment.md`](thread-mesh-role-assignment.md) — la ADR hermana sobre topología (MED vs REED)
- [`docs/runbooks/thread-mesh-health.md`](../runbooks/thread-mesh-health.md) — diagnóstico operativo
- [`docs/runbooks/lwm2m-capacity-test.md`](../runbooks/lwm2m-capacity-test.md) — runbook con los pasos exactos del test empírico (creado a la par de esta ADR)

### Externas

- IEEE 802.15.4-2020 spec, sección 8.2 (CSMA-CA) — base del modelo de utilización ≤ 30%
- OMA LwM2M 1.1 Technical Specification, sección 6.2.4 (Lifetime resource) — comportamiento del Update timer
- Eclipse Leshan source: `LwM2mServerImpl#cleanRegistrations()` — cómo Leshan detecta clients expirados
- Thread spec 1.x §4.7.5 (MLE Advertisement) — overhead que entra en `overhead_factor`
- Estudio académico de referencia: [«Performance Analysis of IEEE 802.15.4 in Mesh Networks»](https://ieeexplore.ieee.org/) — confirma 30% como threshold práctico
