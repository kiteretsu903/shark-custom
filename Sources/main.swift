import AppKit
import CoreBluetooth

// FunCooler control — Discovery build.
// A menu bar app that scans for the Black Shark FunCooler, connects, and dumps
// its full GATT map (services / characteristics / properties / live values).
// Everything is logged to a window AND to stderr so it can be captured from a terminal.

// Name substrings the cooler is likely to advertise under (case-insensitive).
let NAME_HINTS = ["funcooler", "shark", "cooler", "br5", "br6", "br50", "black"]

// Candidate cooler service UUIDs extracted statically from the Shark Arsenal
// Dart snapshot. If the cooler advertises one of these, we lock onto it.
let CANDIDATE_SERVICES: [CBUUID] = [
    CBUUID(string: "ECD0"),   // 0000ECD0-22ED-CCDB-79C7-71482B33C801 family
    CBUUID(string: "FCF0"),   // 0000FCF0-22ED-CCDB-79C7-71482B33C801 family
    CBUUID(string: "FFE0"),   // classic serial service (FFE1/FFE2 chars)
    CBUUID(string: "FFE1"),
    CBUUID(string: "A001"),   // 0000a001/a002/a003 vendor family
    CBUUID(string: "FF10"),
    CBUUID(string: "0000ECD0-22ED-CCDB-79C7-71482B33C801"),
    CBUUID(string: "0000FCF0-22ED-CCDB-79C7-71482B33C801"),
]

// Set FUNCOOLER_SCAN_ALL=1 to scan every device instead of filtering by service.
let SCAN_ALL = ProcessInfo.processInfo.environment["FUNCOOLER_SCAN_ALL"] == "1"

// The confirmed Black Shark MagCooler 5pro on this Mac. Connect straight to it.
let KNOWN_COOLER_UUID = UUID(uuidString: "9AF7E02A-62F7-337E-BD2C-35A88696F612")!

func looksLikeCooler(_ name: String?) -> Bool {
    guard let n = name?.lowercased() else { return false }
    return NAME_HINTS.contains { n.contains($0) }
}

// MARK: - Logging

final class Log {
    static let shared = Log()
    private let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()
    var sink: ((String) -> Void)?
    private let fileHandle: FileHandle?

    init() {
        // Log to <bundle parent>/discovery.log so it can be read even when
        // launched via `open` (which detaches stderr).
        let dir = Bundle.main.bundleURL.deletingLastPathComponent()
        let url = dir.appendingPathComponent("discovery.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
    }

    func line(_ s: String) {
        let stamped = "[\(df.string(from: Date()))] \(s)"
        let data = (stamped + "\n").data(using: .utf8)!
        FileHandle.standardError.write(data)
        fileHandle?.write(data)
        DispatchQueue.main.async { self.sink?(stamped) }
    }
}

func log(_ s: String) { Log.shared.line(s) }

// MARK: - BLE

/// Cooling modes, as sent in byte 4 of the 0x05 command.
enum CoolingMode: UInt8, CaseIterable {
    case overclock = 1
    case smart     = 2
    case silent    = 3
    case custom    = 4

    var label: String {
        switch self {
        case .overclock: return "Overclock"
        case .smart:     return "Smart"
        case .silent:    return "Silent"
        case .custom:    return "Custom"
        }
    }
}

/// Decoded contents of the cooler's 0x06 telemetry frame.
struct Telemetry {
    let cold: Int      // cold end temp, °C
    let hot: Int       // hot end temp, °C
    let rpm: Int       // fan speed
    let watt: Int      // device power draw
    let flags: UInt8
}

final class BLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private(set) var latest: Telemetry?
    var onTelemetry: ((Telemetry) -> Void)?
    /// Fires once the command characteristic is live and commands may be sent.
    var onReady: (() -> Void)?
    private var central: CBCentralManager!
    private var target: CBPeripheral?
    private(set) var discovered: [UUID: CBPeripheral] = [:]
    var onDevices: (() -> Void)?

    // Set once the cooler is connected, so we can send commands to A001.
    private(set) var writeChar: CBCharacteristic?
    var isConnectedToCooler: Bool { writeChar != nil }

    // MARK: Cooler commands
    //
    // Host→device frames are [total_length][opcode][payload…]; the device
    // replies with the same shape but 0x80 OR'd into the length byte.

