// MediaObserver.swift — Motosync Bridge
// OVERHAULED: Uses private MediaRemote.framework to intercept global background audio metadata

import Foundation
import Combine
import AVFoundation
import MediaPlayer

final class MediaObserver: ObservableObject {

    static let shared = MediaObserver()

    @Published var currentTrack: String  = "No Media Playing"
    @Published var currentArtist: String = "Unknown Artist"
    @Published var isPlaying: Bool = false
    @Published var nowPlayingApp: String = ""

    var onMetadataChanged: ((String, String) -> Void)?
    private var pollTimer: Timer?
    private var silentAudioPlayer: AVAudioPlayer?
    
    // Dynamic C-linkage pointers for the Private MediaRemote framework
    private typealias MRMediaRemoteGetNowPlayingInfoType = @convention(c) (DispatchQueue, @escaping (CFDictionary) -> Void) -> Void
    private var MRMediaRemoteGetNowPlayingInfo: MRMediaRemoteGetNowPlayingInfoType?
    
    private typealias MRGetNowPlayingAppBundleIDType = @convention(c) (DispatchQueue, @escaping (CFString) -> Void) -> Void
    private var MRMediaRemoteGetNowPlayingApplicationBundleIdentifier: MRGetNowPlayingAppBundleIDType?

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
            if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
                MRMediaRemoteGetNowPlayingInfo = unsafeBitCast(sym, to: MRMediaRemoteGetNowPlayingInfoType.self)
            }
            if let sym2 = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationBundleIdentifier") {
                MRMediaRemoteGetNowPlayingApplicationBundleIdentifier = unsafeBitCast(sym2, to: MRGetNowPlayingAppBundleIDType.self)
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
        
        // Listen to secondary audio hint notifications as a sandbox-safe fallback
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSecondaryAudioHint),
            name: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: nil
        )
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.fetchCurrentMedia()
            self?.detectNowPlayingApp()
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    @objc private func handleMediaChange() {
        fetchCurrentMedia()
    }

    func fetchCurrentMedia() {
        // AudioSession can always tell us if OTHER apps are playing audio (sandbox-safe).
        let sessionDetectsAudio = AVAudioSession.sharedInstance().isOtherAudioPlaying
        
        if let MRMediaRemoteGetNowPlayingInfo = MRMediaRemoteGetNowPlayingInfo {
            MRMediaRemoteGetNowPlayingInfo(DispatchQueue.main) { [weak self] dict in
                guard let self = self else { return }
                let info = dict as? [String: Any] ?? [:]
                
                // Try to pull real metadata from MediaRemote
                let mrTitle = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String
                let mrArtist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String
                let playbackRate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0.0
                let mrPlaying = playbackRate > 0.0
                
                // Did MediaRemote actually return real data? (not just empty dict from sandbox denial)
                let mrHasRealData = mrTitle != nil || mrArtist != nil
                
                let finalTitle: String
                let finalArtist: String
                let finalPlaying: Bool
                
                if mrHasRealData {
                    // MediaRemote is functional (TrollStore / entitlements present)
                    finalTitle = mrTitle ?? "No Media Playing"
                    finalArtist = mrArtist ?? "Unknown Artist"
                    finalPlaying = mrPlaying
                } else if sessionDetectsAudio {
                    // MediaRemote is sandboxed, but AudioSession confirms audio is playing
                    finalTitle = "Now Playing"
                    finalArtist = self.nowPlayingApp.isEmpty ? "Music" : self.nowPlayingApp
                    finalPlaying = true
                } else {
                    // Nothing is playing
                    finalTitle = "No Media Playing"
                    finalArtist = "Unknown Artist"
                    finalPlaying = false
                }
                
                if finalTitle != self.currentTrack || finalArtist != self.currentArtist || finalPlaying != self.isPlaying {
                    self.currentTrack = finalTitle
                    self.currentArtist = finalArtist
                    self.isPlaying = finalPlaying
                    
                    print("🎵 Media State: \(finalTitle) — \(finalArtist) (isPlaying: \(finalPlaying), source: \(mrHasRealData ? "MediaRemote" : "AudioSession"))")
                    self.onMetadataChanged?(finalTitle, finalArtist)
                }
            }
        } else {
            // Apple Music Fallback (MediaRemote framework failed to load entirely)
            let player = MPMusicPlayerController.systemMusicPlayer
            let playing = player.playbackState == .playing
            guard let item = player.nowPlayingItem else {
                // No Apple Music item — check AudioSession as last resort
                if sessionDetectsAudio != isPlaying {
                    isPlaying = sessionDetectsAudio
                    if sessionDetectsAudio {
                        currentTrack = "Now Playing"
                        currentArtist = "Background Audio"
                    }
                    onMetadataChanged?(currentTrack, currentArtist)
                }
                return
            }
            
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
    
    @objc private func handleSecondaryAudioHint(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt,
              let type = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: typeValue) else {
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let isPlayingOther = type == .begin
            
            if isPlayingOther != self.isPlaying {
                self.isPlaying = isPlayingOther
                if isPlayingOther && self.currentTrack == "No Media Playing" {
                    self.currentTrack = "Now Playing"
                    self.currentArtist = self.nowPlayingApp.isEmpty ? "Music" : self.nowPlayingApp
                } else if !isPlayingOther && self.currentTrack == "Now Playing" {
                    self.currentTrack = "No Media Playing"
                    self.currentArtist = "Unknown Artist"
                }
                print("🎵 AudioSession Hint: isPlaying updated to \(isPlayingOther)")
                self.onMetadataChanged?(self.currentTrack, self.currentArtist)
            }
        }
    }
    
    // MARK: - Now Playing App Detection
    
    private func detectNowPlayingApp() {
        guard let getAppBundleID = MRMediaRemoteGetNowPlayingApplicationBundleIdentifier else { return }
        getAppBundleID(DispatchQueue.main) { [weak self] bundleID in
            guard let self = self else { return }
            let id = bundleID as String
            guard !id.isEmpty else { return }
            let appName = self.friendlyAppName(bundleID: id)
            if appName != self.nowPlayingApp {
                self.nowPlayingApp = appName
                // If we're currently showing generic metadata, update the artist to the app name
                if self.currentTrack == "Now Playing" {
                    self.currentArtist = appName
                    self.onMetadataChanged?(self.currentTrack, self.currentArtist)
                }
                print("🎵 Detected now-playing app: \(appName) (\(id))")
            }
        }
    }
    
    private func friendlyAppName(bundleID: String) -> String {
        let id = bundleID.lowercased()
        if id.contains("youtubemusic") { return "YouTube Music" }
        if id.contains("youtube") { return "YouTube" }
        if id.contains("spotify") { return "Spotify" }
        if id.contains("apple.music") || id.contains("musicd") { return "Apple Music" }
        if id.contains("soundcloud") { return "SoundCloud" }
        if id.contains("amazon") && id.contains("music") { return "Amazon Music" }
        if id.contains("gaana") { return "Gaana" }
        if id.contains("jiosaavn") || id.contains("saavn") { return "JioSaavn" }
        if id.contains("wynk") { return "Wynk Music" }
        if id.contains("hungama") { return "Hungama" }
        if id.contains("pandora") { return "Pandora" }
        if id.contains("tidal") { return "Tidal" }
        if id.contains("deezer") { return "Deezer" }
        // Fallback: extract the last component and capitalize it
        return bundleID.components(separatedBy: ".").last?.capitalized ?? "Music"
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
