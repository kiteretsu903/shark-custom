#!/usr/bin/env python3
"""Extract ATT writes and notifications from an Android btsnoop_hci log.

The cooler's protocol rides on ATT: the app writes commands to the A001
characteristic and the device notifies status back. This prints both
directions in order so a tapped UI action can be matched to its bytes.

Usage: python3 tools/parse_btsnoop.py <btsnoop_hci.log> [--all]
"""
import struct
import sys
from datetime import datetime, timedelta

# btsnoop timestamps count microseconds from year 0; this is the offset to epoch.
BTSNOOP_EPOCH = 0x00DCDDB30F2F8000

ATT_CID = 0x0004
OPS = {
    0x12: "WriteReq",
    0x52: "WriteCmd",
    0x1B: "Notify",
    0x1D: "Indicate",
    0x0A: "ReadReq",
    0x0B: "ReadRsp",
    0x13: "WriteRsp",
}
WRITE_OPS = {0x12, 0x52}


def parse(path, show_all=False):
    with open(path, "rb") as f:
        hdr = f.read(16)
        if hdr[:8] != b"btsnoop\x00":
            print("not a btsnoop file")
            return

        # Reassemble ACL fragments per connection handle.
        pending = {}
        rows = []
        while True:
            rec = f.read(24)
            if len(rec) < 24:
                break
            olen, ilen, flags, drops, ts = struct.unpack(">IIIIq", rec)
            data = f.read(ilen)
            if len(data) < ilen:
                break
            when = datetime(1, 1, 1) + timedelta(microseconds=ts - BTSNOOP_EPOCH)

            if not data or data[0] != 0x02:      # H4: 0x02 = ACL
                continue
            if len(data) < 5:
                continue
            handle_pb = struct.unpack("<H", data[1:3])[0]
            handle = handle_pb & 0x0FFF
            pb = (handle_pb >> 12) & 0x3
            acl_len = struct.unpack("<H", data[3:5])[0]
            payload = data[5:5 + acl_len]

            if pb == 0x01:                        # continuation fragment
                if handle in pending:
                    pending[handle] += payload
                else:
                    continue
            else:
                pending[handle] = payload

            buf = pending[handle]
            if len(buf) < 4:
                continue
            l2_len, cid = struct.unpack("<HH", buf[:4])
            if len(buf) < 4 + l2_len:
                continue                          # wait for the rest
            l2_payload = buf[4:4 + l2_len]
            pending.pop(handle, None)

            if cid != ATT_CID or not l2_payload:
                continue
            op = l2_payload[0]
            if not show_all and op not in WRITE_OPS and op != 0x1B:
                continue
            if len(l2_payload) < 3:
                continue
            att_handle = struct.unpack("<H", l2_payload[1:3])[0]
            value = l2_payload[3:]
            rows.append((when, OPS.get(op, hex(op)), att_handle, value))

    if not rows:
        print("no ATT writes/notifications found")
        return

    # Handles seen, so the command characteristic can be identified.
    print("=== ATT handles seen ===")
    seen = {}
    for _, kind, h, _ in rows:
        seen.setdefault((kind, h), 0)
        seen[(kind, h)] += 1
    for (kind, h), n in sorted(seen.items(), key=lambda kv: -kv[1]):
        print(f"  {kind:<9} handle 0x{h:04x}  x{n}")

    print("\n=== WRITES (app -> cooler) ===")
    for when, kind, h, val in rows:
        if kind.startswith("Write"):
            print(f"{when:%H:%M:%S.%f}  {kind:<9} h=0x{h:04x}  {val.hex(' ')}")

    print("\n=== NOTIFICATIONS (cooler -> app), non-telemetry only ===")
    for when, kind, h, val in rows:
        if kind == "Notify" and not (len(val) >= 2 and val[0] == 0x89 and val[1] == 0x06):
            print(f"{when:%H:%M:%S.%f}  {kind:<9} h=0x{h:04x}  {val.hex(' ')}")


if __name__ == "__main__":
    parse(sys.argv[1], "--all" in sys.argv)