    /// Ask for one telemetry frame. The cooler only reports when polled.
    func pollTelemetry() {
        send(Data([0x05, 0x06, 0x20, 0x00, 0x00]))
    }

    /// Set the cooling mode. `level` applies to .custom only (1…5).
    func setMode(_ mode: CoolingMode, level: UInt8 = 0) {
        send(Data([0x06, 0x05, 0x00, 0x00, mode.rawValue, level]))
    }

    /// Turn the RGB lighting on or off. Verified against the hardware: 0x00 is
    /// the "Standard" lighting mode (on) and 0x03 switches it off — the reverse
    /// of what the capture order first suggested.
    func setLED(on: Bool) {
        send(Data([0x05, 0x01, 0x00, 0x00, on ? 0x00 : 0x03]))
    }

    private var pollTimer: Timer?

    func startPolling() {
        pollTimer?.invalidate()
        pollTelemetry()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.isConnectedToCooler else { return }
            self.pollTelemetry()
        }
        // .common keeps it running while a menu is open — otherwise the run
        // loop switches to event-tracking mode and the readings freeze exactly
        // when the user is looking at them.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // A001 is write-without-response: no flow control, so back-to-back writes
    // can be dropped while the cooler digests the previous one. Queue them and
    // pace them out instead of firing everything at once.
    private var sendQueue: [Data] = []
    private var draining = false
    private static let sendGap = 0.18

    /// Queue raw command bytes for the cooler's A001 write characteristic.
    func send(_ data: Data) {
        guard isConnectedToCooler else {
            log("send: not connected to cooler yet."); return
        }
        sendQueue.append(data)
        drainQueue()
    }

