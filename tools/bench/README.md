# Bench testsuite — UART introspection of LwM2M nodes

## Architecture

```
R1000 (192.168.1.175)  ─── Router ─── PC (WSL2 + Windows)
   ├── OTBR / Border Router                │
   ├── TB Edge / Leshan                    │
   └── Production mesh (UNAL-R1000)        │
                                           │
                                           USB Hub
                                              ├── bench node 1   (USB-Serial)
                                              ├── bench node 2
                                              ├── bench node 3
                                              ├── bench node 4
                                              └── bench node 5
```

The 5 bench nodes join the **production R1000 mesh** like any other node
(no separate bench mesh — the bench is just "5 nodes I can introspect
via UART"). What makes them "bench" is that the edge-agent in WSL has
direct serial access to them, in addition to seeing them via TB Edge.

## Capa 1 — `bench_inventory.py` (current)

Power-cycles each node by toggling DTR/RTS, captures the boot log, and
parses out:

- Zephyr build ID
- `ami-lwm2m-node` version + git sha (when firmware-agent adds the
  banner — see coord repo, brief on Capa 1.5)
- Endpoint name (`ami-esp32c6-XXXX`)
- Thread state / first LwM2M event seen

Run:

```sh
# Auto-detect all attached ESP32-class USB-Serial devices
python3 tools/bench/bench_inventory.py

# Single port, save raw log
python3 tools/bench/bench_inventory.py --port /dev/ttyACM0 \
        --save-logs tools/bench/logs/

# Full report to YAML for archival
python3 tools/bench/bench_inventory.py \
        --out reports/bench-$(date -u +%Y%m%dT%H%MZ).yaml \
        --save-logs reports/logs/
```

## Capa 2 — Zephyr shell (planned)

Once firmware-agent ships a `--variant med-debug` build with
`CONFIG_SHELL=y`, this directory will gain `bench_shell.py` to drive
introspection commands without resetting the node:

```
uart> version
uart> lwm2m status
uart> lwm2m discover-now
uart> mesh status
```

## Capa 3 — pytest harness (later)

Reproducible end-to-end tests (e.g. "rotate edge mleid → assert node
re-resolves and re-registers within 5 min") under `tests/bench/`.

## How to attach USB devices to WSL2

WSL2 does not see Windows USB devices by default. Use `usbipd-win`
to bridge them.

### One-time setup (Windows side)

1. Install `usbipd-win`:
   ```powershell
   winget install --interactive --exact dorssel.usbipd-win
   ```
2. Reboot once after install.
3. (Inside WSL2 — Linux side) install `linux-tools-generic`:
   ```sh
   sudo apt install linux-tools-generic hwdata
   ```
   (already present on Ubuntu 22.04+ / Debian 12+).

### Per-session attach (Windows side, run in admin PowerShell)

```powershell
# 1. List all USB devices Windows knows about
usbipd list

# Find the 5 ESP32-C6 boards. Look for one of:
#   VID 303a:1001  (native USB-CDC)
#   VID 10c4:ea60  (CP210x)
#   VID 1a86:7523  (CH340)
# Note the BUSID column (e.g. "2-3", "2-4", ...).

# 2. Bind each one (only first time per device):
usbipd bind --busid 2-3
usbipd bind --busid 2-4
# ... etc

# 3. Attach to WSL (every session — usbipd auto-attach is also possible):
usbipd attach --wsl --busid 2-3
usbipd attach --wsl --busid 2-4
# ... etc
```

After `attach`, the device shows up in WSL as `/dev/ttyACM*` (native
CDC) or `/dev/ttyUSB*` (UART chips). Verify:

```sh
# inside WSL
ls -la /dev/ttyACM* /dev/ttyUSB* 2>/dev/null
```

### Auto-attach (recommended for daily use)

```powershell
# Once per device — keeps re-attaching on every reconnect/reboot:
usbipd attach --wsl --busid 2-3 --auto-attach
```

Run this in a long-lived PowerShell window. Or wire it into a Windows
scheduled task for boot.

### Reset / reboot quirks

When the ESP32 resets itself (which `bench_inventory.py` does to
capture the boot banner), the USB endpoint briefly disappears and
re-enumerates. Two scenarios:

- **Native USB-CDC** (VID 303a): Windows sees the same device come
  back instantly. With `--auto-attach`, WSL re-attaches in ~200 ms.
  Sometimes `bench_inventory.py` will see a half-second disconnect —
  this is expected, the script handles it via `serial.Serial(...)`
  re-open inside the timeout window.
- **External USB-Serial chip** (CP210x / CH340): the chip stays on
  USB during MCU reset, so no enumeration churn. This is the easier
  case; if your boards have a CP210x, ignore the disconnect note.

If `bench_inventory.py` fails with `Permission denied`, add yourself
to the `dialout` group:

```sh
sudo usermod -aG dialout $USER
# then `exec newgrp dialout` or open a new shell
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `No ESP32-class USB-Serial devices detected` | nothing attached, or attached only to Windows | `usbipd attach --wsl ...` from PowerShell |
| `Permission denied: '/dev/ttyACM0'` | not in `dialout` group | `sudo usermod -aG dialout $USER` + new shell |
| Boot log empty / only garbage | wrong baud rate | check `--baud`. Zephyr default is `115200`; some boards run at `1000000` |
| Banner missing version/sha | firmware doesn't print it yet | wait for firmware-agent Capa 1.5 (see coord repo) |
| USB drops during reset | normal for native USB-CDC | wait ~1 s; the script's read loop handles it |

## Brief in coord repo

The handshake with firmware-agent for Capa 1.5 (version banner) and
Capa 2 (`--variant med-debug` shell build) lives in
`unal-thread-coordination/inbox/from-edge/` — see the most recent
brief tagged `bench-testsuite`.
