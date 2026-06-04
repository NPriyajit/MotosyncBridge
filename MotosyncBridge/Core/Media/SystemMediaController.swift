//
//  SystemMediaController.swift
//  MotosyncBridge
//
//  Created by Priyajit Nayak on 04/06/26.
//

import Foundation

final class SystemMediaController {
    static let shared = SystemMediaController()
    
    // Private API C-function pointer
    private typealias MRMediaRemoteSendCommandType = @convention(c) (UInt32, Any?) -> Bool
    private var sendCommand: MRMediaRemoteSendCommandType?

    // MediaRemote Command Constants
    private let MRCommandTogglePlayPause: UInt32 = 2
    private let MRCommandNextTrack: UInt32 = 4
    private let MRCommandPreviousTrack: UInt32 = 5

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        if let handle = handle, let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCommand = unsafeBitCast(sym, to: MRMediaRemoteSendCommandType.self)
        } else {
            print("⚠️ Failed to load MediaRemote command hook.")
        }
    }

    func togglePlayPause() {
        _ = sendCommand?(MRCommandTogglePlayPause, nil)
        print("⏯️ System Play/Pause Triggered")
    }

    func nextTrack() {
        _ = sendCommand?(MRCommandNextTrack, nil)
        print("⏭️ System Next Track Triggered")
    }

    func previousTrack() {
        _ = sendCommand?(MRCommandPreviousTrack, nil)
        print("⏮️ System Previous Track Triggered")
    }
}
