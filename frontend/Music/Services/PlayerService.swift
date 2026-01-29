//
//  PlayerService.swift
//  Music
//

import Foundation
import AVFoundation
import MediaPlayer
#if os(macOS)
import AppKit
#endif

enum RepeatMode {
    case off
    case all
    case one
}

@MainActor
@Observable
class PlayerService {
    var currentTrack: Track?
    var currentAlbum: Album?
    var queue: [Track] = []
    var currentIndex: Int = 0

    var isPlaying: Bool = false
    var isShuffled: Bool = false
    var repeatMode: RepeatMode = .off

    var cacheService: CacheService?
    private let shuffleService = ShuffleService()

    // Session tracking for smart shuffle
    private var sessionPlayedKeys: Set<String> = []
    private var recentArtists: [String] = []
    private var recentAlbums: [String] = []
    private let recencyWindowSize = 5

    // Ordered play history for the session (most recent at end)
    private(set) var playHistory: [Track] = []
    private var playHistoryIndex: Int = -1  // Current position in history (-1 = at end)

    // Streaming mode
    var streamingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "streamingModeEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "streamingModeEnabled") }
    }
    var isOnline: Bool = true
    private var preCacheTask: Task<Void, Never>?

    // AVPlayer integration
    private var player: AVPlayer?
    private var hasRecordedPlay: Bool = false
    private var timeObserver: Any?
    private var itemObserver: NSKeyValueObservation?
    private var playbackEndObserver: Any?
    private var remoteCommandCenterConfigured = false

    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0

    var hasTrack: Bool {
        currentTrack != nil
    }

    /// Last 10 played tracks (most recent first)
    var previousTracks: [Track] {
        Array(playHistory.suffix(10).reversed())
    }

    /// Next 10 tracks in queue (empty if shuffle mode since next is dynamic)
    var upNextTracks: [Track] {
        guard !isShuffled else { return [] }
        guard currentIndex + 1 < queue.count else { return [] }
        let remaining = Array(queue[(currentIndex + 1)...])
        return Array(remaining.prefix(10))
    }

    var currentArtworkUrl: String? {
        currentAlbum?.imageUrl ?? currentTrack?.embeddedArtworkUrl
    }

    var currentPlaybackURL: URL? {
        guard let track = currentTrack else { return nil }

        // Prefer cached URL
        if let cacheService = cacheService,
           let localURL = cacheService.localURL(for: track) {
            return localURL
        }

        // Fall back to remote if streaming enabled and online
        if streamingEnabled && isOnline,
           let urlString = track.url,
           let remoteURL = URL(string: urlString) {
            return remoteURL
        }

        return nil
    }

    var currentLocalArtworkURL: URL? {
        guard let urlString = currentArtworkUrl,
              let cacheService = cacheService else { return nil }
        return cacheService.localArtworkURL(for: urlString)
    }

    var formattedCurrentTime: String {
        formatTime(currentTime)
    }

    var formattedDuration: String {
        formatTime(duration)
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    // MARK: - Playability Check

    func isTrackPlayable(_ track: Track) -> Bool {
        // Always playable if cached
        if cacheService?.isTrackCached(track) ?? false {
            return true
        }
        // Playable via streaming if enabled and online
        return streamingEnabled && isOnline
    }

    // MARK: - Playback Control

    func play(track: Track, album: Album? = nil, queue: [Track]? = nil) {
        // Only play if cached
        guard isTrackPlayable(track) else { return }

        currentTrack = track
        currentAlbum = album

        if let queue = queue {
            self.queue = queue
            currentIndex = queue.firstIndex(where: { $0.id == track.id }) ?? 0
        } else if let album = album {
            self.queue = album.tracks
            currentIndex = album.tracks.firstIndex(where: { $0.id == track.id }) ?? 0
        } else {
            self.queue = [track]
            currentIndex = 0
        }

        // Track session play
        updateSessionTracking(for: track)

        setupPlayer()
    }

    /// Start playback in shuffle mode with a weighted random starting track
    func shufflePlay(queue: [Track], album: Album? = nil) {
        guard !queue.isEmpty else { return }

        self.queue = queue
        self.currentAlbum = album

        // Enable shuffle mode
        if !isShuffled {
            isShuffled = true
        }

        // Use weighted shuffle to select starting track with context
        let context = buildShuffleContext()
        if let startTrack = shuffleService.selectNextTrack(
            from: queue,
            excluding: nil,
            context: context,
            playableFilter: { [weak self] track in
                self?.isTrackPlayable(track) ?? false
            }
        ) {
            currentTrack = startTrack
            currentIndex = queue.firstIndex(where: { $0.id == startTrack.id }) ?? 0
            updateSessionTracking(for: startTrack)
            setupPlayer()
        }
    }

    private func setupPlayer() {
        // Clean up previous player
        removeTimeObserver()
        player?.pause()

        // Reset play tracking for new track
        hasRecordedPlay = false

        guard let url = currentPlaybackURL else {
            isPlaying = false
            return
        }

        // Configure audio session for background playback
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        // Setup remote command center (once)
        if !remoteCommandCenterConfigured {
            setupRemoteCommandCenter()
            remoteCommandCenterConfigured = true
        }

        let playerItem = AVPlayerItem(url: url)

        // Optimize for streaming: reduce buffer requirements for faster startup
        let isStreaming = cacheService?.isTrackCached(currentTrack!) == false
        if isStreaming {
            playerItem.preferredForwardBufferDuration = 5 // Only buffer 5 seconds ahead
        }

        player = AVPlayer(playerItem: playerItem)

        // For streaming, start playing immediately without waiting for full buffer
        if isStreaming {
            player?.automaticallyWaitsToMinimizeStalling = false
        }

        // Observe when track ends (store reference for cleanup)
        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleTrackEnded()
            }
        }

        // Get duration when ready
        itemObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                if item.status == .readyToPlay {
                    self?.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
                    self?.updateNowPlayingInfo()
                }
            }
        }

        // Add time observer for progress updates
        addTimeObserver()

        player?.play()
        isPlaying = true
        updateNowPlayingInfo()

        // Pre-cache upcoming tracks when streaming
        triggerPreCache()
    }

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self = self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                self.updateNowPlayingTime()

                // Record play event when track reaches 50%
                if !self.hasRecordedPlay && self.duration > 0 && self.currentTime > self.duration * 0.5 {
                    self.hasRecordedPlay = true
                    self.recordPlayEvent()
                }
            }
        }
    }

    private func removeTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        itemObserver?.invalidate()
        itemObserver = nil

        // Remove NotificationCenter observer to prevent memory leak
        if let observer = playbackEndObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackEndObserver = nil
        }
    }

    func togglePlayPause() {
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
        isPlaying.toggle()
        updateNowPlayingInfo()
    }

    func seek(to progress: Double) {
        guard duration > 0 else { return }
        let targetTime = CMTime(seconds: progress * duration, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: targetTime)
        currentTime = progress * duration
        updateNowPlayingTime()
    }

    func seekToTime(_ time: TimeInterval) {
        guard duration > 0 else { return }
        let targetTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: targetTime)
        currentTime = time
        updateNowPlayingTime()
    }

    func next() {
        guard !queue.isEmpty else { return }

        // Record skip if played less than 3 seconds
        if currentTime > 0 && currentTime < 3 {
            recordSkipEvent()
        }

        // If we're navigating back through history, go forward first
        if playHistoryIndex >= 0 && playHistoryIndex < playHistory.count - 1 {
            playHistoryIndex += 1
            let nextTrack = playHistory[playHistoryIndex]

            // Update queue index if track is in current queue
            if let queueIndex = queue.firstIndex(where: { $0.id == nextTrack.id }) {
                currentIndex = queueIndex
            }

            currentTrack = nextTrack
            updateSessionTracking(for: nextTrack, fromHistoryNavigation: true)
            setupPlayer()
            return
        }

        if isShuffled {
            // Use weighted shuffle selection with context
            let context = buildShuffleContext()
            if let nextTrack = shuffleService.selectNextTrack(
                from: queue,
                excluding: currentTrack,
                context: context,
                playableFilter: { [weak self] track in
                    self?.isTrackPlayable(track) ?? false
                }
            ) {
                if let index = queue.firstIndex(where: { $0.id == nextTrack.id }) {
                    currentIndex = index
                }
            } else {
                return // No playable tracks
            }
        } else {
            // Find next playable track sequentially
            var nextIndex = (currentIndex + 1) % queue.count
            var attempts = 0
            while !isTrackPlayable(queue[nextIndex]) && attempts < queue.count {
                nextIndex = (nextIndex + 1) % queue.count
                attempts += 1
            }
            if attempts >= queue.count { return } // No playable tracks
            currentIndex = nextIndex
        }

        currentTrack = queue[currentIndex]
        updateSessionTracking(for: currentTrack!)
        setupPlayer()
    }

    func previous() {
        guard !queue.isEmpty else { return }

        // If we're more than 3 seconds in, restart current track
        if currentTime > 3 {
            seek(to: 0)
            return
        }

        // Record skip if played less than 3 seconds
        if currentTime > 0 && currentTime < 3 {
            recordSkipEvent()
        }

        // Try to go back in play history first
        if playHistoryIndex > 0 {
            playHistoryIndex -= 1
            let previousTrack = playHistory[playHistoryIndex]

            // Update queue index if track is in current queue
            if let queueIndex = queue.firstIndex(where: { $0.id == previousTrack.id }) {
                currentIndex = queueIndex
            }

            currentTrack = previousTrack
            updateSessionTracking(for: previousTrack, fromHistoryNavigation: true)
            setupPlayer()
            return
        }

        // Fall back to sequential navigation if no history
        var prevIndex = currentIndex > 0 ? currentIndex - 1 : queue.count - 1
        var attempts = 0
        while !isTrackPlayable(queue[prevIndex]) && attempts < queue.count {
            prevIndex = prevIndex > 0 ? prevIndex - 1 : queue.count - 1
            attempts += 1
        }
        if attempts >= queue.count { return } // No playable tracks
        currentIndex = prevIndex

        currentTrack = queue[currentIndex]
        updateSessionTracking(for: currentTrack!)
        setupPlayer()
    }

    private func handleTrackEnded() {
        switch repeatMode {
        case .one:
            hasRecordedPlay = false
            seek(to: 0)
            player?.play()
        case .all:
            next()
        case .off:
            if currentIndex < queue.count - 1 {
                next()
            } else {
                isPlaying = false
                currentTime = 0
                updateNowPlayingInfo()
            }
        }
    }

    func toggleShuffle() {
        isShuffled.toggle()
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off:
            repeatMode = .all
        case .all:
            repeatMode = .one
        case .one:
            repeatMode = .off
        }
    }

    // MARK: - Now Playing Info Center

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if !self.isPlaying {
                    self.togglePlayPause()
                }
            }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.isPlaying {
                    self.togglePlayPause()
                }
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.togglePlayPause()
            }
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.next()
            }
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.previous()
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                self?.seekToTime(event.positionTime)
            }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]

        if let artist = track.artist {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album = track.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }

        // Load artwork from cache
        if let artworkURL = currentLocalArtworkURL,
           let imageData = try? Data(contentsOf: artworkURL) {
            #if os(iOS)
            if let image = UIImage(data: imageData) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                info[MPMediaItemPropertyArtwork] = artwork
            }
            #else
            if let image = NSImage(data: imageData) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                info[MPMediaItemPropertyArtwork] = artwork
            }
            #endif
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingTime() {
        // Only update time-related properties (more efficient than full update)
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Helpers

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite && time >= 0 else { return "0:00" }
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Play/Skip Tracking (Core Data + CloudKit)

    private func recordPlayEvent() {
        guard let track = currentTrack else { return }
        AnalyticsStore.shared.recordPlay(track: track, duration: currentTime, trackDuration: duration)
    }

    private func recordSkipEvent() {
        guard let track = currentTrack else { return }
        AnalyticsStore.shared.recordSkip(track: track, playedDuration: currentTime)
    }

    // MARK: - Session Tracking for Smart Shuffle

    private func updateSessionTracking(for track: Track, fromHistoryNavigation: Bool = false) {
        // Add to session played set
        sessionPlayedKeys.insert(track.s3Key)

        // Update play history (ordered list of played tracks)
        if !fromHistoryNavigation {
            // If we're not at the end of history, truncate forward history
            if playHistoryIndex >= 0 && playHistoryIndex < playHistory.count - 1 {
                playHistory = Array(playHistory.prefix(playHistoryIndex + 1))
            }
            playHistory.append(track)
            playHistoryIndex = playHistory.count - 1
        }

        // Update recent artists (maintain window size)
        if let artist = track.artist {
            // Remove if already present to avoid duplicates
            recentArtists.removeAll { $0 == artist }
            // Insert at beginning (most recent)
            recentArtists.insert(artist, at: 0)
            // Trim to window size
            if recentArtists.count > recencyWindowSize {
                recentArtists = Array(recentArtists.prefix(recencyWindowSize))
            }
        }

        // Update recent albums (maintain window size)
        if let album = track.album {
            // Remove if already present to avoid duplicates
            recentAlbums.removeAll { $0 == album }
            // Insert at beginning (most recent)
            recentAlbums.insert(album, at: 0)
            // Trim to window size
            if recentAlbums.count > recencyWindowSize {
                recentAlbums = Array(recentAlbums.prefix(recencyWindowSize))
            }
        }
    }

    private func buildShuffleContext() -> ShuffleContext {
        var context = ShuffleContext()
        context.recentArtists = recentArtists
        context.recentAlbums = recentAlbums
        context.sessionPlayed = sessionPlayedKeys

        // Get genre/mood from current track for continuity
        if let track = currentTrack {
            context.lastPlayedGenre = Genre.normalize(track.genre)
            context.lastPlayedMood = track.mood
        }

        return context
    }

    /// Reset session tracking (call when queue changes or app restarts)
    func resetSessionTracking() {
        sessionPlayedKeys.removeAll()
        recentArtists.removeAll()
        recentAlbums.removeAll()
        playHistory.removeAll()
        playHistoryIndex = -1
    }

    /// Set up preview data for SwiftUI previews
    func setupPreviewData(queue: [Track], currentIndex: Int, playHistory: [Track]) {
        self.queue = queue
        self.currentIndex = currentIndex
        self.currentTrack = queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
        self.playHistory = playHistory
        self.playHistoryIndex = playHistory.count - 1
    }

    // MARK: - Pre-Caching

    private func triggerPreCache() {
        preCacheTask?.cancel()

        guard streamingEnabled && isOnline,
              let cacheService = cacheService else { return }

        preCacheTask = Task {
            await preCacheUpcomingTracks(cacheService: cacheService)
        }
    }

    private func preCacheUpcomingTracks(cacheService: CacheService) async {
        let preCacheCount = 3
        var tracksToCache: [Track] = []
        var index = currentIndex + 1

        // Collect next N uncached tracks
        while tracksToCache.count < preCacheCount && index < queue.count {
            let track = queue[index]
            if !cacheService.isTrackCached(track) {
                tracksToCache.append(track)
            }
            index += 1
        }

        // Download each
        for track in tracksToCache {
            guard !Task.isCancelled else { break }
            await cacheService.downloadSingleTrack(track)
        }
    }

    nonisolated func cleanup() {
        // Called when the service is being deallocated
        // Player will be cleaned up automatically
    }
}
