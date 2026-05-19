# Runbook — Bench OTBR on Pi4 + EKH01

**Cuándo usar:** querés un border-router de prueba aislado para iterar firmware/test/debug sin tocar la mesh de producción del R1000 (`192.168.8.176`).

**No-goals:** este bench **no** corre TB Edge ni publica `_lwm2m._udp` por SRP. Es una mesh Thread limpia con OTBR — punto. Si después querés cargarle TB Edge encima, copiá el bloque Docker del runbook de R1000.

---

## Aislamiento vs producción

| | Producción (R1000) | Bench (Pi4) |
|---|---|---|
| IP | `192.168.8.176` | DHCP del router (LAN) |
| Channel Thread | **21** | **15** |
| Network name | `UNAL-R1000` | `UNAL-BENCH` |
| PAN ID | `0x41ae` | random (cada init genera uno nuevo) |
| Network Key | producción | random fresca |
| TB Edge | sí | no |
| SRP publica `_lwm2m._udp` | sí | no |

Channel 15 vs 21 = ≥6 canales de separación → cero co-canal interference. Los nodos del bench **no pueden** unirse a producción y viceversa (network key distinto), aunque oigan los beacons del otro.

---

## 1. Flashear la imagen

La imagen ya está construida en este repo:

```sh
ls -lh bin/targets/bcm27xx/bcm2711/openwrt-morse-2.9-dev-mm6108-ekh01-spi-squashfs-sysupgrade.img.gz
# 110M, sha256: c0aea0934b5822c4e01b3d8a326606472dba960f1f2d3a759c11371a651f7b67
```

Si tu EKH01 hat tiene MM8108 en vez de MM6108, usá `mm8108-ekh01-spi` en lugar de `mm6108-ekh01-spi`. Si va vía SDIO en vez de SPI, usá `mmx108-ekh01-sdio`.

Decompresión + dd a la SD card (reemplazá `/dev/sdX` con la tuya — verificá con `lsblk` antes para no destruir un disco productivo):

```sh
zcat bin/targets/bcm27xx/bcm2711/openwrt-morse-2.9-dev-mm6108-ekh01-spi-squashfs-sysupgrade.img.gz \
    | sudo dd of=/dev/sdX bs=4M status=progress oflag=direct conv=fsync
sync
```

## 2. Primer boot

1. Metés la SD en el Pi4, le conectás el EKH01 hat, le ponés cable de red al WAN, y la enciendes.
2. La interfaz `eth0` arranca como WAN con DHCP. Buscá la IP en tu router o:
   ```sh
   # desde tu PC, buscá la MAC del Pi4 en el ARP table del router
   ip neigh | grep -i 'dc:a6:32\|b8:27:eb\|e4:5f:01'
   ```
3. SSH (sin password por default en first boot):
   ```sh
   ssh root@<PI4_IP>
   passwd   # ponele password para que SSH lo acepte después
   ```

## 3. Correr `bench-otbr-init.sh`

```sh
# desde tu PC
scp tools/bench/bench-otbr-init.sh root@<PI4_IP>:/tmp/
ssh root@<PI4_IP> sh /tmp/bench-otbr-init.sh
```

Esperá la cola del summary que imprime el script. Debe decir `thread state: leader`, `channel: 15`, `networkname: UNAL-BENCH`.

El script es idempotente — re-correrlo no hace daño.

## 4. Sanity checks

Desde el Pi4:

```sh
ot-ctl state            # leader
ot-ctl br state         # running
ot-ctl ipaddr           # debe mostrar OMR + mleid
ot-ctl networkname      # UNAL-BENCH
ot-ctl channel          # 15
```

Desde tu PC (suponiendo `tools/bench/bench_inventory.py` corriendo contra nodos USB):

```sh
# Una vez tengas un nodo flasheado con UNAL-BENCH dataset, debería
# attacharse al Pi4. El bench_inventory.py te muestra qué firmware
# tiene cada nodo independientemente de si la mesh anda.
python3 tools/bench/bench_inventory.py --port /dev/ttyACM0
```

## 5. Cargar el dataset en los nodos bench

Tomá el TLV blob:

```sh
ssh root@<PI4_IP> cat /etc/otbr/bench-dataset.tlvs
# imprime algo como: 0e080000000000010000000300001535...
```

En el nodo bench (Zephyr LwM2M), antes de bootear con la imagen normal podés:

- Opción A — commissioning manual via OT shell (si el firmware tiene `CONFIG_SHELL`):
  ```
  uart> ot dataset set active <TLV_HEX>
  uart> ot ifconfig up
  uart> ot thread start
  ```
- Opción B — overlay temporal con los mismos `THREAD_NETWORK_NAME`, `THREAD_CHANNEL`, `THREAD_NETWORK_KEY`, etc., del bench, hardcodeados en `prj.conf` (el firmware soporta esto vía las macros `CONFIG_OPENTHREAD_*`).

Opción A es preferida porque podés rotar datasets sin reflashear.

## 6. Rotar dataset (forzar re-commissioning de todos los nodos)

Útil para reproducir escenarios de "el OTBR cambió, ¿el firmware se recupera?":

```sh
ssh root@<PI4_IP> "rm /etc/otbr/bench-dataset.tlvs && sh /tmp/bench-otbr-init.sh"
```

El script genera un dataset fresco (random keys / panid / extpanid). Channel y networkname se mantienen.

## 7. Recovery

| Síntoma | Acción |
|---|---|
| `ot-ctl state = disabled` post-boot | `/etc/otbr/reapply-dataset.sh` debería ejecutarse desde `/etc/rc.local`. Verificá `/tmp/reapply-dataset.log`. |
| `Pi4 no aparece en LAN` | Asegurate que el EKH01 hat esté bien encajado; sin él el morse driver falla y a veces tira el boot. |
| `dataset.tlvs vacío post-sysupgrade` | Está en `/etc/sysupgrade.conf` — verificá `grep otbr /etc/sysupgrade.conf`. Si falta, agregarlo y `sysupgrade -k` para que respete keep-config. |

## Referencias

- Spec de R1000 (homólogo de producción): [`../architecture/edge-r1000.md`](../architecture/edge-r1000.md)
- Mesh health diagnostics (mismos comandos aplican al bench): [`thread-mesh-health.md`](thread-mesh-health.md)
- Bench testsuite (UART introspection de nodos atachados a la PC): [`../../tools/bench/README.md`](../../tools/bench/README.md)
- Init script: [`../../tools/bench/bench-otbr-init.sh`](../../tools/bench/bench-otbr-init.sh)
