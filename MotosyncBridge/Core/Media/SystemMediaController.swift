//
//  SystemMediaController.swift
//  MotosyncBridge
//
//  Created by Priyajit Nayak on 04/06/26.
//

import Foundation
import MediaPlayer

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
        if AppConfiguration.mediaControlMode == .systemWide {
            if let sendCommand = sendCommand {
                let success = sendCommand(MRCommandTogglePlayPause, nil)
                print("⏯️ MediaRemote Play/Pause Triggered (success: \(success))")
            } else {
                print("⚠️ MediaRemote not loaded or unavailable. Cannot send command.")
            }
        } else {
            let player = MPMusicPlayerController.systemMusicPlayer
            if player.playbackState == .playing {
                player.pause()
                print("⏯️ Apple Music Paused")
            } else {
                player.play()
                print("⏯️ Apple Music Playing")
            }
        }
    }

    func nextTrack() {
        if AppConfiguration.mediaControlMode == .systemWide {
            if let sendCommand = sendCommand {
                let success = sendCommand(MRCommandNextTrack, nil)
                print("⏭️ MediaRemote Next Track Triggered (success: \(success))")
            } else {
                print("⚠️ MediaRemote not loaded or unavailable. Cannot send command.")
            }
        } else {
            MPMusicPlayerController.systemMusicPlayer.skipToNextItem()
            print("⏭️ Apple Music Skip to Next Item")
        }
    }

    func previousTrack() {
        if AppConfiguration.mediaControlMode == .systemWide {
            if let sendCommand = sendCommand {
                let success = sendCommand(MRCommandPreviousTrack, nil)
                print("⏮️ MediaRemote Previous Track Triggered (success: \(success))")
            } else {
                print("⚠️ MediaRemote not loaded or unavailable. Cannot send command.")
            }
        } else {
            MPMusicPlayerController.systemMusicPlayer.skipToPreviousItem()
            print("⏮️ Apple Music Skip to Previous Item")
        }
    }
}
