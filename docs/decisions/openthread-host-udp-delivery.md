# OpenThread BR — UDP delivery from mesh to host kernel

**Status:** resolved 2026-04-29 — end-to-end LwM2M working
**Date:** 2026-04-29
**Context:** R1000 + Wio-WM6108, OpenThread `thread-reference-20250612-574-g83eb368bf` (built 2026-02-16)
**Affects:** Edge `192.168.1.175` (UNAL-R1000, channel 21).

## Resolution (TL;DR)

The bug was **not** an OpenThread internal stack issue. It was a multi-layer config gap, dominated by a missing `nftables` zone for `wpan0`. Once all of the following were in place, end-to-end LwM2M registration and Observe exchanges flowed cleanly (verified with the node child rloc 0xd804 sourced from `[fd67:9823:5fe5:1:5315:6b14:fbde:5b8c]:52642`, observing `Object 10242` resources with `Token=93EC866A08009F06` and others, all completing with `2.04 Changed` ACKs):

1. **Firewall zone `thread` for `wpan0`** — without this, `nft list chain inet fw4 input` had `policy drop` and no `iifname "wpan0" jump …`, so every UDP packet from the mesh was dropped by the kernel before reaching any user-space socket. Added via `uci`, persisted in `/etc/config/firewall` (which is already in `/etc/sysupgrade.conf`).
2. **`preferred_lft forever`** for the `mleid` and OMR addresses on `wpan0`, re-applied every minute by cron in `/etc/crontabs/root`. Without this, otbr-agent re-deprecates the addresses (`preferred_lft 0sec`), which causes Linux to pick a different source address for outbound replies and breaks src/dst symmetry.
3. **SRP service announcing TB Edge at the OMR address** (`fd67:…:b221`), not at `mleid`. Re-published on every boot by `/etc/rc.local` (~30s after boot, after otbr-agent settles).
4. **TB Edge running with Docker `--network host`**, Java/Leshan binding `[::]:5683`. The host's kernel UDP demux delivers radio-originated packets to OMR/mleid into Java's socket without any extra address aliasing (no need for `lo /128` hacks).
5. **Power-cycle of the node** to clear its Zephyr CoAP backoff after long retry windows (after the path was correct).

The earlier ICMPv6 Unreachable observed in `ot-ctl history tx` was the kernel rejecting unsolicited UDP because no chain accepted the `wpan0` traffic. Once the `thread` zone existed, the path opened end-to-end. The OpenThread receive filter and `processReceive` mechanics inspected during diagnosis are healthy and not the cause.

The text below preserves the diagnosis path for future reference.

---

## Symptom (during investigation)

---

LwM2M node (Zephyr, ESP32-C6, child rloc 0xd804) sends a well-formed CoAP REGISTER (187 bytes) to the SRP-announced host address `[fd67:9823:5fe5:1:1061:43d9:fa54:b221]:5683` (TB Edge OMR address). The packet is received over 802.15.4 by the OTBR's RCP, visible via `ot-ctl history rx`. **However, the packet never reaches Eclipse Leshan listening on `[::]:5683`.**

Symptom evolution observed during diagnosis:

1. Initially: kernel emits ICMPv6 Destination Unreachable for every REGISTER (`ot-ctl history tx` shows `ICMP6(Unreach)` ~50 ms after each RX).
2. After `ot-ctl srp server disable`: ICMPv6 Unreach disappears, but packets still don't reach the user-space socket on `[::]:5683`.
3. `tcpdump -i wpan0`: shows only trel/MeshCoP traffic on UDP:19788 — **zero packets to UDP:5683** are visible at the kernel TUN, even though `ot-ctl history rx` shows them at the radio layer.

## Root cause (proven)

The OpenThread border-router stack in this build processes incoming UDP packets to "host" addresses (OMR, mleid) **entirely in its user-space ip6 stack** and does **not** inject them to the Linux kernel TUN device `wpan0`. Concretely, in `src/core/net/ip6.cpp` (`Ip6::PassToHost`):

```cpp
// line 986
case kProtoUdp:
{
    Udp::Header udp;
    IgnoreError(aMessagePtr->Read(aMessagePtr->GetOffset(), udp));
    VerifyOrExit(!Get<Udp>().IsPortInUse(udp.GetDestinationPort()), error = kErrorNoRoute);
    break;
}
```

`mReceiveFilterEnabled = true` is set unconditionally by `platformNetifSetUp()` in `src/posix/platform/netif.cpp:2303`. When SRP server is enabled, **its CoAP listener implicitly binds UDP:5683 inside the OpenThread stack** (via the SRP/CoAP plumbing), which makes `IsPortInUse(5683) → true` and triggers `kErrorNoRoute`, which the BorderRouter `RoutingManager::CheckReachabilityToSendIcmpError` (line 952-957 in the same file) translates into the ICMPv6 Unreachable we observed.

