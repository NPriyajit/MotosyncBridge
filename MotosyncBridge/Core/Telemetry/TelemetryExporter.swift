//
//  TelemetryExporter.swift
//  MotosyncBridge
//

import Foundation

struct TelemetryExporter {
    static func generateGPX(for session: RideSession) -> URL? {
        let formatter = ISO8601DateFormatter()
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="MotosyncBridge" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>Motosync Telemetry Ride</name>
            <time>\(formatter.string(from: session.startTime))</time>
          </metadata>
        """
        
        // Add anomalies as waypoints (wpt)
        for anomaly in session.anomalies {
            xml += """
              <wpt lat="\(anomaly.latitude)" lon="\(anomaly.longitude)">
                <name>Road Anomaly</name>
                <desc>Magnitude: \(String(format: "%.2fg", anomaly.magnitude))</desc>
                <time>\(formatter.string(from: anomaly.timestamp))</time>
              </wpt>
            """
        }
        
        // Add track points
        xml += """
          <trk>
            <name>Ride Log - \(formatter.string(from: session.startTime))</name>
            <trkseg>
        """
        
        for loc in session.locations {
            xml += """
                  <trkpt lat="\(loc.latitude)" lon="\(loc.longitude)">
                    <ele>\(loc.altitude)</ele>
                    <time>\(formatter.string(from: loc.timestamp))</time>
                  </trkpt>
            """
        }
        
        xml += """
            </trkseg>
          </trk>
        </gpx>
        """
        
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "ride_\(Int(session.startTime.timeIntervalSince1970)).gpx"
        let fileURL = tempDir.appendingPathComponent(filename)
        
        do {
            try xml.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            print("❌ Failed to write GPX: \(error.localizedDescription)")
            return nil
        }
    }
    
    static func generateJSON(for session: RideSession) -> URL? {
        struct SessionExport: Codable {
            let id: UUID
            let startTime: Date
            let endTime: Date?
            let phonePlacement: String
            let smoothnessScore: Int
            let anomalies: [AnomalyExport]
            let locations: [LocationExport]
        }
        struct AnomalyExport: Codable {
            let timestamp: Date
            let latitude: Double
            let longitude: Double
            let magnitude: Double
        }
        struct LocationExport: Codable {
            let timestamp: Date
            let latitude: Double
            let longitude: Double
            let speed: Double
            let altitude: Double
        }
        
        let export = SessionExport(
            id: session.id,
            startTime: session.startTime,
            endTime: session.endTime,
            phonePlacement: session.phonePlacement,
            smoothnessScore: session.smoothnessScore,
            anomalies: session.anomalies.map { AnomalyExport(timestamp: $0.timestamp, latitude: $0.latitude, longitude: $0.longitude, magnitude: $0.magnitude) },
            locations: session.locations.map { LocationExport(timestamp: $0.timestamp, latitude: $0.latitude, longitude: $0.longitude, speed: $0.speed, altitude: $0.altitude) }
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        
        do {
            let data = try encoder.encode(export)
            let tempDir = FileManager.default.temporaryDirectory
            let filename = "ride_\(Int(session.startTime.timeIntervalSince1970)).json"
            let fileURL = tempDir.appendingPathComponent(filename)
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            print("❌ Failed to write JSON: \(error.localizedDescription)")
            return nil
        }
    }
}
