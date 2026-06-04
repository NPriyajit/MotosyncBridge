// BluetoothManager.swift — Motosync Bridge
// Payload format reverse-engineered from BleHardwareLink.ts:
//   MusicEncoder.generateDisplayPacket() → 141-byte fixed packet
//   Heartbeat → single 0x01 byte, not "PING"

import Foundation
import CoreBluetooth
import Combine

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
    static let packetSize   = 141
    static let titleOffset  = 2
    static let titleLength  = 70
    static let artistOffset = 72
    static let artistLength = 69

    static func generateDisplayPacket(title: String, artist: String) -> Data {
        var packet = [UInt8](repeating: 0x00, count: packetSize)
        packet[0] = 0x01  // packet type: track update
        packet[1] = 0x00  // reserved

        func writeString(_ s: String, at offset: Int, maxLen: Int) {
            let bytes = Array(s.utf8.prefix(maxLen))
            for (i, b) in bytes.enumerated() { packet[offset + i] = b }
        }

        writeString(title,  at: titleOffset,  maxLen: titleLength)
        writeString(artist, at: artistOffset, maxLen: artistLength)

        return Data(packet)
    }

    // Single-byte keep-alive matching RN: new Uint8Array([0x01])
    static var heartbeatPacket: Data { Data([0x01]) }
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
            
            // 1. Map TX (Transmit) pipeline for 141-byte data ingestion
            
            if char.uuid == AppConfiguration.displayCharUUID {
                print("🔥 Assigned TX Characteristic! Initializing display stream...")
                m.txCharacteristic = char
                m.startHeartbeat()
            }
            
            // 2. Automatically subscribe to RX (Notify/Indicate) for bike button events
            if char.properties.contains(.notify) || char.properties.contains(.indicate) {
                print("    📡 Subscribing to RX Notifications on characteristic: \(char.uuid)")
                peripheral.setNotifyValue(true, for: char)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let e = error {
            print("⚠️ BLE write error: \(e.localizedDescription)")
        }
    }
    
    // MARK: - Handlebar Button Listener (RX Incoming Stream)
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let e = error {
            print("⚠️ Incoming data read error: \(e.localizedDescription)")
            return
        }
        
        guard let data = characteristic.value else { return }
        
        // Formats the incoming buffer into a human-readable stream of hex bytes
        let hexString = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("🏍️ HONDA RAW PACKET RECEIVED: [\(hexString)] from UUID: \(characteristic.uuid)")
        
        // Handle physical button clicks here once the hex layout is determined
    }
}
// MARK: — BluetoothManager

final class BluetoothManager: ObservableObject {

    static let shared = BluetoothManager()

    @Published var status: BLEStatus = .poweredOff
    @Published var connectedPeripheral: CBPeripheral?

    fileprivate var txCharacteristic: CBCharacteristic?
    fileprivate var targetPeripheral: CBPeripheral?
    fileprivate var heartbeatTimer: Timer?

    // Matches TARGET_BROADCAST_NAME — prefix so "HONDA BTU 9A43" is caught

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

    // Sends 141-byte encoded packet — matches MusicEncoder.generateDisplayPacket()
    func sendMetadata(track: String, artist: String) {
        guard let peripheral = connectedPeripheral,
              let txChar = txCharacteristic else { return }
        let packet = MusicEncoder.generateDisplayPacket(title: track, artist: artist)
        peripheral.writeValue(packet, for: txChar, type: .withoutResponse)
    }

    // MARK: Heartbeat
    // Matches RN: new Uint8Array([0x01]) every HEARTBEAT_INTERVAL_MS (2000ms)

    fileprivate func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
            [weak self] _ in
            guard let self,
                  let peripheral = self.connectedPeripheral,
                  let char = self.txCharacteristic else { return }
            peripheral.writeValue(MusicEncoder.heartbeatPacket, for: char, type: .withoutResponse)
        }
        RunLoop.main.add(heartbeatTimer!, forMode: .common)
    }

    fileprivate func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
}
