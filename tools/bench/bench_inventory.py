#!/usr/bin/env python3
# Read firmware version banner from each bench node by power-cycling
# the ESP32-C6 and capturing UART output. Writes a YAML inventory of
# what's actually on each node (vs what TB Edge thinks).
#
# Usage:
#   python3 bench_inventory.py                  # auto-detect + read all
#   python3 bench_inventory.py --port /dev/ttyACM0
#   python3 bench_inventory.py --out report.yaml
#
# Requires: pyserial (pip3 install pyserial). Already present in WSL.
#
# How a node is reset: ESP32-C6 dev boards expose EN (reset) and IO9
# (boot) on the USB-Serial DTR/RTS lines. Toggling DTR/RTS the right
# way triggers a hard reset without entering bootloader. Same trick
# esptool uses for `--before default_reset`.

import argparse
import re
import sys
import time
from pathlib import Path

import serial
from serial.tools import list_ports

# VID:PID of common USB-Serial chips on ESP32-C6 dev boards.
# 303a:1001 = native USB-CDC of ESP32-C6 (no UART chip — direct USB)
# 10c4:ea60 = SiLabs CP210x  (the one Sonoff/Seeed dev boards use)
# 1a86:7523 = WCH CH340      (cheap clones)
# 1a86:55d3 = WCH CH343      (newer)
ESP32_USB_IDS = {
    (0x303a, 0x1001): "ESP32-C6 native USB-CDC",
    (0x10c4, 0xea60): "CP210x USB-Serial",
    (0x1a86, 0x7523): "CH340",
    (0x1a86, 0x55d3): "CH343",
    (0x1a86, 0x55d5): "CH343 (alt)",
}


def detect_esp32_ports() -> list[dict]:
    found = []
    for p in list_ports.comports():
        if p.vid is None or p.pid is None:
            continue
        key = (p.vid, p.pid)
        if key in ESP32_USB_IDS:
            found.append({
                "device": p.device,
                "vid_pid": f"{p.vid:04x}:{p.pid:04x}",
                "chip": ESP32_USB_IDS[key],
                "serial": p.serial_number or "",
            })
    return found


def reset_esp32(ser: serial.Serial) -> None:
    # Sequence equivalent to esptool's `default_reset`:
    #   DTR=False (deassert), RTS=True (assert reset)
    #   sleep, then DTR=True (boot strap to "run app"), RTS=False (release reset)
    ser.dtr = False
    ser.rts = True
    time.sleep(0.1)
    ser.dtr = True
    ser.rts = False
    time.sleep(0.05)


def read_boot_window(port: str, baud: int, timeout_s: float) -> str:
    with serial.Serial(port, baud, timeout=0.2) as ser:
        ser.reset_input_buffer()
        reset_esp32(ser)

        deadline = time.monotonic() + timeout_s
        buf = bytearray()
        while time.monotonic() < deadline:
            chunk = ser.read(2048)
            if chunk:
                buf.extend(chunk)
                # Early exit once we likely have version + endpoint
                if b"REGISTERED" in buf or b"DNS-SD lookup" in buf:
                    break
    return buf.decode("utf-8", errors="replace")


# Patterns parsed from the boot log. Each is best-effort; missing fields
# return None. Once firmware-agent adds the canonical version banner
# (Capa 1.5 in coord repo brief), `version` and `sha` become reliable.
PATTERNS = {
    "zephyr_build": re.compile(r"\*\*\* Booting Zephyr OS build (\S+)"),
    "version": re.compile(r"ami-lwm2m-node\s+v?(\S+?)\s+sha=(\w+)"),
    "endpoint": re.compile(r"endpoint[:\s=]+(ami-esp32c6-[0-9a-f]+)", re.IGNORECASE),
    "thread_state": re.compile(r"Thread\s+state[:\s=]+(\w+)", re.IGNORECASE),
    "register_event": re.compile(
        r"(LWM2M_RD_CLIENT_EVENT_REGISTRATION_COMPLETE|REGISTERED|"
        r"DNS-SD lookup\s+\S+)"
    ),
}


def parse_boot_log(text: str) -> dict:
    out = {"raw_chars": len(text)}

    m = PATTERNS["zephyr_build"].search(text)
    if m:
        out["zephyr_build"] = m.group(1).rstrip("*").strip()

    m = PATTERNS["version"].search(text)
    if m:
        out["version"] = m.group(1)
        out["sha"] = m.group(2)

    m = PATTERNS["endpoint"].search(text)
    if m:
        out["endpoint"] = m.group(1)

    m = PATTERNS["thread_state"].search(text)
    if m:
        out["thread_state"] = m.group(1)

    out["lwm2m_event_seen"] = bool(PATTERNS["register_event"].search(text))
    return out


def inspect_one(port: str, baud: int, timeout_s: float, save_log_dir: Path | None) -> dict:
    info = {"port": port, "baud": baud}
    try:
        text = read_boot_window(port, baud, timeout_s)
    except serial.SerialException as exc:
        info["error"] = f"serial open/read: {exc}"
        return info

    info.update(parse_boot_log(text))

    if save_log_dir:
        save_log_dir.mkdir(parents=True, exist_ok=True)
        ts = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        port_slug = port.replace("/", "_").lstrip("_")
        log_path = save_log_dir / f"{ts}-{port_slug}.log"
        log_path.write_text(text)
        info["log_path"] = str(log_path)

    return info


def format_row(info: dict) -> str:
    port = info.get("port", "?")
    if "error" in info:
        return f"{port:25s}  ERROR: {info['error']}"
    v = info.get("version") or "UNKNOWN"
    sha = (info.get("sha") or "")[:10]
    ep = info.get("endpoint") or "?"
    state = info.get("thread_state") or ("evt!" if info.get("lwm2m_event_seen") else "?")
    return f"{port:25s}  v{v:8s}  sha={sha:10s}  ep={ep:22s}  thread={state}"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Read firmware version + endpoint from each bench node via UART"
    )
    parser.add_argument("--port", action="append", default=None,
                        help="explicit port (repeatable). Skip auto-detect.")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=8.0,
                        help="seconds to capture boot log per node (default 8)")
    parser.add_argument("--out", help="write report YAML to this path")
    parser.add_argument("--save-logs", help="write raw boot logs to this dir")
    args = parser.parse_args()

    if args.port:
        targets = [{"device": p, "chip": "(explicit)"} for p in args.port]
    else:
        targets = detect_esp32_ports()
        if not targets:
            print("No ESP32-class USB-Serial devices detected.", file=sys.stderr)
            print("If running in WSL, attach via:", file=sys.stderr)
            print("  (PowerShell admin) usbipd list", file=sys.stderr)
            print("  (PowerShell admin) usbipd attach --wsl --busid <X-Y>", file=sys.stderr)
            print("See tools/bench/README.md for details.", file=sys.stderr)
            return 1

    print(f"Inspecting {len(targets)} device(s) "
          f"(timeout={args.timeout:.0f}s each, baud={args.baud})\n")

    save_dir = Path(args.save_logs) if args.save_logs else None
    results = []
    for t in targets:
        result = inspect_one(t["device"], args.baud, args.timeout, save_dir)
        result["chip"] = t.get("chip")
        results.append(result)
        print(format_row(result))

    if args.out:
        try:
            import yaml
        except ImportError:
            print("\n--out requires PyYAML (pip3 install pyyaml). Skipped.",
                  file=sys.stderr)
        else:
            payload = {
                "ts": int(time.time()),
                "nodes": results,
            }
            Path(args.out).write_text(yaml.safe_dump(payload, sort_keys=False))
            print(f"\nWrote {args.out}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
