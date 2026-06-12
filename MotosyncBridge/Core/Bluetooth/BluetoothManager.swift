// BluetoothManager.swift — Motosync Bridge
// Payload format reverse-engineered from BleHardwareLink.ts:
//   MusicEncoder.generateDisplayPacket() → 141-byte fixed packet
//   Heartbeat → single 0x01 byte, not "PING"

import Foundation
import CoreBluetooth
import Combine
import MediaPlayer

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
        
        // 10. Content Icon ID: MUSIC (3)
        packet.append(3)
        // 11. Content Icon Tint Color: PURE_WHITE (0)
        packet.append(0)
        
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

    // Dynamic 5-byte keep-alive matching POP_UP layout with zeroed fields.
    static func generateHeartbeat(requestId: UInt8) -> Data {
        return Data([0x02, requestId, 0x00, 0x00, 0x00])
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

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let m = manager else { return }
        switch central.state {
        case .poweredOn:    m.startScanning()
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
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let m = manager else { return }
        m.status = .connected
        m.connectedPeripheral = peripheral
        
        print("🔗 Connected! Discovering ALL custom services...")
        // Passing nil forces iOS to map the entire hardware profile
        peripheral.discoverServices(nil) 
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        guard let m = manager else { return }
        m.status = .disconnected
        DispatchQueue.main.async { m.startScanning() }
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
        DispatchQueue.main.async { m.startScanning() }
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
            }
            
            // 2. Automatically subscribe to RX (Notify/Indicate) for bike button events
            if char.properties.contains(.notify) || char.properties.contains(.indicate) {
                print("    📡 Subscribing to RX Notifications on characteristic: \(char.uuid)")
                peripheral.setNotifyValue(true, for: char)
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
    case verified(key: Data)
    case failed(String)
}

final class BluetoothManager: ObservableObject {

    static let shared = BluetoothManager()

    @Published var status: BLEStatus = .poweredOff
    @Published var connectedPeripheral: CBPeripheral?
    @Published var handshakeState: HandshakeState = .unverified

    fileprivate var txCharacteristic: CBCharacteristic?
    fileprivate var targetPeripheral: CBPeripheral?
    fileprivate var heartbeatTimer: Timer?

    fileprivate var securityStatusChar: CBCharacteristic?
    fileprivate var securityControlPointChar: CBCharacteristic?
    fileprivate var securityDataSourceChar: CBCharacteristic?

    private let  bleDelegate: BLEDelegate
    private var  centralManager: CBCentralManager!

    private init() {
        bleDelegate = BLEDelegate()
        bleDelegate.manager = self
        centralManager = CBCentralManager(
            delegate: bleDelegate,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    // MARK: Public API
    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        status = .scanning
        
        // References the centralized AppConfiguration file directly
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    // Auto-incrementing requestId tracking for GATT display commands
    private var lastRequestId: UInt8 = 0
    private func nextRequestId() -> UInt8 {
        let id = lastRequestId
        lastRequestId = lastRequestId &+ 1
        return id
    }

    // Sends dynamic LiveScreen projection packet
    func sendMetadata(track: String, artist: String) {
        guard let peripheral = connectedPeripheral,
              let txChar = txCharacteristic else { return }
        // Verify we are handshaked/secured before allowing display updates
        guard case .verified = handshakeState else {
            print("⚠️ Metadata send deferred: security handshake not completed yet.")
            return
        }
        let rid = nextRequestId()
        let packet = MusicEncoder.generateDisplayPacket(requestId: rid, title: track, artist: artist)
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

            succeedHandshake(key: key)
        } else {
            failHandshake(reason: "GATT Key validation status error byte: \(status)")
        }
    }

    private func succeedHandshake(key: Data) {
        handshakeState = .verified(key: key)
        print("🎉 Honda BTU Security validation complete! Connection is now SECURED.")
        startHeartbeat()
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
