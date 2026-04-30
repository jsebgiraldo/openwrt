# Architecture — UNAL-Thread / ThingsBoard Edge deployment

Este folder contiene la **especificación viva** de cómo está armado el sistema en producción. La idea: cualquier agente (humano o IA) puede:

1. **Leer la spec** para entender el sistema entero sin ssh-ar a 30 nodos.
2. **Editar la spec** para proponer cambios (revisable como cualquier diff).
3. **Aplicar la spec** (siguiendo §10 / §11 de cada doc) para provisionar nuevos nodos o restaurar uno existente.
4. **Re-extraer un snapshot** del estado actual de un nodo para confirmar que coincide con la spec, o para incorporar drift no documentado.

---

## Archivos en este folder (architecture/)

| Archivo | Qué describe |
|---|---|
| [`edge-thingsboard.md`](edge-thingsboard.md) | **Edge `192.168.1.111`** — Pi 4 + EKH01 HaLow hat + OTBR (channel 25, UNAL-Thread) + ThingsBoard Edge. Edge piloto, ahora con churn por rogue PAN. |
| [`edge-r1000.md`](edge-r1000.md) | **Edge `192.168.1.175`** — Seeed R1000 + Wio-WM6108 + OTBR (channel 21, UNAL-R1000) + ThingsBoard Edge. **Edge twin con lecciones aplicadas desde día 1** (backbone selectivo, lifetime ≥60s, channel limpio, JVM cap). |
| [`snapshots/edge-<IP>-<DATE>-<context>.txt`](snapshots/) | Salidas crudas de diagnóstico/extracción. Inmutables. |

## Documentos hermanos relacionados

| Archivo | Tipo | Qué describe |
|---|---|---|
| [`../decisions/halow-carrier-compatibility.md`](../decisions/halow-carrier-compatibility.md) | ADR | Por qué R1000 + WM6108 funciona vía polling-mode driver y qué pinmap necesitaría un carrier nuevo. |
| [`../decisions/thread-mesh-role-assignment.md`](../decisions/thread-mesh-role-assignment.md) | ADR | **Topología:** cómo asignar roles (MED vs REED) en mesh Thread con 30+ nodos. Plan de escalamiento a 60+. |
| [`../decisions/lwm2m-update-rate-and-mesh-capacity.md`](../decisions/lwm2m-update-rate-and-mesh-capacity.md) | ADR | **Tráfico:** modelo de capacidad airtime + guidelines de `lifetime` LwM2M. Por qué `lifetime ≤ 5s` mata la mesh aunque host esté idle. |
| [`../decisions/edge-zero-touch-provisioning.md`](../decisions/edge-zero-touch-provisioning.md) | ADR | **Provisioning:** flow completo TB Central + edge LAN-side. Validado contra REST API; script `tools/tb-edge-claim/`. |
| [`../runbooks/thread-mesh-health.md`](../runbooks/thread-mesh-health.md) | Runbook | Diagnóstico de churn en mesh Thread — comandos, métricas, remediación. |
| [`../runbooks/tb-edge-baseline-tuning.md`](../runbooks/tb-edge-baseline-tuning.md) | Runbook | Tuning de TB Edge cuando hay presión de RAM/CPU/disco en el host. |
| [`../runbooks/lwm2m-capacity-test.md`](../runbooks/lwm2m-capacity-test.md) | Runbook | Procedimiento empírico de 5-nodos baseline + scale-up para descubrir N_max real de un edge. |

> **Convención de tipos:**
> - **Spec viva** (este folder) — describe el estado actual del sistema. Se edita con cada cambio aplicado.
> - **ADR** (`decisions/`) — captura una decisión arquitectural y su rationale. No se edita; se supersede.
> - **Runbook** (`runbooks/`) — pasos operativos para diagnosticar/remediar un síntoma. Se actualiza con experiencia operativa.

---

## Cómo usar este folder

### Caso 1 — "Provisiona un edge nuevo en otra ubicación"

1. Lee `edge-thingsboard.md` §1–§3 (overview, variables, hardware).
2. Genera valores para los `EDGE_*` y `CLOUD_ROUTING_*` (los demás se heredan del mesh existente).
3. Ejecuta §10 paso a paso (flash, dataset, SRP, Docker, mDNS, persistence).
4. Valida con §10.9 y los health checks de §11.

### Caso 2 — "Re-deployar un edge tras un fallo de hardware"

1. Restaura backup de `/opt/docker/tb-edge-data` (ver §6.3 del spec) en el nuevo hardware.
2. Aplica el resto de §10 igual que un edge nuevo, **pero con los mismos `CLOUD_ROUTING_KEY`/`SECRET`** del edge fallido.
3. Restaura `/etc/otbr/active-dataset.tlvs` para que se rejoin al mesh sin commissioning.

### Caso 3 — "Mantener la spec en sync con la realidad"

Cuando hagas cambios manuales en un edge:

```sh
ssh root@<EDGE> "$(cat <<'INSPECT'
# (script de §13 del spec)
echo "## identity"; uci get system.@system[0].hostname; cat /tmp/sysinfo/board_name; uname -r
echo "## net"; ip -br link; ip -4 -br addr; ip -6 -br addr
...
INSPECT
)" > docs/architecture/snapshots/edge-<IP>-$(date +%Y-%m-%d).txt
```

Diff el snapshot vs el último commit del spec → si hay drift no intencional, decide: ¿el spec se equivoca (actualizar) o el edge se desvió (re-aplicar)?

### Caso 4 — "Le pido a un agente que cambie X"

Pattern recomendado de prompt:

> Mira `docs/architecture/edge-thingsboard.md`. Quiero hacer **X** (e.g. "agregar un servicio MQTTS en puerto 8883", "cambiar el `CLOUD_RPC_HOST` a otra IP", "publicar un servicio HTTP custom vía SRP"). Edita el .md primero (sección donde aplique + §2 si es per-edge variable + §10 si requiere paso de replay nuevo) y luego propón el comando para aplicarlo en el edge `192.168.1.111`. No toques nada vivo hasta que apruebe el diff.

Esto separa **lo que queremos** (spec versionado) de **lo que está corriendo** (estado del nodo) y permite reviews limpios sin que el agente improvise sobre el sistema.

---

## Convenciones

- **Per-edge variables** se nombran `<MAYÚSCULAS_CON_GUIÓN_BAJO>` y están en §2 del spec del edge.
- **Secretos** (Network Key, PSKc, SAE key, cloud routing secret, postgres password) viven en el spec por replay, **pero el repo es interno**. Si en algún momento el repo se hace público, mover a `.env` no versionado y referenciar por placeholder.
- **Snapshots** son inmutables — uno por extracción, fechados. Sirven como "evidencia histórica", no se editan.
- **El spec es vivo** — sí se edita, sí se rebasa.

---

## Estado actual del cluster

| Nodo | IP LAN | Hardware | Rol | Spec |
|---|---|---|---|---|
| ekh01-de87 | 192.168.1.111 | Pi 4 + EKH01 hat | edge central — TB Edge + OTBR central | `edge-thingsboard.md` |
| r1000-wm6108-a3dd | 192.168.1.182 | Seeed R1000 + Wio-WM6108 | edge HaLow secundario (polling-mode) | (heredero del template, sin spec separada por ahora) |
| (cloud) | 192.168.1.170 | externo | ThingsBoard CE (server) — RPC en :7070 | fuera de scope (no es edge) |
| (loki/prom central) | 100.67.60.126 | Tailscale/WG | logs + métricas | fuera de scope |