    private func drainQueue() {
        guard !draining, !sendQueue.isEmpty else { return }
        guard let p = target, let ch = writeChar else { sendQueue.removeAll(); return }
        draining = true
        let data = sendQueue.removeFirst()
        let type: CBCharacteristicWriteType =
            ch.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(data, for: ch, type: type)
        log("→ SENT to A001: \(data.map { String(format: "%02x", $0) }.joined(separator: " "))")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sendGap) { [weak self] in
            guard let self else { return }
            self.draining = false
            self.drainQueue()
        }
    }

    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
    }

    /// True while the user wants us holding the cooler link.
    private(set) var attached = false

    /// True once a connection attempt has given up; drives the Retry button.
    private(set) var connectFailed = false
    private var connectWatchdog: DispatchWorkItem?
    /// Spent after one silent reconnect, so a dead cooler cannot loop forever.
    private var autoReconnectUsed = false

    /// Attach to the known cooler, giving up after a timeout so the UI can
    /// offer a retry rather than spinning forever.
    func attachToCooler() {
        connectFailed = false
        onDevices?()
        guard let cooler = central.retrievePeripherals(withIdentifiers: [KNOWN_COOLER_UUID]).first else {
            log("Cooler not found — is it powered on and in range?")
            connectFailed = true
            onDevices?()
            return
        }
        attached = true
        discovered[cooler.identifier] = cooler
        connect(cooler)

        connectWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, !self.isConnectedToCooler else { return }
            log("Connection timed out — giving up. Use Retry when the cooler is back.")
            // Stand down completely: cancel the pending connect and clear
            // `attached` so nothing schedules another attempt behind the user's
            // back. Only the Retry button starts a new one.
            self.central.cancelPeripheralConnection(cooler)
            self.attached = false
            self.connectFailed = true
            self.onDevices?()
        }
        connectWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: watchdog)
    }

    /// Release the cooler so the official app can connect freely.
    func detachFromCooler() {
        attached = false
        stopPolling()
        writeChar = nil
        if let p = target ?? central.retrievePeripherals(withIdentifiers: [KNOWN_COOLER_UUID]).first {
            central.cancelPeripheralConnection(p)
            log("Detached — cooler released. The official app can connect now.")
        }
        target = nil
        onDevices?()
    }

    // Manual connect from the menu: force a full dump of the chosen device.
    func connect(_ peripheral: CBPeripheral) {
        collecting = false
        central.stopScan()
        probeTimeout?.cancel()
        forced = true
        foundCooler = false
        currentProbe = peripheral
        svcTotal = 0; svcDone = 0
        hasAppleService = false; matchedKnownService = false; hasCustomWritable = false
        peripheral.delegate = self
        log("Manual connect → \(peripheral.name ?? peripheral.identifier.uuidString) (will dump fully) …")
        central.connect(peripheral, options: nil)
    }
    private var forced = false

    // Probe state
    private var collecting = false
    private var adv: [UUID: (rssi: Int, company: UInt16?, name: String?)] = [:]
    private var probeQueue: [CBPeripheral] = []
    private var currentProbe: CBPeripheral?
    private var probeTimeout: DispatchWorkItem?
    private var foundCooler = false
    // Per-connection accumulators.
    private var svcTotal = 0
    private var svcDone = 0
    private var hasAppleService = false
    private var matchedKnownService = false
    private var hasCustomWritable = false

    // Central state
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            // Start DETACHED so the official app can connect first. The cooler
            // only accepts a second central once the first link is established.
            if let cooler = c.retrievePeripherals(withIdentifiers: [KNOWN_COOLER_UUID]).first {
                discovered[cooler.identifier] = cooler
                onDevices?()
                log("Cooler known — connecting automatically …")
                attachToCooler()
            } else {
                log("Cooler not in system registry yet — scanning to find it …")
                collecting = true
                c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.buildProbeQueue() }
            }
        case .unauthorized:
            log("Bluetooth UNAUTHORIZED — grant this app Bluetooth access in System Settings › Privacy & Security › Bluetooth.")
        case .poweredOff:
            log("Bluetooth is OFF — turn it on.")
        case .unsupported:
            log("Bluetooth LE unsupported on this machine.")
        default:
            log("Bluetooth state: \(c.state.rawValue)")
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? p.name
        let isNew = discovered[p.identifier] == nil
        discovered[p.identifier] = p

        var company: UInt16?
        var extras: [String] = []
        if let svcs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], !svcs.isEmpty {
            extras.append("services=[\(svcs.map { $0.uuidString }.joined(separator: ","))]")
        }
        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 2 {
            company = UInt16(mfg[0]) | (UInt16(mfg[1]) << 8)
            let hex = mfg.map { String(format: "%02x", $0) }.joined(separator: " ")
            extras.append(String(format: "mfg(company=0x%04x)=[\(hex)]", company!))
        }
        adv[p.identifier] = (RSSI.intValue, company, name)
        if isNew {
            let flag = looksLikeCooler(name) ? "  <-- name match" : ""
            let extraStr = extras.isEmpty ? "" : "  " + extras.joined(separator: "  ")
            log("Found \(RSSI) dBm  \(p.identifier)  \(name ?? "(no name)")\(flag)\(extraStr)")
            onDevices?()
        }
    }

    // Build an ordered probe list: skip Apple gear, prefer strong signal.
    private func buildProbeQueue() {
        guard collecting else { return }
        collecting = false
        central.stopScan()
        let ranked = discovered.values.compactMap { p -> (CBPeripheral, Int)? in
            guard let a = adv[p.identifier] else { return nil }
            // Skip Apple devices (company 0x004C) unless the name hints at a cooler.
            if a.company == 0x004C && !looksLikeCooler(a.name) { return nil }
            // Skip devices too weak to be the cooler sitting next to the Mac.
            if a.rssi < -80 { return nil }
            // Prioritise explicit name matches.
            let priority = looksLikeCooler(a.name) ? 1000 : 0
            return (p, priority + a.rssi)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(15)
        .map { $0.0 }

        probeQueue = Array(ranked)
        log("Probing \(probeQueue.count) candidate device(s) for a custom cooler service …")
        probeNext()
    }

    private func probeNext() {
        guard !foundCooler else { return }
        guard let p = probeQueue.first else {
            log("── No cooler found among probed devices. Power-cycle the cooler and use 'Rescan', or connect manually from the menu.")
            return
        }
        probeQueue.removeFirst()
        currentProbe = p
        svcTotal = 0; svcDone = 0
        hasAppleService = false; matchedKnownService = false; hasCustomWritable = false
        p.delegate = self
        let label = adv[p.identifier].flatMap { $0.name } ?? String(p.identifier.uuidString.prefix(8))
        log("Probe → \(label) (\(adv[p.identifier]?.rssi ?? 0) dBm) …")
        let to = DispatchWorkItem { [weak self] in
            guard let self, self.currentProbe?.identifier == p.identifier else { return }
            log("   …timeout, skipping.")
            self.central.cancelPeripheralConnection(p)
            self.currentProbe = nil
            self.probeNext()
        }
        probeTimeout = to
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: to)
        central.connect(p, options: nil)
    }

    private func isCoolerService(_ u: CBUUID) -> Bool {
        let s = u.uuidString.uppercased()
        if s.contains("22ED-CCDB-79C7-71482B33C801") { return true }          // ECD0/FCF0 base
        if s.contains("01C8332B-4871-C779-DBCC") { return true }              // reversed base
        return ["FFE0", "FFE1", "ECD0", "FCF0", "A001"].contains(s)
    }
    private func isAppleService(_ u: CBUUID) -> Bool {
        // Apple Continuity/Nearby service.
        return u.uuidString.uppercased().hasPrefix("D0611E78") || u.uuidString.uppercased().hasPrefix("9FA480E0")
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        guard currentProbe?.identifier == p.identifier else { return }
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        if currentProbe?.identifier == p.identifier {
            log("   connect failed: \(error?.localizedDescription ?? "unknown")")
            probeTimeout?.cancel(); currentProbe = nil; probeNext()
        }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("Disconnected \(p.identifier): \(error?.localizedDescription ?? "clean")")
        guard p.identifier == KNOWN_COOLER_UUID || target?.identifier == p.identifier else { return }

        // Drop stale state so the UI shows what is actually true right now.
        stopPolling()
        writeChar = nil
        latest = nil
        sendQueue.removeAll()
        onDevices?()

        guard attached else { return }
        if autoReconnectUsed {
            // One attempt was already spent: stop and let the user decide.
            log("Cooler still unreachable — stopping. Use Retry.")
            attached = false
            connectFailed = true
            onDevices?()
            return
        }
        autoReconnectUsed = true
        log("Lost the cooler — one automatic reconnect attempt …")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.attached else { return }
            self.attachToCooler()
        }
    }

    // Peripheral
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard currentProbe?.identifier == p.identifier else { return }
        if let e = error { log("   service discovery error: \(e.localizedDescription)"); finishProbe(p, cooler: false); return }
        let services = p.services ?? []
        svcTotal = services.count
        svcDone = 0
        if services.isEmpty { finishProbe(p, cooler: false); return }
        for s in services {
            if isAppleService(s.uuid) { hasAppleService = true }
            if isCoolerService(s.uuid) { matchedKnownService = true }
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard currentProbe?.identifier == p.identifier else { return }
        for c in s.characteristics ?? [] {
            // A writable characteristic on a non-standard 128-bit service ⇒ likely control.
            let writable = c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse)
            if writable && s.uuid.uuidString.count > 6 && !isAppleService(s.uuid) {
                hasCustomWritable = true
            }
        }
        svcDone += 1
        if svcDone >= svcTotal { evaluateProbe(p) }
    }

    private func evaluateProbe(_ p: CBPeripheral) {
        let cooler = forced || (!hasAppleService && (matchedKnownService || hasCustomWritable))
        finishProbe(p, cooler: cooler)
    }

    private func finishProbe(_ p: CBPeripheral, cooler: Bool) {
        probeTimeout?.cancel()
        if cooler {
            connectWatchdog?.cancel()
            connectFailed = false
            autoReconnectUsed = false   // a good link re-arms the one free retry
            foundCooler = true
            target = p
            currentProbe = nil
            let label = adv[p.identifier].flatMap { $0.name } ?? p.identifier.uuidString
            attached = true
            log("★★★ COOLER IDENTIFIED: \(label) (\(p.identifier)) — dumping full GATT ★★★")
            dumpFully(p)
            onDevices?()
        } else {
            log("   not the cooler (apple=\(hasAppleService) known=\(matchedKnownService) writable=\(hasCustomWritable)) — skipping.")
            central.cancelPeripheralConnection(p)
            currentProbe = nil
            probeNext()
        }
    }

    // Detailed dump of the confirmed cooler: list everything, read readables, subscribe notifies.
    private func dumpFully(_ p: CBPeripheral) {
        for s in p.services ?? [] {
            log("[Service] \(s.uuid)")
            for c in s.characteristics ?? [] {
                log("    [Char] \(c.uuid)  props=[\(propsString(c.properties))]")
                if c.uuid.uuidString.uppercased() == "A001" {
                    writeChar = c
                    log("    ↑ captured A001 as the command write characteristic")
                    // The cooler is silent unless polled, so drive it ourselves.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.startPolling()
                        self?.onReady?()
                    }
                }
                if c.properties.contains(.read) { p.readValue(for: c) }
                if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                    p.setNotifyValue(true, for: c)
                }
                p.discoverDescriptors(for: c)
            }
        }
        onDevices?()
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let e = error { log("write error \(c.uuid): \(e.localizedDescription)") }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let e = error { log("Read error \(c.uuid): \(e.localizedDescription)"); return }
        let d = c.value ?? Data()
        log("      value \(c.uuid) = \(hex(d))  \(ascii(d))")

        // Telemetry: 0x89 0x06 <flags> <rsvd> <cold> <hot> <rpm lo> <rpm hi> <watt>
        let b = [UInt8](d)
        if b.count >= 9, b[0] == 0x89, b[1] == 0x06 {
            let t = Telemetry(cold: Int(b[4]), hot: Int(b[5]),
                              rpm: Int(b[6]) | (Int(b[7]) << 8),
                              watt: Int(b[8]), flags: b[2])
            latest = t
            onTelemetry?(t)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverDescriptorsFor c: CBCharacteristic, error: Error?) {
        for d in c.descriptors ?? [] {
            log("        [Descriptor] \(d.uuid)")
        }
    }

    // Helpers
    private func propsString(_ p: CBCharacteristicProperties) -> String {
        var out: [String] = []
        if p.contains(.read) { out.append("read") }
        if p.contains(.write) { out.append("write") }
        if p.contains(.writeWithoutResponse) { out.append("writeNoResp") }
        if p.contains(.notify) { out.append("notify") }
        if p.contains(.indicate) { out.append("indicate") }
        if p.contains(.broadcast) { out.append("broadcast") }
        if p.contains(.authenticatedSignedWrites) { out.append("signedWrite") }
        return out.joined(separator: ",")
    }
    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined(separator: " ") }
    private func ascii(_ d: Data) -> String {
        let s = d.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." }
        return "\"" + String(s) + "\""
    }
}

