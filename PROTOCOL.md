# Black Shark MagCooler 5 Pro — BLE protocol notes

Reverse-engineered against a real device (advertises as `Black Shark MagCooler 5pro`).
Official app: Shark Arsenal (`com.blackshark.peripheral.community`), a Flutter iOS
app running on Apple Silicon. Model family in-app: `br6x`.

## Connection

| Item | Value |
|---|---|
| Device name | `Black Shark MagCooler 5pro` |
| Control service | `0000A0A0-3C17-D293-8E48-14FE2E4DA212` |
| `A001` | writeWithoutResponse — **commands go here** |
| `A002` | notify — telemetry + command replies |
| `A003` | notify — events (nothing observed yet) |
| OTA service | `00010203-0405-0607-0809-0A0B0C0D1912` — **do not poke** |

No pairing, bonding, or encryption: reads and writes succeed with no auth.

### Sharing the device with the official app

The cooler accepts two centrals **only if the official app connects first**.
Connect in Shark Arsenal, *then* attach our app (it uses
`retrievePeripherals(withIdentifiers:)`). Attaching first locks the official app out.

## Frame format

    [0]  0x80 | total_length     (0x80 bit set = message FROM device)
    [1]  opcode
    [2…] payload

Confirmed by observation: a 9-byte frame starts `0x89`, a 5-byte frame `0x85`,
an 11-byte frame `0x8b`. Replies echo the opcode of the request.

Host→device frames use the same shape without the 0x80 bit: `[len][opcode][payload…]`.
A bare `02 <opcode>` query is accepted and sometimes answered.

## Telemetry — opcode 0x06 (unsolicited, ~every 2s on A002)

    89 06 20 00 08 2b d4 0d 13
    ^^ ^^ ^^ ^^ ^^ ^^ ^^^^^ ^^
    |  |  |  |  |  |  |     device power, watts
    |  |  |  |  |  |  fan RPM, uint16 LITTLE-endian (0x0DD4 = 3540)
    |  |  |  |  |  hot end temp, °C
    |  |  |  |  cold end temp, °C
    |  |  |  reserved (always 0x00 seen)
    |  |  flags/mode (always 0x20 seen, does not track power mode)
    |  opcode 0x06
    0x80 | 9

Verified against the official app UI: Cold 9 °C / Hot 43 °C / 3540 RPM / 19 W.

## Command acknowledgement — opcode 0x05

After the official app changes a setting, the device emits:

    85 05 00 00 01        # 01 = success

Identical for every power mode, so it is a generic ACK, not a mode echo.

## Power modes (observed effect, commands NOT yet known)

| Mode | Fan RPM | Power |
|---|---|---|
| Silent | ~3540 | 19 W |
| Smart (default) | 3540–4830 | 19 W |
| Overclock | ~4890 | 34 W |
| Custom | slider, 5 levels | 26 W at level 3 |

## Opcodes that answer a bare `02 <op>` query

Replies are intermittent and their payloads vary between identical queries, so
these are recorded raw and not yet interpreted:

| Opcode | Example reply |
|---|---|
| 0x05 | `85 05 23 79 01` |
| 0x21 | `85 21 08 3d 03`, `85 21 05 a8 00` |
| 0x49 | `8b 49 07 a7 01 c7 08 a3 85 33 04` |
| 0x61 | `85 61 0a e7 03` |
| 0x86 | `89 86 21 c9 04 2d a2 12 1a` — tail matches telemetry fields |
| 0xa5 | `85 a5 20 71 01` |
| 0xab | `89 ab 14 7b 01 0f 00 00 00` |
| 0xe1 | `85 e1 36 96 01` |
| 0xe4 | `85 e4 0d 33 00` |

## Probing opcode 0x05 (the likely command opcode)

Sending `[len] 05 <param> <value>` to A001 gets back `85 05 <param> <value> <status>`
— the device **echoes the payload back**. Two observations pin this down:

- Repeating the *same* 3-byte frame `03 05 01` returned a different third byte each
  time (`4d`, `1a`, `65`): the frame is one byte short, so the device echoes
  uninitialised buffer memory.
- Four-byte frames echo exactly what was sent (`04 05 01 00` → `85 05 01 00 00`,
  `04 05 01 01` → `85 05 01 01 00`).

The trailing byte looks like a status: every frame we constructed came back `00`,
while the ACK produced by the *official* app is `85 05 00 00 01`. So `01` is
presumably "accepted" and our frames are being rejected — something in the payload
(a required value range, or a checksum/sequence field) is still missing.

Replies are also intermittent: frames with arbitrary payloads (`05 05 aa bb cc`)
draw no reply at all, suggesting the device validates parameters and stays silent
on invalid ones. That makes probe-and-observe an unreliable oracle.

## PacketLogger on macOS 27 — does not capture

`PacketLogger.app` (Additional Tools for Xcode 26) installs and runs, has the
`com.apple.bluetooth.system` entitlement, and File ▸ New macOS Trace opens a live
window — but it records **0 packets** while BLE telemetry is demonstrably flowing.
No output on stderr, nothing in the unified log. Running it as root, or installing
Apple's Bluetooth logging configuration profile, is the untested next step.

## Open question — the write commands

The exact bytes the official app writes to `A001` are still unknown. macOS blocks
every free way to observe them for an iOS-on-Mac app:

- unified log redacts ATT traffic (`com.apple.bluetooth` yields nothing)
- `lldb` attach is denied even though `Runner` is signed `flags=0x0`
- `DYLD_INSERT_LIBRARIES` is stripped by AMFI / library validation

Remaining options: Apple's **PacketLogger** (free, in "Additional Tools for Xcode",
needs an Apple ID) which records the exact writes; or continued probing of `A001`
using the ACK + telemetry feedback loop.

## Status byte confirmed (and why guessing fails)

Sending `05 05 00 00 01` returns `85 05 00 00 00`. Bytes [2] and [3] are echoed
from the request, but [4] is *not* an echo — we sent `01` and the device replied
`00`. Since the official app's ACK for the same opcode ends in `01`, byte [4] is a
result code: `01` accepted, `00` rejected.

Our frames are therefore parsed but refused even with the same visible parameters,
so the genuine command carries an additional field we cannot see — most likely a
checksum, sequence counter, or session token. Brute-forcing that blind is not viable.

## Capture avenues, all closed on this Mac

| Route | Result |
|---|---|
| PacketLogger live macOS trace | 0 packets, even running as root |
| Unified log (`com.apple.bluetooth`) | ATT traffic redacted |
| `lldb` attach to Runner | denied by the system |
| `DYLD_INSERT_LIBRARIES` hook | stripped by AMFI / library validation |
| App's data container | TCC-protected, unreadable without Full Disk Access |

### Most promising remaining route: capture from an iPhone

PacketLogger has **File ▸ New iOS Trace**, which records Bluetooth traffic from a
tethered iOS device. Installing Apple's Bluetooth logging profile on an iPhone,
tethering it over USB, and driving Shark Arsenal *on the phone* would yield the
exact writes that macOS refuses to expose locally.
