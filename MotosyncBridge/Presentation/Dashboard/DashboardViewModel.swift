// DashboardViewModel.swift — Motosync Bridge
// FIXED: uses .shared singleton, not a second BluetoothManager()

import Foundation
import Combine
import CoreBluetooth

@MainActor
final class DashboardViewModel: ObservableObject {

    @Published var connectionStatus: String = "Initializing..."
    @Published var trackTitle: String       = "No Media Playing"
    @Published var trackArtist: String      = "Unknown Artist"

    // FIX: reference shared singleton — not BluetoothManager()
    // which creates a competing CBCentralManager and never connects
    let bluetoothManager = BluetoothManager.shared
    let mediaObserver    = MediaObserver()

    private var cancellables = Set<AnyCancellable>()

    init() {
        setupBindings()
    }

    private func setupBindings() {
        bluetoothManager.$status
            .map { $0.rawValue }
            .receive(on: RunLoop.main)
            .assign(to: &$connectionStatus)

        mediaObserver.$currentTrack
            .receive(on: RunLoop.main)
            .assign(to: &$trackTitle)

        mediaObserver.$currentArtist
            .receive(on: RunLoop.main)
            .assign(to: &$trackArtist)

        mediaObserver.onMetadataChanged = { [weak self] title, artist in
            Task { @MainActor in
                self?.bluetoothManager.sendMetadata(track: title, artist: artist)
            }
        }
    }

    func startEngine() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.bluetoothManager.startScanning()
            self?.mediaObserver.fetchCurrentMedia()
        }
    }
}