// MARK: - Menu views

/// One type scale and one set of metrics for every row, so the panel reads as
/// a single design rather than a pile of individually-styled controls.
enum UI {
    static let width: CGFloat = 264
    static let inset: CGFloat = 16

    /// Small uppercase section label, letterspaced.
    static func caption(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 0.8,
        ])
        return f
    }

    /// Numeric readout. Monospaced digits keep columns from shifting.
    static func value(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        f.textColor = .labelColor
        return f
    }

    /// Ordinary control label.
    static func row(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 12.5, weight: .regular)
        f.textColor = .labelColor
        return f
    }

    static func recolor(_ field: NSTextField, _ color: NSColor) {
        guard let s = field.attributedStringValue.mutableCopy() as? NSMutableAttributedString else { return }
        s.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: s.length))
        field.attributedStringValue = s
    }
}

/// Telemetry header: four readings in a 2×2 grid.
final class StatsView: NSView {
    private let values: [NSTextField]
    private static let captions = ["COLD END", "FAN", "HOT END", "POWER"]

    init() {
        values = Self.captions.map { _ in UI.value("—") }
        super.init(frame: NSRect(x: 0, y: 0, width: UI.width, height: 78))

        let columns: [NSStackView] = (0..<2).map { col in
            let cells: [NSView] = (0..<2).map { row in
                let idx = row * 2 + col
                let cell = NSStackView(views: [UI.caption(Self.captions[idx]), values[idx]])
                cell.orientation = .vertical
                cell.alignment = .leading
                cell.spacing = 0
                return cell
            }
            let column = NSStackView(views: cells)
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 9
            return column
        }

        let grid = NSStackView(views: columns)
        grid.orientation = .horizontal
        grid.distribution = .fillEqually
        grid.spacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: UI.inset),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -UI.inset),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ t: Telemetry?) {
        guard let t else {
            values.forEach { $0.stringValue = "—" }
            return
        }
        values[0].stringValue = "\(t.cold)°C"
        values[1].stringValue = "\(t.rpm) rpm"
        values[2].stringValue = "\(t.hot)°C"
        values[3].stringValue = "\(t.watt) W"
    }
}

