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
    static let serviceUUID = CBUUID(string: "592c1017-9c1d-6457-0be7-e7635c65c21b")
    static let displayCharUUID = CBUUID(string: "4fa28b27-6938-48f8-980e-7c7c9acc6c1e")
    
    // Engine Intervals
    static let heartbeatInterval: TimeInterval = 2.0
    static let mediaPollInterval: TimeInterval = 2.5
}
