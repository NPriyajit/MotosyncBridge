// BluetoothManager.swift — Motosync Bridge
// Payload format reverse-engineered from Android BLE decompilation:
//   REQUEST_SAB_MODE  → [0x0A, requestId]          2 bytes
//   MYSTERY_BOX       → LiveScreen serialization    variable
//   POP_UP heartbeat  → [0x02, requestId, 0, 0, 0]  5 bytes

import Foundation
import CoreBluetooth
import Combine
import MediaPlayer
import AudioToolbox
import UserNotifications

// MARK: — Status

enum BLEStatus: String {
    case poweredOff   = "Bluetooth Off"
    case scanning     = "Searching for Console..."
    case connecting   = "Connecting..."
    case connected    = "Connected to Dashboard"
    case disconnected = "Disconnected"
}

// MARK: — MusicEncoder
//
// Swift port of MusicEncoder.generateDisplayPacket(title, artist).
// Builds the 141-byte fixed-length packet the Honda BTU display expects.
// Packet layout confirmed from Wireshark handle 0x0063 captures:
//   [0]      = 0x01  (packet type: track update)
//   [1]      = 0x00  (reserved)
//   [2..71]  = title  UTF-8, zero-padded to 70 bytes
//   [72..141]= artist UTF-8, zero-padded to 69 bytes (total = 141)

private enum MusicEncoder {
    static func generateDisplayPacket(requestId: UInt8, title: String, artist: String) -> Data {
        var packet = Data()
        
        // 1. Command ID: MYSTERY_BOX (0x01)
        packet.append(0x01)
        // 2. Request ID
        packet.append(requestId)
        // 3. Header Background Color: ORANGE (14)
        packet.append(14)
        
        // 4. Header Text: "Music"
        let headerText = "Music"
        let headerBytes = Array(headerText.utf8)
        packet.append(UInt8(headerBytes.count))
        if !headerBytes.isEmpty {
            packet.append(contentsOf: headerBytes)
            packet.append(0) // Header Text Color: PURE_WHITE (0)
        }
        
        // 5. Body Type: LIVE_SCREEN (2)
        packet.append(2)
        // 6. Body Background Color: PURE_BLACK (1)
        packet.append(1)
        
        // 7. Left Action Icon ID: IC_NONE (0)
        packet.append(0)
        // Left action color, content icon, content icon tint, background color are all skipped (null)
        
        // 8. Right Action Icon ID: IC_NONE (0)
        packet.append(0)
        // Right action color, content icon, content icon tint, background color are all skipped (null)
        
        // 9. Content Background Color: PURE_BLACK (1)
        packet.append(1)
        
        // 10. Content Icon ID: IC_NONE (0) — no icon; text fills the content area.
        // Note: MUSIC icon value (3) conflicts with MENU_ARROW_UP (also 3) in the
        // console's icon validation table. IC_NONE is always accepted and avoids
        // the INVALID_PARAMETERS rejection at byte position 0x0F.
        packet.append(0)
        // IC_NONE has no tint color (CommandKt.c skips null → nothing written)
        
        // 12. Content Text Line 1 (Title)
        let cleanTitle = String(title.prefix(30))
        let titleBytes = Array(cleanTitle.utf8)
        packet.append(UInt8(titleBytes.count))
        if !titleBytes.isEmpty {
            packet.append(contentsOf: titleBytes)
            packet.append(0) // Content Text Color Line 1: PURE_WHITE (0)
        }
        
        // 13. Content Text Line 2 (Artist)
        let cleanArtist = String(artist.prefix(30))
        let artistBytes = Array(cleanArtist.utf8)
        packet.append(UInt8(artistBytes.count))
        if !artistBytes.isEmpty {
            packet.append(contentsOf: artistBytes)
            packet.append(0) // Content Text Color Line 2: PURE_WHITE (0)
        }
        
        return packet
    }

    // 2-byte REQUEST_SAB_MODE packet — must be sent once before any display projection.
    // Equivalent to CommandBuilder.i() in Android: [0x0A, requestId]
    static func generateSABModeRequest(requestId: UInt8) -> Data {
        return Data([0x0A, requestId])
    }

    // Dynamic 5-byte keep-alive matching POP_UP layout with zeroed fields.
    static func generateHeartbeat(requestId: UInt8) -> Data {
        return Data([0x02, requestId, 0x00, 0x00, 0x00])
    }
}