/// A label plus a switch. Living in a menu item's view means clicking it
/// toggles in place instead of dismissing the menu.
final class ToggleRowView: NSView {
    let toggle = NSSwitch()
    private let label: NSTextField

    init(title: String) {
        label = UI.row(title)
        super.init(frame: NSRect(x: 0, y: 0, width: UI.width, height: 28))

        // A regular NSSwitch is sized for a settings window and looks bloated
        // in a menu. NSSwitch largely ignores controlSize, so pin the size:
        // 30×17 matches the weight of 12.5pt text.
        toggle.controlSize = .mini
        toggle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toggle.widthAnchor.constraint(equalToConstant: 30),
            toggle.heightAnchor.constraint(equalToConstant: 17),
        ])

        let stack = NSStackView(views: [label, NSView(), toggle])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: UI.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -UI.inset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setEnabled(_ on: Bool) {
        toggle.isEnabled = on
        label.textColor = on ? .labelColor : .disabledControlTextColor
    }
}

/// The power-level slider: draggable, but snapped to the five levels the
/// cooler accepts. Dimmed while Smart is driving the fan.
final class LevelRowView: NSView {
    let slider = NSSlider(value: 3, minValue: 1, maxValue: 5, target: nil, action: nil)
    private let caption = UI.caption("POWER LEVEL")
    private let value = UI.caption("3")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: UI.width, height: 48))
        value.alignment = .right

        // Ticks keep it honest: the fan has five steps, so the knob lands on them.
        slider.numberOfTickMarks = 5
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        slider.isContinuous = true
        slider.controlSize = .small

        let header = NSStackView(views: [caption, NSView(), value])
        header.orientation = .horizontal
        header.alignment = .firstBaseline

        let stack = NSStackView(views: [header, slider])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: UI.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -UI.inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            slider.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setLevel(_ lvl: UInt8) {
        slider.intValue = Int32(lvl)
        value.attributedStringValue = NSAttributedString(
            string: "\(lvl)",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                         .foregroundColor: value.textColor ?? NSColor.tertiaryLabelColor,
                         .kern: 0.8])
    }

    func setEnabled(_ on: Bool) {
        slider.isEnabled = on
        let tint: NSColor = on ? .tertiaryLabelColor : .quaternaryLabelColor
        UI.recolor(caption, tint)
        UI.recolor(value, tint)
        alphaValue = on ? 1.0 : 0.55
    }
}

