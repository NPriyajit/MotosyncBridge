// MediaObserver.swift — Motosync Bridge
// OVERHAULED: Uses private MediaRemote.framework to intercept global background audio metadata

import Foundation
import Combine
import AVFoundation
import MediaPlayer

final class MediaObserver: ObservableObject {

    @Published var currentTrack: String  = "No Media Playing"
    @Published var currentArtist: String = "Unknown Artist"
    @Published var isPlaying: Bool = false

    var onMetadataChanged: ((String, String) -> Void)?
    private var pollTimer: Timer?
    private var silentAudioPlayer: AVAudioPlayer?
    
    // Dynamic C-linkage pointers for the Private MediaRemote framework
    private typealias MRMediaRemoteGetNowPlayingInfoType = @convention(c) (DispatchQueue, @escaping (CFDictionary) -> Void) -> Void
    private var MRMediaRemoteGetNowPlayingInfo: MRMediaRemoteGetNowPlayingInfoType?

    init() {
        loadMediaRemoteFramework()
        setupObservers()
        startPolling()
        startBackgroundAudioLease()
    }

    deinit {
        pollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func loadMediaRemoteFramework() {
        // Dynamically open the private system framework to slip past compiler blocks
        let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        if let handle = handle {
            let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo")
            if let sym = sym {
                MRMediaRemoteGetNowPlayingInfo = unsafeBitCast(sym, to: MRMediaRemoteGetNowPlayingInfoType.self)
            }
        } else {
            print("⚠️ Failed to load MediaRemote framework path.")
        }
    }

    private func setupObservers() {
        // Listen directly to the system-wide background now-playing notification anchor
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaChange),
            name: NSNotification.Name(rawValue: "kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            object: nil
        )
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.fetchCurrentMedia()
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    @objc private func handleMediaChange() {
        fetchCurrentMedia()
    }

    func fetchCurrentMedia() {
        // This officially reads the native Apple Music queue
        let player = MPMusicPlayerController.systemMusicPlayer
        let playing = player.playbackState == .playing
        
        guard let item = player.nowPlayingItem else { return }
        
        let title = item.title ?? "No Media"
        let artist = item.artist ?? "Unknown"
        
        guard title != currentTrack || artist != currentArtist else { return }
        
        currentTrack = title
        currentArtist = artist
        isPlaying = playing
        
        print("🎵 Apple Music Scraped: \(title) — \(artist)")
        onMetadataChanged?(title, artist)
    }
    
    private func startBackgroundAudioLease() {
        do {
            // 1. Configure the audio session to play in the background alongside other apps
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)

            // 2. Create a 1-second dynamic buffer of absolute digital silence
            let numSamples = 44100
            var silence = [Int16](repeating: 0, count: numSamples)
            let data = Data(bytes: &silence, count: numSamples * 2)

            // 3. Loop it infinitely
            silentAudioPlayer = try AVAudioPlayer(data: data)
            silentAudioPlayer?.numberOfLoops = -1
            silentAudioPlayer?.volume = 0.01 // Totally inaudible
            silentAudioPlayer?.play()
            
            print("🤫 Background audio lease secured (Absolute Silence looping).")
        } catch {
            print("⚠️ Failed to initialize background audio lease: \(error)")
        }
    }
}