private enum NavigationEncoder {
    static func generateNavigationPacket(requestId: UInt8, iconId: UInt8, distance: String, instruction: String) -> Data {
        var packet = Data()
        
        // 1. Command ID: MYSTERY_BOX (0x01)
        packet.append(0x01)
        // 2. Request ID
        packet.append(requestId)
        // 3. Header Background Color: ORANGE (14)
        packet.append(14)
        
        // 4. Header Text: "Music"
        let headerText = "Music"
        let headerBytes = Array(headerText.utf8)
        packet.append(UInt8(headerBytes.count))
        if !headerBytes.isEmpty {
            packet.append(contentsOf: headerBytes)
            packet.append(0) // Header Text Color: PURE_WHITE (0)
        }
        
        // 5. Body Type: LIVE_SCREEN (2)
        packet.append(2)
        // 6. Body Background Color: PURE_BLACK (1)
        packet.append(1)
        
        // 7. Left Action Icon ID: IC_NONE (0)
        packet.append(0)
        
        // 8. Right Action Icon ID: IC_NONE (0)
        packet.append(0)
        
        // 9. Content Background Color: PURE_BLACK (1)
        packet.append(1)
        
        // 10. Content Icon ID: IC_NONE (0) — verified bypass to prevent validation rejections
        packet.append(0)
        
        // 12. Content Text Line 1 (Distance / Arrow representation)
        let cleanDistance = String(distance.prefix(30))
        let distanceBytes = Array(cleanDistance.utf8)
        packet.append(UInt8(distanceBytes.count))
        if !distanceBytes.isEmpty {
            packet.append(contentsOf: distanceBytes)
            packet.append(0) // Color: PURE_WHITE (0)
        }
        
        // 13. Content Text Line 2 (Instruction / Street)
        let cleanInstruction = String(instruction.prefix(30))
        let instructionBytes = Array(cleanInstruction.utf8)
        packet.append(UInt8(instructionBytes.count))
        if !instructionBytes.isEmpty {
            packet.append(contentsOf: instructionBytes)
            packet.append(0) // Color: PURE_WHITE (0)
        }
        
        return packet
    }
}

// MARK: — BLEDelegate
//
// NSObject subclass owning both CB delegate protocols.
// Forwards all events to BluetoothManager via weak ref.
// Required split: NSObject + ObservableObject cannot coexist on same class.