// MARK: - App / menu bar UI

final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let ble = BLE()
    private var window: NSWindow!
    private var textView: NSTextView!
    private var hexField: NSTextField!
    private weak var statsView: StatsView?
    private weak var levelRow: LevelRowView?
    private weak var smartRow: ToggleRowView?
    private var currentMode: CoolingMode?
    private var currentLevel: UInt8 = 0
    // The cooler reports neither LED state nor mode, so track what we last set.
    private var ledOn = true
    private var smartOn = true
    private var showStatsInBar = true

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "thermometer.snowflake", accessibilityDescription: "FunCooler")
        }
        rebuildMenu()
        makeLogWindow()

        Log.shared.sink = { [weak self] line in self?.append(line) }
        ble.onDevices = { [weak self] in self?.rebuildMenu() }
        ble.onTelemetry = { [weak self] t in self?.updateStatusTitle(t) }
        ble.onReady = { [weak self] in self?.applySavedSettings() }
        loadSettings()
        ble.start()
        startCommandFileWatcher()
    }

    /// Watches /tmp/funcooler_cmd for one-line commands so the workflow can be
    /// driven from a terminal: ATTACH | DETACH | SEND <hex bytes>
    private func startCommandFileWatcher() {
        let path = "/tmp/funcooler_cmd"
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(atPath: path)
            for rawLine in text.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                switch parts[0].uppercased() {
                case "ATTACH": log("[cmd] ATTACH"); self.ble.attachToCooler()
                case "DETACH": log("[cmd] DETACH"); self.ble.detachFromCooler()
                case "SEND":
                    guard parts.count > 1 else { break }
                    let toks = parts[1].replacingOccurrences(of: "0x", with: "")
                        .components(separatedBy: CharacterSet(charactersIn: " ,\t"))
                        .filter { !$0.isEmpty }
                    var bytes = [UInt8]()
                    var ok = true
                    for t in toks {
                        if let b = UInt8(t, radix: 16) { bytes.append(b) } else { ok = false }
                    }
                    if ok && !bytes.isEmpty { self.ble.send(Data(bytes)) }
                    else { log("[cmd] bad SEND payload: \(parts[1])") }
                default: log("[cmd] unknown: \(line)")
                }
            }
            self.rebuildMenu()
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let connected = ble.isConnectedToCooler
        refreshStatusItem()   // drop the readout when the link goes away

        // Live readings.
        let statsItem = NSMenuItem()
        let stats = StatsView()
        stats.update(connected ? ble.latest : nil)
        statsItem.view = stats
        statsView = stats
        menu.addItem(statsItem)

        // Connection state: silent when healthy, actionable when not.
        if !connected {
            let stopped = ble.connectFailed
            let status = NSMenuItem(title: stopped ? "Cooler disconnected" : "Connecting…",
                                    action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            if stopped {
                let retry = NSMenuItem(title: "Retry", action: #selector(doAttach), keyEquivalent: "r")
                retry.target = self
                menu.addItem(retry)
            }
        }
        menu.addItem(.separator())

        // Smart on → the cooler manages itself and the level row is inert.
        let smartItem = NSMenuItem()
        let smart = ToggleRowView(title: "Smart cooling")
        smart.toggle.state = smartOn ? .on : .off
        smart.toggle.target = self
        smart.toggle.action = #selector(smartSwitched(_:))
        smart.setEnabled(connected)
        smartItem.view = smart
        smartRow = smart
        menu.addItem(smartItem)

        let levelItem = NSMenuItem()
        let row = LevelRowView()
        row.slider.target = self
        row.slider.action = #selector(levelChanged(_:))
        row.setLevel(currentLevel == 0 ? 3 : currentLevel)
        row.setEnabled(connected && !smartOn)
        levelItem.view = row
        levelRow = row
        menu.addItem(levelItem)
        menu.addItem(.separator())

        let ledItem = NSMenuItem()
        let led = ToggleRowView(title: "LED")
        led.toggle.state = ledOn ? .on : .off
        led.toggle.target = self
        led.toggle.action = #selector(ledSwitched(_:))
        led.setEnabled(connected)
        ledItem.view = led
        menu.addItem(ledItem)

        let barItem = NSMenuItem()
        let bar = ToggleRowView(title: "Show stats in menu bar")
        bar.toggle.state = showStatsInBar ? .on : .off
        bar.toggle.target = self
        bar.toggle.action = #selector(barSwitched(_:))
        barItem.view = bar
        menu.addItem(barItem)
        menu.addItem(.separator())


        // Debugging tools stay available but out of the way.
        let advanced = NSMenu()
        let showLog = NSMenuItem(title: "Show Log Window", action: #selector(showLog), keyEquivalent: "l")
        showLog.target = self
        advanced.addItem(showLog)
        advanced.addItem(.separator())
        if ble.discovered.isEmpty {
            advanced.addItem(withTitle: "Scanning…", action: nil, keyEquivalent: "")
        } else {
            for (_, p) in ble.discovered {
                let label = p.name ?? String(p.identifier.uuidString.prefix(8))
                let item = NSMenuItem(title: "Connect: \(label)",
                                      action: #selector(connectDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = p
                advanced.addItem(item)
            }
        }
        let advancedItem = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        advancedItem.submenu = advanced
        menu.addItem(advancedItem)

        let quit = NSMenuItem(title: "Quit FunCooler", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    /// Refresh the menu bar button and the open menu's live rows.
    private func updateStatusTitle(_ t: Telemetry) {
        refreshStatusItem()
        statsView?.update(t)
    }

    /// The button shows the icon alone, or icon plus a compact readout.
    private func refreshStatusItem() {
        guard let btn = statusItem.button else { return }
        btn.image = NSImage(systemSymbolName: "thermometer.snowflake",
                            accessibilityDescription: "FunCooler")
        if showStatsInBar, let t = ble.latest, ble.isConnectedToCooler {
            btn.title = "  \(t.cold)°  \(t.rpm)"
            btn.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            btn.imagePosition = .imageLeading
        } else {
            btn.title = ""
            btn.imagePosition = .imageOnly
        }
    }

    // MARK: Settings
    //
    // The cooler reports neither its mode nor its LED state, so the app is the
    // only memory of them. Persist the choices and re-apply on connect, which
    // keeps what the menu shows and what the hardware is doing in agreement.

    private func loadSettings() {
        let d = UserDefaults.standard
        d.register(defaults: ["smartOn": true, "ledOn": true,
                              "showStatsInBar": true, "level": 3])
        smartOn = d.bool(forKey: "smartOn")
        ledOn = d.bool(forKey: "ledOn")
        showStatsInBar = d.bool(forKey: "showStatsInBar")
        currentLevel = UInt8(max(1, min(5, d.integer(forKey: "level"))))
    }

    private func saveSettings() {
        let d = UserDefaults.standard
        d.set(smartOn, forKey: "smartOn")
        d.set(ledOn, forKey: "ledOn")
        d.set(showStatsInBar, forKey: "showStatsInBar")
        d.set(Int(currentLevel), forKey: "level")
    }

    private func applySavedSettings() {
        if smartOn {
            ble.setMode(.smart)
            currentMode = .smart
        } else {
            ble.setMode(.custom, level: currentLevel)
            currentMode = .custom
        }
        ble.setLED(on: ledOn)
        rebuildMenu()
    }

    // These act on the menu's own views, so the menu stays open while the
    // user flips Smart off and then reaches for the slider.

    @objc private func ledSwitched(_ sender: NSSwitch) {
        ledOn = sender.state == .on
        ble.setLED(on: ledOn)
        saveSettings()
    }

    /// Smart hands control back to the cooler; turning it off pins the fan to
    /// the chosen level via Custom mode and wakes the slider.
    @objc private func smartSwitched(_ sender: NSSwitch) {
        smartOn = sender.state == .on
        if smartOn {
            ble.setMode(.smart)
            currentMode = .smart
        } else {
            if currentLevel == 0 { currentLevel = 3 }
            ble.setMode(.custom, level: currentLevel)
            currentMode = .custom
        }
        levelRow?.setEnabled(ble.isConnectedToCooler && !smartOn)
        saveSettings()
    }

    @objc private func levelChanged(_ sender: NSSlider) {
        let lvl = UInt8(max(1, min(5, sender.intValue)))
        levelRow?.setLevel(lvl)
        // Dragging fires continuously; only talk to the cooler on a real change.
        guard lvl != currentLevel else { return }
        currentLevel = lvl
        currentMode = .custom
        ble.setMode(.custom, level: lvl)
        saveSettings()
    }

    @objc private func barSwitched(_ sender: NSSwitch) {
        showStatsInBar = sender.state == .on
        refreshStatusItem()
        saveSettings()
    }

    @objc private func doAttach() { ble.attachToCooler() }
    @objc private func doDetach() { ble.detachFromCooler() }

    @objc private func connectDevice(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? CBPeripheral else { return }
        ble.connect(p)
    }

    private func makeLogWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "FunCooler Discovery Log"
        window.center()
        let content = window.contentView!

        // Bottom input row: hex field + Send button.
        let rowH: CGFloat = 34
        let sendBtn = NSButton(title: "Send → A001", target: self, action: #selector(sendHex))
        sendBtn.bezelStyle = .rounded
        sendBtn.frame = NSRect(x: content.bounds.width - 130, y: 6, width: 120, height: 24)
        sendBtn.autoresizingMask = [.minXMargin]
        hexField = NSTextField(frame: NSRect(x: 10, y: 6, width: content.bounds.width - 150, height: 24))
        hexField.placeholderString = "hex bytes e.g. aa 02 01 03  — Enter to send"
        hexField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        hexField.autoresizingMask = [.width]
        hexField.target = self
        hexField.action = #selector(sendHex)
        content.addSubview(sendBtn)
        content.addSubview(hexField)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: rowH, width: content.bounds.width,
                                                height: content.bounds.height - rowH))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.autoresizingMask = [.width, .height]
        scroll.documentView = textView
        content.addSubview(scroll)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func sendHex() {
        let raw = hexField.stringValue
        let cleaned = raw.replacingOccurrences(of: "0x", with: "")
                         .components(separatedBy: CharacterSet(charactersIn: " ,\t"))
                         .filter { !$0.isEmpty }
        var bytes = [UInt8]()
        for tok in cleaned {
            guard let b = UInt8(tok, radix: 16) else { log("bad hex token: \(tok)"); return }
            bytes.append(b)
        }
        guard !bytes.isEmpty else { return }
        ble.send(Data(bytes))
    }

    @objc private func showLog() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func append(_ line: String) {
        textView.string += line + "\n"
        textView.scrollToEndOfDocument(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only, no dock icon
let controller = AppController()
app.delegate = controller
app.run()
