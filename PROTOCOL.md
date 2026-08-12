# Black Shark MagCooler 5 Pro — BLE protocol

Reverse-engineered against a real device (advertises as `Black Shark MagCooler 5pro`).
Commands below are **verified**: sent from this repo's app and confirmed by the
cooler's own telemetry and by the official app's UI.

## Connection

| Item | Value |
|---|---|
| Device name | `Black Shark MagCooler 5pro` |
| Control service | `0000A0A0-3C17-D293-8E48-14FE2E4DA212` |
| `A001` | writeWithoutResponse — commands |
| `A002` | notify — telemetry and command replies |
| `A003` | notify — events (nothing observed) |
| OTA service | `00010203-0405-0607-0809-0A0B0C0D1912` — leave alone |

No pairing, bonding, or encryption.

## Frame format

    host → device:   [total_length] [opcode] [payload…]
    device → host:   [0x80 | total_length] [opcode] [payload…]

The length byte counts the whole frame including itself. A reply carries the
same opcode as the request, so `05 06 …` is answered by `89 06 …` (0x80|9).

**The length byte must be right.** Sending a 5-byte mode command instead of a
6-byte one is parsed but rejected — this cost hours of guessing before the
capture settled it.

## Telemetry — opcode 0x06

The cooler is **silent unless polled**. Ask for a frame:

    05 06 20 00 00

Reply (9 bytes):

    89 06 20 00 08 2b d4 0d 13
    ^^ ^^ ^^ ^^ ^^ ^^ ^^^^^ ^^
    |  |  |  |  |  |  |     device power, watts
    |  |  |  |  |  |  fan RPM, uint16 little-endian (0x0DD4 = 3540)
    |  |  |  |  |  hot end temp, °C
    |  |  |  |  cold end temp, °C
    |  |  bytes 2–3 are echoed straight back from the request
    |  opcode
    0x80 | 9

The official app polls this every 2 seconds. Bytes `20 00` are simply the
request's parameters echoed — not flags, as first assumed.

## Set cooling mode — opcode 0x05

    06 05 00 00 <mode> <level>

| mode | meaning | level |
|---|---|---|
| `01` | Overclock | `00` |
| `02` | Smart | `00` |
| `03` | Silent | `00` |
| `04` | Custom | `01`–`05` (power level) |

Reply `85 05 00 00 <status>`: **`01` accepted**, `00` rejected.

Measured on the device:

| Command | Fan | Power |
|---|---|---|
| `06 05 00 00 01 00` Overclock | 4890 RPM | 34 W |
| `06 05 00 00 02 00` Smart | 4440 RPM | 19 W |
| `06 05 00 00 03 00` Silent | 3660 RPM | 19 W |
| `06 05 00 00 04 05` Custom L5 | 5430 RPM | 35 W |

## LED on/off — opcode 0x01

    05 01 00 00 00      # lighting on  ("Standard" mode)
    05 01 00 00 03      # lighting off

Reply `85 01 00 00 01` (`01` accepted). Note the polarity: the capture showed
`03` sent first and `00` second, which suggested `03` = on — but checking the
actual lamp proved the reverse. Byte 4 is a lighting *mode*, where `00` is the
default "Standard" appearance and `03` means off.

The cooler does not report LED state in telemetry, so a client has to remember
what it last set. Colour and effect
selection were not captured — only the on/off pair, which is all that was needed.

## Other frames seen at connect

The official app sends these once on connecting; their meaning is not yet decoded:

    05 04 30 00 00
    05 05 08 00 00
    05 07 08 00 00
    05 06 0a 00 00      # opcode 0x06 with a different parameter than 0x20
    05 06 18 00 00
    05 08 08 00 00
    05 01 20 00 00      # read LED state (opcode 0x01 with param 0x20)

`05 06 0a 00 00` and `05 06 18 00 00` are telemetry reads with other parameters
and are the obvious next thing to explore for more sensor data.

## Sharing the cooler with the official app

Two centrals work **only if the official app connects first**; our app then
attaches via `retrievePeripherals(withIdentifiers:)`. Attaching first locks the
official app out. A phone counts as a separate host and takes the connection
exclusively.

## How this was captured

Every Apple-side capture route failed on macOS 27: PacketLogger recorded 0 packets
for both macOS and iOS traces (even as root), `idevicebtlogger` connected but
returned 0 bytes, `lldb` attach was denied, `DYLD_INSERT_LIBRARIES` was stripped by
AMFI, and the unified log redacts ATT. Apple's Bluetooth logging profile is gated
behind the paid developer program, and the GitHub copies are unsigned and therefore
inert.

What worked: **Android's built-in HCI snoop log**. Enable Developer options ▸
"Bluetooth HCI snoop log", restart Bluetooth so it arms
(`dumpsys bluetooth_manager` must show `sSnoopLogSettingAtEnable = FULL`), drive the
official app on the phone, then:

    adb bugreport out.zip
    unzip -j out.zip 'FS/data/misc/bluetooth/logs/btsnoop_hci_*.log'
    python3 tools/parse_btsnoop.py btsnoop_hci_*.log
