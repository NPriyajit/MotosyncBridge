//
//  TelemetryModels.swift
//  MotosyncBridge
//

import Foundation
import SwiftData

@Model
final class RideSession {
    @Attribute(.unique) var id: UUID
    var startTime: Date
    var endTime: Date?
    var phonePlacement: String
    var smoothnessScore: Int
    
    @Relationship(deleteRule: .cascade, inverse: \RideLocation.session)
    var locations: [RideLocation] = []
    
    @Relationship(deleteRule: .cascade, inverse: \RideAnomaly.session)
    var anomalies: [RideAnomaly] = []
    
    init(id: UUID = UUID(), startTime: Date = Date(), phonePlacement: String, smoothnessScore: Int = 100) {
        self.id = id
        self.startTime = startTime
        self.phonePlacement = phonePlacement
        self.smoothnessScore = smoothnessScore
    }
}

@Model
final class RideLocation {
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var speed: Double
    var altitude: Double
    
    var session: RideSession?
    
    init(timestamp: Date, latitude: Double, longitude: Double, speed: Double, altitude: Double, session: RideSession? = nil) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.speed = speed
        self.altitude = altitude
        self.session = session
    }
}

@Model
final class RideAnomaly {
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var magnitude: Double
    
    var session: RideSession?
    
    init(timestamp: Date, latitude: Double, longitude: Double, magnitude: Double, session: RideSession? = nil) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.magnitude = magnitude
        self.session = session
    }
}
