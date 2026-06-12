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
        requestMediaLibraryAuthorization()
        loadMediaRemoteFramework()
        setupObservers()
        startPolling()
        startBackgroundAudioLease()
    }

    private func requestMediaLibraryAuthorization() {
        MPMediaLibrary.requestAuthorization { status in
            switch status {
            case .authorized:
                print("✅ Media Library access granted.")
            case .denied:
                print("⚠️ Media Library access denied.")
            case .restricted:
                print("⚠️ Media Library access restricted.")
            case .notDetermined:
                print("⚠️ Media Library access not determined.")
            @unknown default:
                break
            }
        }
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
        if let MRMediaRemoteGetNowPlayingInfo = MRMediaRemoteGetNowPlayingInfo {
            MRMediaRemoteGetNowPlayingInfo(DispatchQueue.main) { [weak self] dict in
                guard let self = self else { return }
                let info = dict as? [String: Any] ?? [:]
                
                let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? "No Media Playing"
                let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? "Unknown Artist"
                
                // Read playback rate (typically Double/Float). If > 0, media is playing.
                let playbackRate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0.0
                let playing = playbackRate > 0.0
                
                if title != self.currentTrack || artist != self.currentArtist || playing != self.isPlaying {
                    self.currentTrack = title
                    self.currentArtist = artist
                    self.isPlaying = playing
                    
                    print("🎵 MediaRemote Intercepted: \(title) — \(artist) (isPlaying: \(playing))")
                    self.onMetadataChanged?(title, artist)
                }
            }
        } else {
            // Apple Music Fallback
            let player = MPMusicPlayerController.systemMusicPlayer
            let playing = player.playbackState == .playing
            guard let item = player.nowPlayingItem else { return }
            
            let title = item.title ?? "No Media"
            let artist = item.artist ?? "Unknown"
            
            guard title != currentTrack || artist != currentArtist || playing != isPlaying else { return }
            
            currentTrack = title
            currentArtist = artist
            isPlaying = playing
            
            print("🎵 Apple Music Fallback: \(title) — \(artist)")
            onMetadataChanged?(title, artist)
        }
    }
    
    private func createSilentWAVData() -> Data {
        let sampleRate = 44100
        let seconds = 1
        let numSamples = sampleRate * seconds
        let subChunk2Size = numSamples * 2 // 16-bit mono = 2 bytes per sample
        let chunkSize = 36 + subChunk2Size
        
        var header = Data()
        
        // RIFF header
        header.append(contentsOf: "RIFF".utf8)
        var tempChunkSize = UInt32(chunkSize)
        header.append(Data(bytes: &tempChunkSize, count: 4))
        header.append(contentsOf: "WAVE".utf8)
        
        // fmt subchunk
        header.append(contentsOf: "fmt ".utf8)
        var subchunk1Size: UInt32 = 16
        header.append(Data(bytes: &subchunk1Size, count: 4))
        var audioFormat: UInt16 = 1 // PCM
        header.append(Data(bytes: &audioFormat, count: 2))
        var numChannels: UInt16 = 1 // Mono
        header.append(Data(bytes: &numChannels, count: 2))
        var tempSampleRate = UInt32(sampleRate)
        header.append(Data(bytes: &tempSampleRate, count: 4))
        var byteRate = UInt32(sampleRate * 2)
        header.append(Data(bytes: &byteRate, count: 4))
        var blockAlign: UInt16 = 2
        header.append(Data(bytes: &blockAlign, count: 2))
        var bitsPerSample: UInt16 = 16
        header.append(Data(bytes: &bitsPerSample, count: 2))
        
        // data subchunk
        header.append(contentsOf: "data".utf8)
        var tempSubChunk2Size = UInt32(subChunk2Size)
        header.append(Data(bytes: &tempSubChunk2Size, count: 4))
        
        // Generate silence (PCM samples = 0)
        var silence = [Int16](repeating: 0, count: numSamples)
        header.append(Data(bytes: &silence, count: subChunk2Size))
        
        return header
    }

    private func startBackgroundAudioLease() {
        do {
            // 1. Configure the audio session to play in the background alongside other apps
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)

            // 2. Generate silent WAV data in-memory
            let data = createSilentWAVData()

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
