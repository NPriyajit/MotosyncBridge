//
//  TelemetryManager.swift
//  MotosyncBridge
//

import Foundation
import CoreMotion
import CoreLocation
import Combine
import SwiftData

@MainActor
final class TelemetryManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = TelemetryManager()
    
    @Published var isLoggingActive = false
    @Published var currentSession: RideSession?
    
    private let motionManager = CMMotionManager()
    private let locationManager = CLLocationManager()
    
    // SwiftData container & context
    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?
    
    // Low pass filter state
    private var lastLPValue: Double = 0.0
    private var isLPInitialized = false
    
    // Moving average window for pocket mode
    private var pocketWindow: [Double] = []
    
    // Cooldown logic
    private var lastAnomalyTime: Date?
    private let cooldownWindow: TimeInterval = 1.0
    
    // Coordinates caching
    private var lastKnownLocation: CLLocation?
    
    // Combine subscription
    private var cancellables = Set<AnyCancellable>()
    
    private override init() {
        super.init()
        
        // Setup SwiftData
        do {
            let schema = Schema([
                RideSession.self,
                RideLocation.self,
                RideAnomaly.self
            ])
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            let container = try ModelContainer(for: schema, configurations: [config])
            self.modelContainer = container
            self.modelContext = ModelContext(container)
            print("✅ Telemetry SwiftData container initialized successfully.")
        } catch {
            print("❌ Failed to initialize SwiftData container: \(error.localizedDescription)")
        }
        
        // Setup Bluetooth observers
        setupBluetoothObservers()
    }
    
    private func setupBluetoothObservers() {
        // Observe status to know when fully disconnected
        BluetoothManager.shared.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                if status == .disconnected && self.isLoggingActive {
                    print("🏍️ BLE status disconnected. Ending telemetry session...")
                    self.stopLoggingSession()
                }
            }
            .store(in: &cancellables)
            
        // Observe handshake state to start session when secured
        BluetoothManager.shared.$handshakeState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .verified:
                    if !self.isLoggingActive {
                        print("🔒 BLE connection secured. Starting telemetry session...")
                        self.startLoggingSession()
                    }
                case .unverified, .failed:
                    if self.isLoggingActive {
                        print("🔒 BLE handshake lost/failed. Ending telemetry session...")
                        self.stopLoggingSession()
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }
    
    func startLoggingSession() {
        // Verify user configuration
        guard AppConfiguration.isRideLoggingEnabled else {
            print("ℹ️ Ride intelligence telemetry is disabled by the user.")
            return
        }
        
        guard !isLoggingActive else { return }
        
        print("🚀 Spinning up ride logging session...")
        isLoggingActive = true
        
        // Initialize new session
        let placementString = AppConfiguration.phonePlacement.rawValue
        let session = RideSession(phonePlacement: placementString)
        modelContext?.insert(session)
        self.currentSession = session
        
        // Reset filter states
        isLPInitialized = false
        lastLPValue = 0.0
        pocketWindow.removeAll()
        lastAnomalyTime = nil
        lastKnownLocation = nil
        
        // Start Location Manager
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.startUpdatingLocation()
        
        // Start CoreMotion device motion updates at 10Hz
        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 0.1 // 10Hz
            motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
                guard let self = self, let motion = motion else { return }
                Task { @MainActor in
                    self.processMotionSample(motion)
                }
            }
            print("📳 CoreMotion 10Hz updates started.")
        } else {
            print("⚠️ DeviceMotion is not available on this hardware.")
        }
    }
    
    func stopLoggingSession() {
        guard isLoggingActive, let session = currentSession else { return }
        
        print("🛑 Shutting down ride logging session...")
        
        // Stop sensor loops
        motionManager.stopDeviceMotionUpdates()
        locationManager.stopUpdatingLocation()
        
        session.endTime = Date()
        let duration = session.endTime!.timeIntervalSince(session.startTime)
        
        // Discard short sessions (< 10 seconds) to avoid database bloat
        if duration < 10.0 {
            modelContext?.delete(session)
            try? modelContext?.save()
            print("🗑️ Discarded ultra-short telemetry session (duration: \(String(format: "%.1f", duration))s).")
            self.currentSession = nil
            self.isLoggingActive = false
            return
        }
        
        // Calculate smoothness score
        let anomalyCount = session.anomalies.count
        session.smoothnessScore = calculateSmoothnessScore(duration: duration, anomalyCount: anomalyCount)
        
        do {
            try modelContext?.save()
            print("💾 Telemetry session saved successfully: Score \(session.smoothnessScore), \(anomalyCount) anomalies, duration: \(String(format: "%.1f", duration))s.")
        } catch {
            print("❌ Failed to save ride session: \(error.localizedDescription)")
        }
        
        self.currentSession = nil
        self.isLoggingActive = false
    }
    
    private func processMotionSample(_ motion: CMDeviceMotion) {
        guard isLoggingActive else { return }
        
        // 1. Evaluate user's vertical acceleration vector (Az) by projecting userAcceleration onto gravity
        let userAcc = motion.userAcceleration
        let gravity = motion.gravity
        
        let Az = (userAcc.x * gravity.x) + (userAcc.y * gravity.y) + (userAcc.z * gravity.z)
        
        // 2. High-Pass Filter to eliminate DC/gravity component: LP[n] = alpha * LP[n-1] + (1 - alpha) * Az, HP[n] = Az - LP[n]
        let alpha = 0.9
        if !isLPInitialized {
            lastLPValue = Az
            isLPInitialized = true
        }
        let LPValue = (alpha * lastLPValue) + ((1.0 - alpha) * Az)
        lastLPValue = LPValue
        let HPValue = Az - LPValue
        
        // 3. Process according to profile mode
        let mode = AppConfiguration.phonePlacement
        var deltaAz: Double = 0.0
        var isTriggered = false
        
        switch mode {
        case .handlebar:
            // High-pass filter spike within single sample (0.1s)
            deltaAz = abs(HPValue)
            isTriggered = deltaAz > 1.5
            
        case .pocket:
            // Moving average window of 4 samples (0.4s)
            pocketWindow.append(abs(HPValue))
            if pocketWindow.count > 4 {
                pocketWindow.removeFirst()
            }
            
            // Calculate Moving Average
            if pocketWindow.count == 4 {
                let sum = pocketWindow.reduce(0.0, +)
                deltaAz = sum / 4.0
                isTriggered = deltaAz > 0.6
            }
        }
        
        // 4. Handle anomaly triggering with cooldown refractory period
        if isTriggered {
            let now = Date()
            if let lastTime = lastAnomalyTime, now.timeIntervalSince(lastTime) < cooldownWindow {
                return
            }
            
            lastAnomalyTime = now
            logAnomaly(magnitude: deltaAz, timestamp: now)
        }
    }
    
    private func logAnomaly(magnitude: Double, timestamp: Date) {
        guard let session = currentSession else { return }
        
        let lat = lastKnownLocation?.coordinate.latitude ?? 0.0
        let lon = lastKnownLocation?.coordinate.longitude ?? 0.0
        
        let anomaly = RideAnomaly(
            timestamp: timestamp,
            latitude: lat,
            longitude: lon,
            magnitude: magnitude
        )
        session.anomalies.append(anomaly)
        
        print("⚠️ Flagged Road Anomaly! Magnitude: \(String(format: "%.2fg", magnitude)) at (\(lat), \(lon))")
        try? modelContext?.save()
    }
    
    private func calculateSmoothnessScore(duration: TimeInterval, anomalyCount: Int) -> Int {
        if anomalyCount == 0 {
            return 100
        }
        
        let averageInterval = duration / Double(anomalyCount)
        
        // Linear scale bounds
        let minInterval: Double = 5.0
        let maxInterval: Double = 300.0
        
        if averageInterval <= minInterval {
            return 0
        } else if averageInterval >= maxInterval {
            return 100
        } else {
            let percentage = (averageInterval - minInterval) / (maxInterval - minInterval)
            return Int(percentage * 100.0)
        }
    }
    
    // MARK: - CLLocationManagerDelegate
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isLoggingActive, let location = locations.last else { return }
        
        self.lastKnownLocation = location
        
        let rideLoc = RideLocation(
            timestamp: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            speed: max(0.0, location.speed),
            altitude: location.altitude
        )
        
        currentSession?.locations.append(rideLoc)
        try? modelContext?.save()
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("⚠️ Telemetry Location Manager error: \(error.localizedDescription)")
    }
}
