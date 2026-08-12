#!/usr/bin/env python3
"""Tail the FunCooler log and surface meaningful protocol changes.

Telemetry (0x89 0x06) drifts constantly in temp/RPM/power, so those fields are
summarised rather than shouted. Anything else -- a new message type, a change in
the header/mode bytes, or traffic on A003 -- is printed loudly, because that is
what a settings change looks like.
"""
import re, sys, time, os

LOG = os.path.join(os.path.dirname(__file__), "..", "build", "discovery.log")
LINE = re.compile(r"\[(\d\d:\d\d:\d\d)\.\d+\]\s+value (A00[23]) = ([0-9a-f ]+)")

def decode_telemetry(b):
    if len(b) < 9:
        return None
    return {
        "cold": b[4],
        "hot": b[5],
        "rpm": b[6] | (b[7] << 8),
        "watt": b[8],
        "flags": b[2],
        "b3": b[3],
    }

def main():
    last_sig = None       # (char, msgtype, flags, b3) fingerprint
    last_tel = None
    seen_types = set()
    f = open(LOG, "r")
    f.seek(0, 2)          # start at end; we only care about new events
    print("watching for protocol changes … (change a setting in the official app)")
    while True:
        line = f.readline()
        if not line:
            time.sleep(0.4)
            continue
        m = LINE.search(line)
        if not m:
            continue
        ts, char, hexs = m.group(1), m.group(2), m.group(3).strip()
        b = [int(x, 16) for x in hexs.split()]
        mtype = (b[0], b[1]) if len(b) >= 2 else (None, None)

        # Brand-new message type => almost certainly a settings/event packet.
        key = (char, mtype)
        if key not in seen_types:
            seen_types.add(key)
            print(f"\n*** {ts} NEW MESSAGE TYPE on {char}: {hexs}")
            sys.stdout.flush()
            if not (char == "A002" and mtype == (0x89, 0x06)):
                continue

        if char == "A002" and mtype == (0x89, 0x06):
            t = decode_telemetry(b)
            if not t:
                continue
            sig = (t["flags"], t["b3"])
            if sig != last_sig:
                print(f"\n>>> {ts} MODE/FLAG CHANGE: flags=0x{t['flags']:02x} b3=0x{t['b3']:02x}  raw={hexs}")
                last_sig = sig
            # Only report telemetry when it moves meaningfully.
            if (last_tel is None
                    or abs(t["rpm"] - last_tel["rpm"]) > 150
                    or t["cold"] != last_tel["cold"]
                    or t["hot"] != last_tel["hot"]
                    or t["watt"] != last_tel["watt"]):
                print(f"    {ts} cold={t['cold']}C hot={t['hot']}C rpm={t['rpm']} power={t['watt']}W")
                last_tel = t
        else:
            print(f"    {ts} {char}: {hexs}")
        sys.stdout.flush()

if __name__ == "__main__":
    main()
