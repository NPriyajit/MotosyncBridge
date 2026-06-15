// MotosyncBridgeApp.swift — unchanged, included for completeness

import SwiftUI

@main
struct MotosyncBridgeApp: App {

    @StateObject private var bluetoothManager = BluetoothManager.shared
    @StateObject private var mediaObserver    = MediaObserver.shared

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(bluetoothManager)
                .environmentObject(mediaObserver)
        }
    }
}