After `srp server disable`, `IsPortInUse(5683)` becomes false, the filter no longer drops the packet, and the ICMPv6 error stops. But the packet still does **not** reach the Linux kernel: somewhere between `PassToHost` and `processReceive` (the callback that does `write(sTunFd, …)` in `src/posix/platform/netif.cpp:1116`), the message is consumed.

This was reproduced and isolated by:

- Stopping TB Edge Docker container.
- Running a Python listener (`socket.AF_INET6`, `bind('', 5683)`) directly on the host.
- Sending a packet locally from the same host to the OMR/mleid address — Python receives it (loopback path).
- Sending a packet from the Thread node to the same address — Python never sees it.
- `tcpdump -i wpan0` confirms the packet never traverses the kernel TUN.
- The R1000 has `wpan0` exclusively as a `tun` virtual netdev (`link/none`, `POINTOPOINT`, type 65534). All Thread traffic goes through user-space otbr-agent.

`ot-ctl history rx` is observed at the OpenThread layer, **before** the host filter — that's why we see the packet arriving at the radio but not at the kernel.

## Build configuration confirmed

The OpenThread submodule cmake config sets:

```cmake
set(OT_PLATFORM_UDP ON  CACHE STRING "enable platform UDP" FORCE)
set(OT_PLATFORM_NETIF ON CACHE STRING "enable platform netif" FORCE)
set(OT_UDP_FORWARD OFF CACHE STRING "disable udp forward" FORCE)
```

`OT_PLATFORM_UDP=ON` and `OT_UDP_FORWARD=OFF` are mutually exclusive (`udp6.hpp:64-65`). `OT_PLATFORM_UDP` makes internal services that explicitly call `otUdpOpen` create a real Linux socket via `otPlatUdpSocket()` (`src/posix/platform/udp.cpp:232`). However, the SRP server opens its socket on `Ip6::kNetifThreadInternal` (`src/core/net/srp_server.cpp:815`), which is **internal-only** — it does not surface in `/proc/net/udp6`. The SRP server's port range is 53535–53554 (`config/srp_server.h`), not 5683, so SRP is NOT the source of `IsPortInUse(5683)=true` we initially blamed.

`Udp::IsPortInUse(aPort)` (`src/core/net/udp6.cpp:489`) only inspects the OpenThread internal `mSockets` list. It does **not** consult the Linux kernel UDP table. So whether TB Edge / Leshan binds `[::]:5683` at the OS level is irrelevant to the OT-internal filter check — the filter only blocks if some OT-internal component bound 5683.

## Test that proved the path is broken

After SRP was disabled (which removed the ICMPv6 Unreach), we tested the inverse direction: `ot-ctl udp open + bind '::' 0`, then `ot-ctl udp send fd67:…:b221 5683 -t 'PROBE'`. **Result: TB Edge / Leshan received the packet** ("UDPConnector ([0:0:0:0:0:0:0:0]:5683) received 5 bytes from [fd67:9823:5fe5:1:1061:43d9:fa54:b221]:49160"). This proves that `processReceive → write(sTunFd, …) → kernel UDP demux → Java` works **when the packet originates from the OT internal stack**.

When the packet originates from the **radio side** (a Thread node sending to OMR:5683), the path silently fails: `ot-ctl history rx` records the receipt at the radio layer, but `tcpdump -i wpan0 udp port 5683` captures zero packets, meaning `processReceive` is not invoked for these. The most likely culprit is `aMessagePtr->IsLoopbackToHostAllowed()` (`ip6.cpp:945`) — a flag set per-message that can suppress the host-delivery callback. For radio-originated messages, the message metadata may carry this flag as `false`, ending the path silently before reaching the receive filter or the receive callback.

**Action item:** when the Pi4 comes back online, dump:
- `/usr/sbin/otbr-agent --version`
- `strings /usr/sbin/otbr-agent | grep -E 'thread-reference|OPENTHREAD'`
- `tcpdump -i wpan0 'udp port 5683'` while a node tries to register, to see if packets reach the kernel TUN there.

## Options for fix

### Option A — Rebuild OpenThread with the receive filter disabled or extended (recommended)

The cleanest path. The build currently sets `otIp6SetReceiveFilterEnabled(gInstance, true)` unconditionally. We can patch this to `false`, **or** introduce a Kconfig option that exempts `:5683` from the in-use check, **or** disable the implicit SRP-server CoAP binding.

