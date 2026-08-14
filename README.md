# FunCooler

<p align="center">
  <img src="docs/app-icon.png" alt="FunCooler macOS app icon" width="180">
</p>

A Mac menu bar app for the **Black Shark MagCooler 5 Pro** phone cooler. It
shows live telemetry and controls cooling and lighting without the official app.

<p align="center">
  <img src="docs/control-panel.png" alt="FunCooler control panel showing live cooler telemetry and controls" width="500">
</p>

## Features

- Live cold/hot temperature, fan RPM, and power draw, refreshed every two seconds
- Smart cooling or five-step manual power control
- LED on/off control and optional menu-bar stats
- A clear Retry state when the cooler is unavailable

## Install

Download [the latest release](https://github.com/kiteretsu903/shark-custom/releases/latest),
open the DMG, and drag **FunCooler.app** to **Applications**. On first launch,
allow Bluetooth access when macOS asks.

**Requirements:** Apple Silicon, macOS 13 or later, and a powered-on Black Shark
MagCooler 5 Pro.

## Build from source

Requires Xcode, including `swiftc` and `actool`.

```bash
./build.sh
open build/FunCooler.app
```

## Notes

- The cooler does not report its current mode or LED state, so FunCooler restores
  the last settings it applied when it reconnects.
- On another Mac or cooler, the hard-coded identifier may not match; the app falls
  back to scanning and probing supported services.
- To share the cooler with Shark Arsenal, connect Shark Arsenal first, then attach
  FunCooler. Phones take the connection exclusively.
- Only on/off lighting is currently supported.

The BLE protocol was reverse-engineered for this project; see
[PROTOCOL.md](PROTOCOL.md) for the technical write-up.

## License

[MIT](LICENSE). Unofficial and unaffiliated with Black Shark; use at your own risk.
