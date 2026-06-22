// MotosyncBridgeApp.swift

import SwiftUI
import SwiftData

@main
struct MotosyncBridgeApp: App {

    @StateObject private var bluetoothManager = BluetoothManager.shared
    @StateObject private var mediaObserver    = MediaObserver.shared

    init() {
        // Initialize TelemetryManager to activate BLE and sensor status observers
        _ = TelemetryManager.shared
    }

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(bluetoothManager)
                .environmentObject(mediaObserver)
                .modelContainer(for: [RideSession.self, RideLocation.self, RideAnomaly.self])
        }
    }
}