private final class BLEDelegate: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var manager: BluetoothManager?

    // MARK: CBCentralManagerDelegate

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        print("🔒 CoreBluetooth: Restoring central manager state...")
        guard let m = manager else { return }
        
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                print("🔒 Restored peripheral connection: \(peripheral.name ?? "Unknown") (\(peripheral.identifier.uuidString))")
                m.targetPeripheral = peripheral
                m.connectedPeripheral = peripheral
                peripheral.delegate = self
                
                if peripheral.state == .connected {
                    m.status = .connected
                    peripheral.discoverServices(nil)
                } else if peripheral.state == .connecting {
                    m.status = .connecting
                }
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let m = manager else { return }
        switch central.state {
        case .poweredOn:
            // 1. Queue direct connection to cached peripheral if available
            if m.reconnectToLastKnownPeripheral() {
                print("🔄 Found last known peripheral. Queueing auto-connection...")
            }
            // 2. Start scanning simultaneously to resolve advertisements if cached instance is stale or needs discovery
            m.startScanning()
        case .poweredOff:   m.status = .poweredOff
        case .unauthorized: m.status = .disconnected
        default:            m.status = .poweredOff
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard let m = manager else { return }
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        
        // Match target broadcast name prefix "HONDA BTU"
        guard localName?.hasPrefix(AppConfiguration.targetDeviceName) == true ||
              peripheral.name?.hasPrefix(AppConfiguration.targetDeviceName) == true
        else { return }

        print("🏍️ Found Target Hardware: \(peripheral.name ?? "Unknown")")
        central.stopScan()
        m.targetPeripheral  = peripheral
        peripheral.delegate = self
        m.status            = .connecting
        central.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true
        ])
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let m = manager else { return }
        m.status = .connected
        m.connectedPeripheral = peripheral
        
        // Stop active scan to conserve power now that connection is established
        central.stopScan()
        
        // Save successfully connected peripheral UUID string to cache for subsequent launches
        let uuidString = peripheral.identifier.uuidString
        UserDefaults.standard.set(uuidString, forKey: "LAST_CONNECTED_PERIPHERAL_UUID")
        print("💾 Saved last connected peripheral UUID: \(uuidString)")
        
        print("🔗 Connected! Discovering ALL custom services...")
        // Passing nil forces iOS to map the entire hardware profile
        peripheral.discoverServices(nil) 
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        guard let m = manager else { return }
        m.status = .disconnected
        
        // Only retry connection if the UUID is still saved in UserDefaults (not manually cleared)
        if UserDefaults.standard.string(forKey: "LAST_CONNECTED_PERIPHERAL_UUID") == peripheral.identifier.uuidString {
            print("🔄 Connection failed. Retrying direct connection...")
            central.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                CBConnectPeripheralOptionNotifyOnNotificationKey: true
            ])
        } else {
            print("🔄 Connection failed. Fallback to scanning...")
            DispatchQueue.main.async { m.startScanning() }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard let m = manager else { return }
        m.stopHeartbeat()
        m.status              = .disconnected
        m.connectedPeripheral = nil
        m.txCharacteristic    = nil
        m.resetHandshakeState()
        
        // Bike disconnected or powered down. Queue a background connection request immediately
        // only if the UUID is still saved in UserDefaults (meaning no manual refresh/reset is active).
        if UserDefaults.standard.string(forKey: "LAST_CONNECTED_PERIPHERAL_UUID") == peripheral.identifier.uuidString {
            print("🔄 Bike disconnected. Queuing background reconnection request for \(peripheral.identifier.uuidString)...")
            m.status = .connecting
            central.connect(peripheral, options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                CBConnectPeripheralOptionNotifyOnNotificationKey: true
            ])
        } else {
            print("🔄 Manual refresh or reset active. Fallback to scanning...")
            DispatchQueue.main.async { m.startScanning() }
        }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error {
            print("⚠️ Service discovery error: \(e.localizedDescription)")
            return
        }
        guard let services = peripheral.services else { return }
        for service in services {
            print("📁 Discovered Service Folder: \(service.uuid)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let e = error {
            print("⚠️ Characteristic discovery error: \(e.localizedDescription)")
            return
        }
        guard let chars = service.characteristics,
              let m = manager else { return }
        
        for char in chars {
            print("  ↳ Characteristic Found: \(char.uuid) | Properties: \(char.properties)")
            
            // Save characteristic references
            if char.uuid == AppConfiguration.securityStatusUUID {
                m.securityStatusChar = char
            } else if char.uuid == AppConfiguration.securityControlPointUUID {
                m.securityControlPointChar = char
            } else if char.uuid == AppConfiguration.securityDataSourceUUID {
                m.securityDataSourceChar = char
            } else if char.uuid == AppConfiguration.displayCharUUID {
                print("🔥 Assigned TX Characteristic!")
                m.txCharacteristic = char
            } else if char.uuid == AppConfiguration.assignmentControlUUID {
                m.assignmentControlChar = char
            } else if char.uuid == AppConfiguration.buttonCharUUID {
                m.functionSourceChar = char
            }
            
            // 2. Limit notification subscriptions to ONLY critical channels to prevent flooding
            let notifyUUIDs: Set<CBUUID> = [
                AppConfiguration.buttonCharUUID,
                AppConfiguration.assignmentControlUUID,
                AppConfiguration.displayCharUUID,
                CBUUID(string: "2A19") // Battery Level
            ]
            if notifyUUIDs.contains(char.uuid) {
                if char.properties.contains(.notify) || char.properties.contains(.indicate) {
                    print("    📡 Subscribing to RX Notifications on characteristic: \(char.uuid)")
                    peripheral.setNotifyValue(true, for: char)
                }
            }
        }
        
        // Check and trigger security handshake
        m.checkAndTriggerHandshake()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let e = error {
            print("⚠️ BLE write error for \(characteristic.uuid): \(e.localizedDescription)")
            manager?.handleWriteError(characteristic: characteristic, error: e)
        } else {
            manager?.handleDidWriteValue(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            print("⚠️ Notification subscription failed for \(characteristic.uuid): \(error.localizedDescription)")
        } else {
            print("✅ Notification subscription state updated for \(characteristic.uuid): isNotifying = \(characteristic.isNotifying)")
        }
    }
    
    // MARK: - Handlebar Button Listener (RX Incoming Stream)
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        
        if let error = error {
            print("⚠️ Incoming data read error for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        
        guard let data = characteristic.value else { return }
        guard let m = manager else { return }
        
        // Handle Security Status read response
        if characteristic.uuid == AppConfiguration.securityStatusUUID {
            m.handleSecurityStatusRead(data: data)
            return
        }
        
        // Handle Security Data Source read response
        if characteristic.uuid == AppConfiguration.securityDataSourceUUID {
            m.handleSecurityDataSourceRead(data: data)
            return
        }
        
        // Handle Assignment Control notification receipt
        if characteristic.uuid == AppConfiguration.assignmentControlUUID {
            m.handleAssignmentControlNotification(data: data)
            return
        }
        
        if data.isEmpty { return }
        
        // Print the FULL byte array to see exactly what Honda is sending
        let hexArray = data.map { String(format: "%02x", $0) }
        print("🏍️ RAW PACKET [\(characteristic.uuid)]: \(hexArray)")
        
        // Check if this packet came from the handlebar button characteristic
        if characteristic.uuid == AppConfiguration.buttonCharUUID {
            let firstByte = data.first!
            print("🏍️ Decoded handlebar button code: 0x\(String(format: "%02x", firstByte)) (decimal: \(firstByte))")
            
            switch firstByte {
            case 0x01: // PREVIOUS (Left switch / Back track)
                print("⏮️ Bike requested Previous Track")
                SystemMediaController.shared.previousTrack()
                
            case 0x02: // NEXT (Right switch / Next track)
                print("⏭️ Bike requested Next Track")
                SystemMediaController.shared.nextTrack()
                
            case 0x03: // BACK
                print("⏮️ Bike requested Back")
                
            case 0x04: // SELECT (Center press / Play/Pause toggle)
                print("⏯️ Bike requested Play/Pause Toggle")
                SystemMediaController.shared.togglePlayPause()
                
            case 0x05: // VOLUME_UP
                print("🔊 Bike requested Volume Up")
                
            case 0x06: // VOLUME_DOWN
                print("🔉 Bike requested Volume Down")
                
            case 0x07: // VOLUME_MUTE
                print("🔇 Bike requested Mute")
                
            case 0x08: // MENU
                print("📋 Bike requested Menu")
                
            case 0x09: // MODE_SAB
                print("🏍️ RoadSync Mode Active (MODE_SAB)")
                
            case 0x0A: // MODE_HU
                print("🏍️ HeadUnit Mode Active (MODE_HU)")
                
            default:
                print("❓ Unknown button function byte: 0x\(String(format: "%02x", firstByte))")
            }
        }
    }
}

// MARK: — BluetoothManager

enum HandshakeState {
    case unverified
    case readingStatus
    case exchangingKeys(keyPair: RSAKeyPair)
    case validating(key: Data)
    case assigning
    case verified(key: Data)
    case failed(String)
}

final class BluetoothManager: ObservableObject {

    static let shared = BluetoothManager()

    @Published var status: BLEStatus = .poweredOff
    @Published var connectedPeripheral: CBPeripheral?
    @Published var handshakeState: HandshakeState = .unverified
    @Published var isNavigationActive: Bool = false

    fileprivate var txCharacteristic: CBCharacteristic?
    fileprivate var targetPeripheral: CBPeripheral?
    fileprivate var heartbeatTimer: Timer?

    fileprivate var securityStatusChar: CBCharacteristic?
    fileprivate var securityControlPointChar: CBCharacteristic?
    fileprivate var securityDataSourceChar: CBCharacteristic?
    fileprivate var assignmentControlChar: CBCharacteristic?
    fileprivate var functionSourceChar: CBCharacteristic?

    private var savedAESKey: Data?
    private var pendingAssignments: [Data] = []
    private var currentAssignment: Data?

    private let  bleDelegate: BLEDelegate
    private var  centralManager: CBCentralManager!

    private init() {
        bleDelegate = BLEDelegate()
        bleDelegate.manager = self
        centralManager = CBCentralManager(
            delegate: bleDelegate,
            queue: nil,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: true,
                CBCentralManagerOptionRestoreIdentifierKey: "com.priyajit.MotosyncBridge.centralRestorationIdentifier"
            ]
        )
    }

    // MARK: Public API
    
    // Auto-connect to the last successfully connected peripheral identifier cached in UserDefaults
    func reconnectToLastKnownPeripheral() -> Bool {
        guard let uuidStr = UserDefaults.standard.string(forKey: "LAST_CONNECTED_PERIPHERAL_UUID"),
              let uuid = UUID(uuidString: uuidStr) else {
            return false
        }
        
        print("🔄 Retrieving last known peripheral with UUID: \(uuidStr)")
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        if let lastPeripheral = peripherals.first {
            print("🔄 Found last known peripheral in system cache. Initiating direct reconnection...")
            self.targetPeripheral = lastPeripheral
            self.connectedPeripheral = lastPeripheral
            lastPeripheral.delegate = self.bleDelegate
            self.status = .connecting
            
            // Reconnect options queued indefinitely by the OS
            centralManager.connect(lastPeripheral, options: [
                CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                CBConnectPeripheralOptionNotifyOnNotificationKey: true
            ])
            return true
        }
        return false
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        status = .scanning
        
        // Scan with nil services in foreground to guarantee finding the BTU name
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func manualRefresh() {
        print("🔄 Manual Bluetooth Refresh Requested...")
        
        stopHeartbeat()
        
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        } else if let peripheral = targetPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        
        connectedPeripheral = nil
        targetPeripheral = nil
        txCharacteristic = nil
        resetHandshakeState()
        
        // Clear the saved UUID to allow fresh pairing
        UserDefaults.standard.removeObject(forKey: "LAST_CONNECTED_PERIPHERAL_UUID")
        
        status = .disconnected
        
        // Start scanning after a brief delay to allow clean cancellation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startScanning()
        }
    }

    // Auto-incrementing requestId tracking for GATT display commands
    private var lastRequestId: UInt8 = 0
    private func nextRequestId() -> UInt8 {
        let id = lastRequestId
        lastRequestId = lastRequestId &+ 1
        return id
    }

    // Latest track/artist as reported by MediaObserver.
    // Updated by DashboardViewModel so succeedHandshake can push immediately.
    private(set) var lastKnownTrack:  String = "No Media Playing"
    private(set) var lastKnownArtist: String = "Unknown Artist"

    func updateKnownMetadata(track: String, artist: String) {
        lastKnownTrack  = track
        lastKnownArtist = artist
    }

    // Sends REQUEST_SAB_MODE (0x0A) to switch console into SAB display mode.
    // Must be called once after handshake before any MYSTERY_BOX projection.
    func sendSABModeRequest() {
        guard let peripheral = connectedPeripheral,
              let txChar = txCharacteristic else { return }
        guard case .verified = handshakeState else { return }
        let rid = nextRequestId()
        let packet = MusicEncoder.generateSABModeRequest(requestId: rid)
        let hex = packet.map { String(format: "%02x", $0) }
        print("🏍️ → SAB MODE REQUEST [\(rid)]: \(hex)")
        peripheral.writeValue(packet, for: txChar, type: .withoutResponse)
    }

    // Sends dynamic LiveScreen projection packet (MYSTERY_BOX / 0x01).
    func sendMetadata(track: String, artist: String) {
        guard !isNavigationActive else { return }
        guard let peripheral = connectedPeripheral,
              let txChar = txCharacteristic else { return }
        // Verify we are handshaked/secured before allowing display updates
        guard case .verified = handshakeState else {
            print("⚠️ Metadata send deferred: security handshake not completed yet.")
            return
        }
        let rid = nextRequestId()
        let packet = MusicEncoder.generateDisplayPacket(requestId: rid, title: track, artist: artist)
        let hex = packet.map { String(format: "%02x", $0) }
        print("🎵 → MYSTERY_BOX [rid=\(rid), \(packet.count)B]: \(hex)")
        peripheral.writeValue(packet, for: txChar, type: .withoutResponse)
    }

    // Sends dynamic LiveScreen projection packet formatted for navigation.
    func sendNavigationInfo(iconId: UInt8, distance: String, instruction: String) {
        guard let peripheral = connectedPeripheral,
              let txChar = txCharacteristic else { return }
        // Verify we are handshaked/secured before allowing display updates
        guard case .verified = handshakeState else {
            print("⚠️ Navigation send deferred: security handshake not completed yet.")
            return
        }
        let rid = nextRequestId()
        let packet = NavigationEncoder.generateNavigationPacket(requestId: rid, iconId: iconId, distance: distance, instruction: instruction)
        let hex = packet.map { String(format: "%02x", $0) }
        print("🗺️ → NAVIGATION MYSTERY_BOX [rid=\(rid), \(packet.count)B]: \(hex)")
        peripheral.writeValue(packet, for: txChar, type: .withoutResponse)
    }

    // MARK: Heartbeat
    // Writes a 5-byte POP_UP keepalive heartbeat every 2000ms

    fileprivate func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
            [weak self] _ in
            guard let self,
                  let peripheral = self.connectedPeripheral,
                  let char = self.txCharacteristic else { return }
            let rid = self.nextRequestId()
            let packet = MusicEncoder.generateHeartbeat(requestId: rid)
            peripheral.writeValue(packet, for: char, type: .withoutResponse)
        }
        RunLoop.main.add(heartbeatTimer!, forMode: .common)
    }

    fileprivate func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    fileprivate func resetHandshakeState() {
        handshakeState = .unverified
        securityStatusChar = nil
        securityControlPointChar = nil
        securityDataSourceChar = nil
        assignmentControlChar = nil
        functionSourceChar = nil
        savedAESKey = nil
        pendingAssignments.removeAll()
        currentAssignment = nil
    }

    // MARK: — Handshake Flow

    fileprivate func checkAndTriggerHandshake() {
        guard let peripheral = connectedPeripheral,
              let _ = securityStatusChar,
              let _ = securityControlPointChar,
              let _ = securityDataSourceChar
        else { return }

        guard case .unverified = handshakeState else { return }

        print("🔒 Security characteristics discovered. Reading security status...")
        handshakeState = .readingStatus
        peripheral.readValue(for: securityStatusChar!)
    }

    fileprivate func handleSecurityStatusRead(data: Data) {
        let isSecured = data.first == 1
        print("🔒 Security Status read: \(isSecured ? "Secured (1)" : "Not Secured (0)")")

        let savedKeyKey = "AES_SESSION_KEY_\(connectedPeripheral?.identifier.uuidString ?? "")"
        let savedKey = UserDefaults.standard.data(forKey: savedKeyKey)

        if isSecured {
            if let key = savedKey {
                print("🔒 Saved AES key found. Validating connection...")
                savedAESKey = key
                performKeyValidation(key: key)
            } else {
                print("⚠️ Bike reports secured, but no key is saved locally. Forcing Secure Exchange...")
                performSecureExchange()
            }
        } else {
            print("🔒 Console is unsecured. Starting Secure Exchange...")
            performSecureExchange()
        }
    }

    fileprivate func performSecureExchange() {
        guard let keyPair = RSAKeyPair.generate() else {
            failHandshake(reason: "RSA KeyPair generation failed")
            return
        }

        handshakeState = .exchangingKeys(keyPair: keyPair)
        print("🔒 RSA KeyPair generated. Sending Modulus (\(keyPair.modulus.count) bytes) to Control Point...")

        var packet = Data()
        packet.append(0x02) // Command Id: SECURE_EXCHANGE
        packet.append(keyPair.modulus)

        guard let controlPointChar = securityControlPointChar else {
            failHandshake(reason: "Control Point characteristic missing")
            return
        }

        connectedPeripheral?.writeValue(packet, for: controlPointChar, type: .withResponse)
    }

    fileprivate func handleSecurityDataSourceRead(data: Data) {
        switch handshakeState {
        case .exchangingKeys(let keyPair):
            processSecureExchangeResponse(data: data, keyPair: keyPair)
        case .validating(let key):
            processKeyValidationResponse(data: data, key: key)
        default:
            print("⚠️ Received unexpected DataSource read in state: \(handshakeState)")
        }
    }

    private func processSecureExchangeResponse(data: Data, keyPair: RSAKeyPair) {
        print("🔒 Received Secure Exchange response (\(data.count) bytes). Decrypting...")

        guard data.count != 1 else {
            failHandshake(reason: "Secure exchange rejected by console (received error byte)")
            return
        }

        guard let decrypted = keyPair.decryptNoPadding(data: data) else {
            failHandshake(reason: "RSA decryption failed")
            return
        }

        guard decrypted.count >= 128 else {
            failHandshake(reason: "Decrypted payload too short (\(decrypted.count) bytes)")
            return
        }

        let aesKey = decrypted.subdata(in: 110..<126)
        let receivedCrc = decrypted.subdata(in: 126..<128)

        let computedCrc = Checksum.calculateBytes(for: aesKey)
        if computedCrc == receivedCrc {
            print("🔒 AES session key decrypted and CRC verified successfully!")
            performKeyValidation(key: aesKey)
        } else {
            failHandshake(reason: "CRC mismatch in session key (Received: \(receivedCrc.map { String(format: "%02x", $0) }), Computed: \(computedCrc.map { String(format: "%02x", $0) }))")
        }
    }

    private func performKeyValidation(key: Data) {
        handshakeState = .validating(key: key)

        let commandId: UInt8 = 0x03 // VALIDATION
        let commandData = Data([commandId])
        let crcBytes = Checksum.calculateBytes(for: commandData)

        var plain = Data()
        plain.append(commandId)
        plain.append(crcBytes)

        guard let encrypted = AESCryptor.encryptECB_PKCS7(data: plain, key: key) else {
            failHandshake(reason: "AES encryption of validation packet failed")
            return
        }

        var packet = Data()
        packet.append(0x01)
        packet.append(0x00) // Put little-endian short 1
        packet.append(encrypted)

        guard let controlPointChar = securityControlPointChar else {
            failHandshake(reason: "Control Point characteristic missing")
            return
        }

        print("🔒 Writing Validation packet to Control Point...")
        connectedPeripheral?.writeValue(packet, for: controlPointChar, type: .withResponse)
    }

    private func processKeyValidationResponse(data: Data, key: Data) {
        print("🔒 Received Key Validation response (\(data.count) bytes). Decrypting...")

        guard data.count > 2 else {
            failHandshake(reason: "GATT validation response too short (\(data.count) bytes)")
            return
        }

        let ciphertext = data.subdata(in: 2..<data.count)

        var decrypted: Data? = AESCryptor.decryptECB_PKCS7(data: ciphertext, key: key)
        if decrypted == nil {
            decrypted = AESCryptor.decryptECB_NoPadding(data: ciphertext, key: key)
        }

        guard let decryptedBytes = decrypted, !decryptedBytes.isEmpty else {
            failHandshake(reason: "AES decryption of validation response failed")
            return
        }

        let status = decryptedBytes[0]
        if status == 1 {
            if decryptedBytes.count >= 5 {
                let incrementId = decryptedBytes.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: UInt32.self) }
                print("🔒 Key validation successful! Increment ID: \(incrementId)")
            } else {
                print("🔒 Key validation successful!")
            }

            let savedKeyKey = "AES_SESSION_KEY_\(connectedPeripheral?.identifier.uuidString ?? "")"
            UserDefaults.standard.set(key, forKey: savedKeyKey)

            savedAESKey = key
            startAssignments()
        } else {
            failHandshake(reason: "GATT Key validation status error byte: \(status)")
        }
    }

    // MARK: - Button & Color Assignments
    
    private func buildAssignments() -> [Data] {
        var list: [Data] = []
        var counter: UInt16 = 0
        
        func nextRid() -> (UInt8, UInt8) {
            counter += 1
            return (UInt8(counter & 0xFF), UInt8((counter >> 8) & 0xFF))
        }
        
        // 1. VOLUME_UP
        let (r1L, r1H) = nextRid()
        list.append(Data([1, r1L, r1H, 5, 1, 7, 0x80, 0]))
        
        // 2. VOLUME_DOWN
        let (r2L, r2H) = nextRid()
        list.append(Data([1, r2L, r2H, 6, 1, 7, 0x81, 0]))
        
        // 3. PREVIOUS
        let (r3L, r3H) = nextRid()
        list.append(Data([1, r3L, r3H, 1, 2]))
        
        // 4. NEXT
        let (r4L, r4H) = nextRid()
        list.append(Data([1, r4L, r4H, 2, 2]))
        
        // 5. BACK
        let (r5L, r5H) = nextRid()
        list.append(Data([1, r5L, r5H, 3, 2]))
        
        // 6. SELECT
        let (r6L, r6H) = nextRid()
        list.append(Data([1, r6L, r6H, 4, 2]))
        
        // 7. VOLUME_MUTE
        let (r7L, r7H) = nextRid()
        list.append(Data([1, r7L, r7H, 7, 2]))
        
        // 8. MENU
        let (r8L, r8H) = nextRid()
        list.append(Data([1, r8L, r8H, 8, 2]))
        
        // 9. MODE_SAB
        let (r9L, r9H) = nextRid()
        list.append(Data([1, r9L, r9H, 9, 2]))
        
        // 10. MODE_HU
        let (r10L, r10H) = nextRid()
        list.append(Data([1, r10L, r10H, 10, 2]))
        
        // Register the 17 custom colors to ensure custom colors (like Orange 14) are registered
        let colors: [(UInt8, [UInt8])] = [
            (2, [0xD6, 0x47, 0x47]), // NEGATIVE
            (3, [0x38, 0xA8, 0x43]), // POSITIVE
            (4, [0x30, 0x9A, 0x87]), // GREEN_LIGHT
            (5, [0x24, 0x73, 0x65]), // GREEN
            (6, [0x0B, 0x27, 0x22]), // GREEN_DARK
            (7, [0x78, 0x46, 0xA3]), // PURPLE_LIGHT
            (8, [0x57, 0x32, 0x7A]), // PURPLE
            (9, [0x27, 0x16, 0x37]), // PURPLE_DARK
            (10, [0x45, 0x7A, 0xB1]), // BLUE_LIGHT
            (11, [0x34, 0x5C, 0x86]), // BLUE
            (12, [0x12, 0x1F, 0x2C]), // BLUE_DARK
            (13, [0xD8, 0x84, 0x2B]), // ORANGE_LIGHT
            (14, [0xAA, 0x69, 0x27]), // ORANGE
            (15, [0x4C, 0x28, 0x0A]), // ORANGE_DARK
            (16, [0x71, 0x71, 0x71]), // GREY_LIGHT
            (17, [0x4B, 0x4B, 0x4B]), // GREY
            (18, [0x27, 0x27, 0x27])  // GREY_DARK
        ]
        
        for (colorId, rgb) in colors {
            let (cL, cH) = nextRid()
            list.append(Data([2, cL, cH, colorId, rgb[0], rgb[1], rgb[2]]))
        }
        
        return list
    }
    
    fileprivate func startAssignments() {
        handshakeState = .assigning
        pendingAssignments = buildAssignments()
        sendNextAssignment()
    }
    
    private func sendNextAssignment() {
        guard let peripheral = connectedPeripheral,
              let char = assignmentControlChar else {
            failHandshake(reason: "Assignment Control characteristic missing")
            return
        }
        
        if pendingAssignments.isEmpty {
            print("🔒 All assignments registered successfully! Sending END_ASSIGNMENT...")
            sendEndAssignment()
            return
        }
        
        let assignment = pendingAssignments.removeFirst()
        currentAssignment = assignment
        
        let hex = assignment.map { String(format: "%02x", $0) }
        print("🔒 Sending Assignment: \(hex)")
        
        peripheral.writeValue(assignment, for: char, type: .withoutResponse)
        
        // Timeout retry mechanism in case response not received (2 seconds)
        let savedAssignment = assignment
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            if self.currentAssignment == savedAssignment {
                print("⚠️ Assignment confirmation timeout for \(hex). Retrying...")
                self.pendingAssignments.insert(savedAssignment, at: 0)
                self.sendNextAssignment()
            }
        }
    }
    
    fileprivate func handleAssignmentControlNotification(data: Data) {
        guard case .assigning = handshakeState,
              let current = currentAssignment else { return }
        
        let hex = data.map { String(format: "%02x", $0) }
        print("🔒 Assignment notification receipt: \(hex)")
        
        guard data.count >= 4 else { return }
        
        let commandId = data[0]
        let ridLow = data[1]
        let ridHigh = data[2]
        let status = data[3]
        
        if current[0] == commandId && current[1] == ridLow && current[2] == ridHigh {
            if status == 1 || status == 13 {
                // Success or already registered
                currentAssignment = nil
                sendNextAssignment()
            } else {
                failHandshake(reason: "Assignment failed with status: \(status)")
            }
        }
    }
    
    private func sendEndAssignment() {
        guard let peripheral = connectedPeripheral,
              let char = assignmentControlChar else {
            failHandshake(reason: "Assignment Control characteristic missing")
            return
        }
        
        let packet = Data([3])
        peripheral.writeValue(packet, for: char, type: .withoutResponse)
        
        print("🔒 END_ASSIGNMENT sent. Transitioning to secured state.")
        succeedSecuredState()
    }
    
    private func succeedSecuredState() {
        guard case .assigning = handshakeState,
              let key = savedAESKey else {
            failHandshake(reason: "Missing AES Session key in succeedSecuredState")
            return
        }
        
        handshakeState = .verified(key: key)
        print("🎉 Honda BTU Security & Assignments complete! Connection is SECURED.")
        
        // Vibrate phone twice and post lock screen notification to alert rider in background
        triggerConnectionAlert()
        
        // Step 1: Tell console to enter SAB display mode before sending any projection.
        sendSABModeRequest()

        // Step 2: Start keep-alive heartbeat (POP_UP, every 2s).
        startHeartbeat()

        // Step 3: Push current track info immediately
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sendMetadata(track: self.lastKnownTrack, artist: self.lastKnownArtist)
        }
    }

    private func triggerConnectionAlert() {
        // Vibrate twice with a short delay
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
        
        // Deliver local notification so it mirrors to Lock Screen / Apple Watch
        let content = UNMutableNotificationContent()
        content.title = "🏍️ Motosync Link Secured"
        content.body = "Successfully connected to Honda BTU dashboard."
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "motosync_connection_success",
            content: content,
            trigger: nil // Deliver immediately
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("⚠️ Failed to post connection notification: \(error.localizedDescription)")
            }
        }
    }

    fileprivate func failHandshake(reason: String) {
        print("❌ Handshake failed: \(reason)")
        handshakeState = .failed(reason)

        let savedKeyKey = "AES_SESSION_KEY_\(connectedPeripheral?.identifier.uuidString ?? "")"
        UserDefaults.standard.removeObject(forKey: savedKeyKey)

        print("🔒 Scheduling retry handshake in 3 seconds...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.status == .connected else { return }
            self.handshakeState = .unverified
            self.checkAndTriggerHandshake()
        }
    }

    fileprivate func handleWriteError(characteristic: CBCharacteristic, error: Error) {
        if characteristic.uuid == AppConfiguration.securityControlPointUUID {
            failHandshake(reason: "Write to Security Control Point failed: \(error.localizedDescription)")
        }
    }

    fileprivate func handleDidWriteValue(for characteristic: CBCharacteristic) {
        guard let peripheral = connectedPeripheral else { return }

        if characteristic.uuid == AppConfiguration.securityControlPointUUID {
            switch handshakeState {
            case .exchangingKeys:
                print("🔒 Modulus write complete. Reading encrypted key from DataSource...")
                if let dataSourceChar = securityDataSourceChar {
                    peripheral.readValue(for: dataSourceChar)
                }
            case .validating:
                print("🔒 Validation write complete. Reading status from DataSource...")
                if let dataSourceChar = securityDataSourceChar {
                    peripheral.readValue(for: dataSourceChar)
                }
            default:
                break
            }
        }
    }
}
