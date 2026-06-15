//
//  NavigationManager.swift
//  MotosyncBridge
//
//  Created by Priyajit Nayak on 14/06/26.
//

import Foundation
import MapKit
import CoreLocation
import Combine
import UserNotifications

enum HotspotCategory: String, CaseIterable {
    case food = "Restaurants"
    case gas = "Petrol"
    case atm = "ATMs"
    case coffee = "Cafes"
    case parking = "Parking"
    
    var searchKeyword: String {
        switch self {
        case .food: return "Restaurants"
        case .gas: return "Gas Station"
        case .atm: return "ATM"
        case .coffee: return "Coffee"
        case .parking: return "Parking"
        }
    }
    
    var sfSymbol: String {
        switch self {
        case .food: return "fork.knife"
        case .gas: return "fuelpump.fill"
        case .atm: return "dollarsign.circle"
        case .coffee: return "cup.and.saucer.fill"
        case .parking: return "p.circle.fill"
        }
    }
}

final class NavigationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    
    static let shared = NavigationManager()
    
    // Published navigation state
    @Published var userLocation: CLLocation?
    @Published var searchResults: [MKMapItem] = []
    @Published var selectedRoute: MKRoute?
    @Published var isNavigating: Bool = false
    
    // Step and guidance progress tracking
    @Published var currentStepIndex: Int = 0
    @Published var distanceToNextStep: CLLocationDistance = 0
    @Published var currentStepInstruction: String = ""
    @Published var currentManeuverIcon: UInt8 = 39 // Default to straight
    @Published var useEmojiArrows: Bool = true
    
    @Published var eta: Date?
    @Published var remainingDistance: CLLocationDistance = 0
    @Published var remainingDuration: TimeInterval = 0
    
    private let locationManager = CLLocationManager()
    private var activeSteps: [MKRoute.Step] = []
    private var lastNotifiedStepIndex: Int = -1
    
    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 5.0 // Update every 5 meters
        locationManager.activityType = .automotiveNavigation
        
        // Request in-use authorization initially (standard practice)
        locationManager.requestWhenInUseAuthorization()
        
        // Request permission for local notifications so alerts mirror to Apple Watch
        requestNotificationAuthorization()
    }
    
    // Request permission to mirror navigation prompts to Apple Watch
    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                print("✅ Navigation notification permissions granted.")
            } else if let error = error {
                print("⚠️ Notification permission error: \(error.localizedDescription)")
            }
        }
    }
    
    // Request always location usage if background operations are required
    func requestAlwaysLocationAuthorization() {
        locationManager.requestAlwaysAuthorization()
    }
    
    // Search destinations using MapKit
    func searchDestinations(query: String) {
        guard !query.isEmpty else {
            self.searchResults = []
            return
        }
        
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        
        // Center the search around the user's current location if available
        if let location = userLocation {
            request.region = MKCoordinateRegion(
                center: location.coordinate,
                latitudinalMeters: 50000,
                longitudinalMeters: 50000
            )
        }
        
        let search = MKLocalSearch(request: request)
        search.start { [weak self] response, error in
            guard let self = self else { return }
            if let error = error {
                print("⚠️ Search error: \(error.localizedDescription)")
                return
            }
            DispatchQueue.main.async {
                self.searchResults = response?.mapItems ?? []
            }
        }
    }
    
    // Search nearby hotspot categories
    func searchHotspots(category: HotspotCategory) {
        guard let location = userLocation else { return }
        
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = category.searchKeyword
        request.region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 5000,
            longitudinalMeters: 5000
        )
        
        let search = MKLocalSearch(request: request)
        search.start { [weak self] response, error in
            guard let self = self else { return }
            if let error = error {
                print("⚠️ Hotspot search error: \(error.localizedDescription)")
                return
            }
            DispatchQueue.main.async {
                self.searchResults = response?.mapItems ?? []
            }
        }
    }
    
    // Calculate route to a map destination
    func calculateRoute(to destination: MKMapItem, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let userLoc = userLocation else {
            completion(false)
            return
        }
        
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: userLoc.coordinate))
        request.destination = destination
        request.transportType = .automobile
        
        let directions = MKDirections(request: request)
        directions.calculate { [weak self] response, error in
            guard let self = self else {
                completion(false)
                return
            }
            
            if let error = error {
                print("⚠️ Route calculation failed: \(error.localizedDescription)")
                completion(false)
                return
            }
            
            guard let route = response?.routes.first else {
                completion(false)
                return
            }
            
            DispatchQueue.main.async {
                self.selectedRoute = route
                self.remainingDistance = route.distance
                self.remainingDuration = route.expectedTravelTime
                self.eta = Date().addingTimeInterval(route.expectedTravelTime)
                completion(true)
            }
        }
    }
    
    // Start active navigation
    func startNavigation() {
        guard let route = selectedRoute else { return }
        
        // Extract route steps and filter out empty instructions
        self.activeSteps = route.steps.filter { !$0.instructions.isEmpty }
        guard !self.activeSteps.isEmpty else { return }
        
        DispatchQueue.main.async {
            self.isNavigating = true
            self.currentStepIndex = 0
            self.lastNotifiedStepIndex = -1
            
            // Set up background location updates
            self.locationManager.allowsBackgroundLocationUpdates = true
            self.locationManager.showsBackgroundLocationIndicator = true
            self.locationManager.startUpdatingLocation()
            
            // Activate navigation override in BLE controller
            BluetoothManager.shared.isNavigationActive = true
            
            // Instantly send first step updates
            self.updateGuidance()
        }
    }
    
    // Stop active navigation
    func stopNavigation() {
        DispatchQueue.main.async {
            self.isNavigating = false
            
            // Disable background location updates to conserve power
            self.locationManager.allowsBackgroundLocationUpdates = false
            self.locationManager.showsBackgroundLocationIndicator = false
            self.locationManager.stopUpdatingLocation()
            
            // Disable navigation override in BLE controller
            BluetoothManager.shared.isNavigationActive = false
            
            // Push active media metadata back to display console immediately
            let bm = BluetoothManager.shared
            bm.sendMetadata(track: bm.lastKnownTrack, artist: bm.lastKnownArtist)
        }
    }
    
    // Clear route and reset all state to start fresh
    func clearRoute() {
        DispatchQueue.main.async {
            self.stopNavigation()
            self.selectedRoute = nil
            self.activeSteps = []
            self.currentStepIndex = 0
            self.lastNotifiedStepIndex = -1
            self.distanceToNextStep = 0
            self.currentStepInstruction = ""
        }
    }
    
    // Update active guidance details based on user position
    private func updateGuidance() {
        guard isNavigating, !activeSteps.isEmpty else { return }
        guard let userLoc = userLocation else { return }
        
        let currentStep = activeSteps[currentStepIndex]
        
        // Check if we can transition to the next step
        if currentStepIndex < activeSteps.count - 1 {
            let nextStep = activeSteps[currentStepIndex + 1]
            let nextStepStart = nextStep.polyline.coordinate
            let distanceToNext = distanceBetween(userLoc.coordinate, nextStepStart)
            
            // If user is within 35 meters of the next step starting point, advance the step
            if distanceToNext < 35.0 {
                currentStepIndex += 1
                updateGuidance()
                return
            }
        }
        
        // Calculate remaining distance for the current step
        // We measure the distance from the user to the start coordinate of the next step (if available)
        var stepRemainingDistance = currentStep.distance
        if currentStepIndex < activeSteps.count - 1 {
            let nextStepStart = activeSteps[currentStepIndex + 1].polyline.coordinate
            stepRemainingDistance = distanceBetween(userLoc.coordinate, nextStepStart)
        }
        
        // Update published state
        self.distanceToNextStep = stepRemainingDistance
        self.currentStepInstruction = currentStep.instructions
        self.currentManeuverIcon = parseManeuverIcon(from: currentStep.instructions, isFinalStep: currentStepIndex == activeSteps.count - 1)
        
        // Format strings
        let formattedDistance = formatDistance(stepRemainingDistance)
        let formattedInstruction = currentStep.instructions
        
        // Emoji-Data Routing Visual Hack: Format distance line to include the arrow graphic representation
        let arrow = parseManeuverArrow(from: currentStep.instructions, useEmoji: useEmojiArrows)
        let arrowDistanceText = "\(arrow) \(formattedDistance)"
        
        // Push guidance parameters to Bluetooth manager (use 0x02 Navigation icon while injecting text arrows)
        BluetoothManager.shared.sendNavigationInfo(
            iconId: 2, // Static NAVIGATION icon
            distance: arrowDistanceText,
            instruction: formattedInstruction
        )
        
        // Post local notifications (which automatically mirrors onto Apple Watch)
        if currentStepIndex != lastNotifiedStepIndex {
            lastNotifiedStepIndex = currentStepIndex
            triggerNotification(title: formattedDistance, body: formattedInstruction)
        }
    }
    
    // Core Location delegate method
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        DispatchQueue.main.async {
            self.userLocation = location
            
            if self.isNavigating {
                // Update ETA and route properties dynamically
                if let route = self.selectedRoute {
                    // Reduce overall remaining distance based on step progression
                    let completedStepsDistance = self.activeSteps.prefix(self.currentStepIndex).reduce(0.0) { $0 + $1.distance }
                    self.remainingDistance = max(0.0, route.distance - completedStepsDistance - (self.distanceToNextStep - self.activeSteps[self.currentStepIndex].distance))
                    
                    // Rough travel time approximation
                    let travelTimeFactor = self.remainingDistance / max(1.0, route.distance)
                    self.remainingDuration = route.expectedTravelTime * travelTimeFactor
                    self.eta = Date().addingTimeInterval(self.remainingDuration)
                }
                
                self.updateGuidance()
            }
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            // Start listening to coordinate updates to track position immediately
            locationManager.startUpdatingLocation()
        default:
            break
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("⚠️ CoreLocation Error: \(error.localizedDescription)")
    }
    
    // MARK: - Helper Utilities
    
    private func distanceBetween(_ coord1: CLLocationCoordinate2D, _ coord2: CLLocationCoordinate2D) -> CLLocationDistance {
        let loc1 = CLLocation(latitude: coord1.latitude, longitude: coord1.longitude)
        let loc2 = CLLocation(latitude: coord2.latitude, longitude: coord2.longitude)
        return loc1.distance(from: loc2)
    }
    
    private func formatDistance(_ meters: CLLocationDistance) -> String {
        if meters < 1000.0 {
            return "In \(Int(meters)) m"
        } else {
            return String(format: "In %.1f km", meters / 1000.0)
        }
    }
    
    // Parse the instruction string to determine the maneuver arrow symbol
    private func parseManeuverArrow(from instructions: String, useEmoji: Bool) -> String {
        let lower = instructions.lowercased()
        
        if useEmoji {
            if lower.contains("u-turn") || lower.contains("uturn") {
                return "↩️"
            } else if lower.contains("sharp left") {
                return "⬅️"
            } else if lower.contains("sharp right") {
                return "➡️"
            } else if lower.contains("slight left") || lower.contains("bear left") || lower.contains("keep left") {
                return "↖️"
            } else if lower.contains("slight right") || lower.contains("bear right") || lower.contains("keep right") {
                return "↗️"
            } else if lower.contains("turn left") || lower.contains("take the left") {
                return "⬅️"
            } else if lower.contains("turn right") || lower.contains("take the right") {
                return "➡️"
            } else if lower.contains("roundabout") || lower.contains("rotary") {
                // Check for specific roundabout exits
                if lower.contains("1st exit") {
                    return "🔄 1st exit"
                } else if lower.contains("2nd exit") {
                    return "🔄 2nd exit"
                } else if lower.contains("3rd exit") {
                    return "🔄 3rd exit"
                } else if lower.contains("4th exit") {
                    return "🔄 4th exit"
                }
                return "🔄"
            } else if lower.contains("merge") {
                return "🔀"
            } else if lower.contains("ramp") {
                return "↗️"
            } else if lower.contains("arrive") || lower.contains("destination") {
                return "🏁"
            }
            return "⬆️"
        } else {
            if lower.contains("u-turn") || lower.contains("uturn") {
                return "U-Turn"
            } else if lower.contains("sharp left") {
                return "<<-"
            } else if lower.contains("sharp right") {
                return "->>"
            } else if lower.contains("slight left") || lower.contains("bear left") || lower.contains("keep left") {
                return "\\-"
            } else if lower.contains("slight right") || lower.contains("bear right") || lower.contains("keep right") {
                return "-/"
            } else if lower.contains("turn left") || lower.contains("take the left") {
                return "<-"
            } else if lower.contains("turn right") || lower.contains("take the right") {
                return "->"
            } else if lower.contains("roundabout") || lower.contains("rotary") {
                if lower.contains("1st exit") {
                    return "(O) Exit 1"
                } else if lower.contains("2nd exit") {
                    return "(O) Exit 2"
                } else if lower.contains("3rd exit") {
                    return "(O) Exit 3"
                } else if lower.contains("4th exit") {
                    return "(O) Exit 4"
                }
                return "(O)"
            } else if lower.contains("merge") {
                return ">-<"
            } else if lower.contains("ramp") {
                return "Ramp"
            } else if lower.contains("arrive") || lower.contains("destination") {
                return "[End]"
            }
            return "^"
        }
    }
    
    // Parse the instruction string to determine the maneuver icon ID
    private func parseManeuverIcon(from instructions: String, isFinalStep: Bool) -> UInt8 {
        if isFinalStep {
            return 83 // DA_TURN_FLAG_END (Flag icon for arrival)
        }
        
        let lower = instructions.lowercased()
        
        if lower.contains("arrive") || lower.contains("destination") {
            return 40 // DA_TURN_ARRIVE
        } else if lower.contains("u-turn") || lower.contains("uturn") {
            return 47 // DA_TURN_UTURN
        } else if lower.contains("sharp left") {
            return 54 // DA_TURN_SHARP_LEFT
        } else if lower.contains("sharp right") {
            return 45 // DA_TURN_SHARP_RIGHT
        } else if lower.contains("slight left") || lower.contains("bear left") {
            return 55 // DA_TURN_SLIGHT_LEFT
        } else if lower.contains("slight right") || lower.contains("bear right") {
            return 46 // DA_TURN_SLIGHT_RIGHT
        } else if lower.contains("keep left") {
            return 55 // DA_TURN_SLIGHT_LEFT
        } else if lower.contains("keep right") {
            return 46 // DA_TURN_SLIGHT_RIGHT
        } else if lower.contains("turn left") || lower.contains("take the left") {
            return 53 // DA_TURN_LEFT
        } else if lower.contains("turn right") || lower.contains("take the right") {
            return 44 // DA_TURN_RIGHT
        } else if lower.contains("roundabout") || lower.contains("rotary") {
            // Check for specific roundabout exits
            if lower.contains("1st exit") {
                return 62 // DA_TURN_ROUNDABOUT_1
            } else if lower.contains("2nd exit") {
                return 63 // DA_TURN_ROUNDABOUT_2
            } else if lower.contains("3rd exit") {
                return 64 // DA_TURN_ROUNDABOUT_3
            } else if lower.contains("4th exit") {
                return 65 // DA_TURN_ROUNDABOUT_4
            } else if lower.contains("5th exit") {
                return 66 // DA_TURN_ROUNDABOUT_5
            } else if lower.contains("6th exit") {
                return 67 // DA_TURN_ROUNDABOUT_6
            } else if lower.contains("7th exit") {
                return 68 // DA_TURN_ROUNDABOUT_7
            } else if lower.contains("8th exit") {
                return 69 // DA_TURN_ROUNDABOUT_8
            }
            return 49 // DA_TURN_GENERIC_ROUNDABOUT
        } else if lower.contains("merge") {
            return 42 // DA_TURN_GENERIC_MERGE
        } else if lower.contains("ramp") {
            if lower.contains("left") {
                return 59 // DA_TURN_RAMP_LEFT
            } else {
                return 50 // DA_TURN_RAMP_RIGHT
            }
        }
        
        return 39 // DA_TURN_STRAIGHT
    }
    
    // Post local system notification which mirrors to paired Apple Watches automatically
    private func triggerNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "motosync_nav_turn",
            content: content,
            trigger: nil // Trigger immediately
        )
        
        UNUserNotificationCenter.current().add(request)
    }
}
