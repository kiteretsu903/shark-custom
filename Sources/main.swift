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

final class BLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var target: CBPeripheral?
    private(set) var discovered: [UUID: CBPeripheral] = [:]
    var onDevices: (() -> Void)?

    // Set once the cooler is connected, so we can send commands to A001.
    private(set) var writeChar: CBCharacteristic?
    var isConnectedToCooler: Bool { writeChar != nil }

    /// Send raw command bytes to the cooler's A001 write characteristic.
    func send(_ data: Data) {
        guard let p = target, let ch = writeChar else {
            log("send: not connected to cooler yet."); return
        }
        let type: CBCharacteristicWriteType =
            ch.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(data, for: ch, type: type)
        log("→ SENT to A001: \(data.map { String(format: "%02x", $0) }.joined(separator: " "))")
    }

    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
    }

    /// True while the user wants us holding the cooler link.
    private(set) var attached = false

    /// Attach to the known cooler (call AFTER the official app has connected).
    func attachToCooler() {
        guard let cooler = central.retrievePeripherals(withIdentifiers: [KNOWN_COOLER_UUID]).first else {
            log("Cooler not found in registry — is it powered on?"); return
        }
        attached = true
        discovered[cooler.identifier] = cooler
        connect(cooler)
    }

    /// Release the cooler so the official app can connect freely.
    func detachFromCooler() {
        attached = false
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
                log("Ready, but NOT attached (so the official app can connect).")
                log("→ Connect the cooler in Shark Arsenal first, then choose 'Attach to cooler' in the menu bar.")
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
        // Only auto-reconnect while the user wants us attached.
        if attached && (p.identifier == KNOWN_COOLER_UUID || target?.identifier == p.identifier) {
            writeChar = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                log("Re-attaching to cooler …")
                self.connect(p)
            }
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
            foundCooler = true
            target = p
            currentProbe = nil
            let label = adv[p.identifier].flatMap { $0.name } ?? p.identifier.uuidString
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

// MARK: - App / menu bar UI

final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let ble = BLE()
    private var window: NSWindow!
    private var textView: NSTextView!
    private var hexField: NSTextField!

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "thermometer.snowflake", accessibilityDescription: "FunCooler")
        }
        rebuildMenu()
        makeLogWindow()

        Log.shared.sink = { [weak self] line in self?.append(line) }
        ble.onDevices = { [weak self] in self?.rebuildMenu() }
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
        let state = ble.isConnectedToCooler ? "● Attached (recording)" : "○ Detached"
        menu.addItem(withTitle: "FunCooler — \(state)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let attach = NSMenuItem(title: "Attach to cooler", action: #selector(doAttach), keyEquivalent: "a")
        attach.target = self
        attach.isEnabled = !ble.isConnectedToCooler
        menu.addItem(attach)
        let detach = NSMenuItem(title: "Detach (release for official app)", action: #selector(doDetach), keyEquivalent: "d")
        detach.target = self
        menu.addItem(detach)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Tip: connect in Shark Arsenal FIRST, then Attach", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        if ble.discovered.isEmpty {
            menu.addItem(withTitle: "Scanning…", action: nil, keyEquivalent: "")
        } else {
            for (_, p) in ble.discovered {
                let label = p.name ?? String(p.identifier.uuidString.prefix(8))
                let title = "Connect: \(label)"
                let item = NSMenuItem(title: title, action: #selector(connectDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = p
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let showLog = NSMenuItem(title: "Show Log Window", action: #selector(showLog), keyEquivalent: "l")
        showLog.target = self
        menu.addItem(showLog)
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
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