Pros:
- Predictable: every UDP packet to a host address goes to the kernel TUN, end of story.
- Scales to 60+ nodes without per-node configuration.
- No extra user-space process to maintain.

Cons:
- Requires rebuilding the OpenWrt image and reflashing.
- The filter exists for a reason: it prevents the host stack from double-processing packets that OpenThread internal services (DTLS commissioning, MeshCoP, SRP) want to handle. Disabling it broadly may have side effects on those internal services. Need to test that BorderAgent commissioning, SRP server, and DNS-SD still work.
- One viable middle ground: keep the filter on but ensure the SRP server binds on an internal-only port (not 5683), so `IsPortInUse(5683)` returns false during normal operation.

### Option B — User-space CoAP relay via OpenThread API

Write a small daemon that uses the OpenThread C API (`otUdpOpen`, `otUdpBind`) to register an internal UDP listener on `:5683`. When a packet arrives, the daemon copies the payload and forwards it via a regular Linux UDP socket to `127.0.0.1:5683` where TB Edge / Leshan is listening. Responses are relayed back.

Pros:
- No firmware rebuild.
- Localized: a single daemon plus an init script.

Cons:
- Adds an extra process and copy step (small latency hit, ~1-2 ms).
- Requires linking against the OpenThread runtime library (or compiling the daemon as a CLI app like `ot-cli-app`).
- More moving parts to maintain — risk of socket lifecycle bugs, DTLS support is non-trivial.

### Option C — NAT64 + IPv4-only LwM2M

Configure NAT64 on the BR and have the node speak IPv4-mapped CoAP via `64:ff9b::/96`. The kernel handles IPv4 demux normally.

Pros:
- Sidesteps the IPv6 host-delivery path entirely.

Cons:
- Significant config change at the BR and possibly at the node.
- NAT64 in OpenThread BR is gated by `OPENTHREAD_CONFIG_NAT64_TRANSLATOR_ENABLE` — would need rebuild anyway.
- Doesn't match the thesis goal ("LwM2M over Thread, native IPv6").

## Decision

**A** is the goal but blocks on rebuild + verification. Until then, document this finding so the Pi4 (which works) is not "lost wisdom," and so future thesis work can cite this exact root cause.

## What was applied during diagnosis (persisted)

These survive a reboot:

- Firewall zone `thread` (device `wpan0`, input/output/forward = ACCEPT) added via `uci`. `iifname "wpan0" jump input_thread` confirmed in `nft list chain inet fw4 input`. This was **not** the cause but is a prerequisite for any traffic to reach the host once Option A or B unblocks delivery.
- Cron job `* * * * * ip -6 addr change <mleid>/64 dev wpan0 preferred_lft forever valid_lft forever` already in `/etc/crontabs/root`. Continues to neutralize the otbr-agent re-deprecation drift.
- SRP service publishes TB Edge at OMR (`fd67:…:b221`), not mleid. This was a hypothesis-driven change; both addresses exhibit the same blocked path, so it's effectively neutral.

## What was tried and discarded during diagnosis

- Adding `mleid/128` and `OMR/128` as secondary `lo` addresses to force kernel local delivery via `lo` route. **No effect** — the packet never reaches the kernel demux stage at all.
- Restarting the TB Edge container with explicit JVM IPv6 flags (`-Djava.net.preferIPv6Stack=true`). **No effect** — same reason.
- Disabling `srp server`. **Removed the ICMPv6 Unreach** but did not unblock packet delivery. Confirms the filter is one of two gates; the second gate is in `processReceive` / message ownership logic.
- `ot-ctl coap stop`. **No effect** — the CoAP CLI app was not the offender.
- Running TB Edge as a Python `socket` listener outside Docker. **No effect** — eliminates Docker as a factor.
- Running `tcpdump -i wpan0 udp port 5683`. **Captured zero packets** even when `ot-ctl history rx` showed them. Confirms the kernel TUN is bypassed.

## References

- OpenThread BR commit graph at `build_deps/ot-br-posix/` (matches the binary on the R1000).
- Source files: `third_party/openthread/repo/src/core/net/ip6.cpp` (`PassToHost`, `DetermineAction`), `src/posix/platform/netif.cpp` (`platformNetifSetUp`, `processReceive`).
- Companion runbook: [`../runbooks/thread-mesh-health.md`](../runbooks/thread-mesh-health.md) — diagnosis steps for mesh churn, complementary to this ADR.
- Edge spec: [`../architecture/edge-r1000.md`](../architecture/edge-r1000.md) §10 (provisioning) and §11 (health checks).
