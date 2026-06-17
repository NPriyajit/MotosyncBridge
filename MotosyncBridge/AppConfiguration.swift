//
//  AppConfiguration.swift
//  MotosyncBridge
//
//  Created by Priyajit Nayak on 04/06/26.
//

import Foundation
import CoreBluetooth

enum AppConfiguration {
    // Hardware Targets
    static let targetDeviceName = "HONDA BTU"
    
    // GATT Service Profile Mapping
    // Display/Data Service (DataCommunicationService)
    static let displayServiceUUID = CBUUID(string: "8536e103-6771-4d4b-9702-287cb5e1340f")
    static let displayCharUUID = CBUUID(string: "d2e23443-f1ad-4293-a70b-a9fd163f7b00") // Display control point
    static let buttonCharUUID = CBUUID(string: "6C060578-D1D9-460A-B86F-EB97F01B2227")
    static let assignmentControlUUID = CBUUID(string: "4F5FBE6B-474B-4820-833F-95BFBF525D9F")
    
    // Security Service
    static let securityServiceUUID = CBUUID(string: "592c1017-9c7b-4a35-aba6-f268592fb8fc")
    static let securityStatusUUID = CBUUID(string: "a65b7152-589e-4933-a426-8f729bfad439")
    static let securityControlPointUUID = CBUUID(string: "4fa28b27-6938-48f8-980e-7c7c9acc6c1e")
    static let securityDataSourceUUID = CBUUID(string: "ebb3656f-03a5-44ce-a22c-70cfccf5e247")
    
    // Engine Intervals
    static let heartbeatInterval: TimeInterval = 2.0
    static let mediaPollInterval: TimeInterval = 2.5
    
    // Media Control Mode
    enum MediaControlMode: String {
        case appleMusic = "Apple Music (Public API)"
        case systemWide = "System Wide (MediaRemote Private API)"
    }
    
    // Set to .systemWide for YouTube Music / Spotify control (requires TrollStore/Jailbreak entitlements on device).
    // Set to .appleMusic for native sandboxed Apple Music control on any stock iPhone.
    static let mediaControlMode: MediaControlMode = .systemWide
    
    // Preferred Map App for external navigation handoff
    enum PreferredMapApp: String, CaseIterable {
        case appleMaps = "Apple Maps"
        case googleMaps = "Google Maps"
        case inApp = "In-App Map"
    }
    
    static var preferredMapApp: PreferredMapApp {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "preferredMapApp"),
                  let pref = PreferredMapApp(rawValue: raw) else {
                return .appleMaps
            }
            return pref
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "preferredMapApp")
        }
    }
}
