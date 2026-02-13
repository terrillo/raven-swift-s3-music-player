//
//  CacheService.swift
//  Music
//

import Foundation
import SwiftUI
import SwiftData
import CryptoKit

enum DownloadStatus: Equatable {
    case pending
    case downloading(progress: Double)
    case completed
    case failed(error: String)
    case cached
}

@MainActor
@Observable
class CacheService {
    var isDownloading: Bool = false
    var currentProgress: Double = 0
    var currentFileName: String = ""
    var totalFiles: Int = 0
    var completedFiles: Int = 0
    var error: String?
    var isCancelled: Bool = false

    // Per-track download status
    var trackDownloadStatus: [String: DownloadStatus] = [:]

    // Batched cache lookup for performance with large catalogs
    private var cachedTrackKeys: Set<String> = []
    private var cachedArtworkUrls: Set<String> = []

    private var modelContext: ModelContext

    // MARK: - Storage Limit

    /// Maximum cache size in GB (0 = unlimited). Uses UserDefaults directly since @Observable doesn't support @AppStorage.
    var maxCacheSizeGB: Int {
        get { UserDefaults.standard.integer(forKey: "maxCacheSizeGB") }
        set { UserDefaults.standard.set(newValue, forKey: "maxCacheSizeGB") }
    }

    /// Check if storage limit is enabled
    var hasStorageLimit: Bool { maxCacheSizeGB > 0 }

    /// Max cache size in bytes
    var maxCacheSizeBytes: Int64 { Int64(maxCacheSizeGB) * 1_000_000_000 }

    /// Whether artwork should be included in backups (persisted to survive restore)
    var shouldPersistArtwork: Bool { UserDefaults.standard.bool(forKey: "autoImageCachingEnabled") }

    /// Whether tracks should be included in backups (only when no storage limit)
    var shouldPersistTracks: Bool { !hasStorageLimit }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        UserDefaults.standard.register(defaults: ["autoImageCachingEnabled": true, "maxCacheSizeGB": 0, "autoDownloadFavoritesEnabled": true])
        #if os(macOS)
        migrateFromOldCacheLocation()
        #endif
        let infos = loadCachedKeysFromDB()
        validateCachedFilesInBackground(trackInfos: infos.trackInfos, artworkInfos: infos.artworkInfos)
    }

    #if os(macOS)
    /// Migrate cache from old Documents location to new Application Support location
    private func migrateFromOldCacheLocation() {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let oldCacheDir = documentsPath.appendingPathComponent("MusicCache", isDirectory: true)

        // Check if old cache exists
        guard FileManager.default.fileExists(atPath: oldCacheDir.path) else { return }

        // Check if new cache doesn't exist yet (avoid re-migrating)
        let newCacheDir = cacheDirectory
        if FileManager.default.fileExists(atPath: newCacheDir.path) {
            // New location already exists, just delete old one
            print("CacheService: Removing old cache location at \(oldCacheDir.path)")
            try? FileManager.default.removeItem(at: oldCacheDir)
            return
        }

        print("CacheService: Migrating cache from \(oldCacheDir.path) to \(newCacheDir.path)")

        do {
            // Ensure parent directory exists
            try FileManager.default.createDirectory(at: newCacheDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Move the cache directory
            try FileManager.default.moveItem(at: oldCacheDir, to: newCacheDir)
            print("CacheService: Successfully migrated cache to Application Support")
        } catch {
            print("CacheService: Migration failed: \(error). Will re-download cache.")
            // If migration fails, just delete the old location
            try? FileManager.default.removeItem(at: oldCacheDir)
        }
    }
    #endif

    /// Fast path: load all cached keys from SwiftData into memory (no file I/O).
    /// Called synchronously in init() for near-instant startup.
    /// Returns track/artwork info for background validation to avoid a second fetch.
    private func loadCachedKeysFromDB() -> (
        trackInfos: [(s3Key: String, localFileName: String)],
        artworkInfos: [(remoteUrl: String, localFileName: String)]
    ) {
        let trackDescriptor = FetchDescriptor<CachedTrack>()
        let tracks = (try? modelContext.fetch(trackDescriptor)) ?? []
        let trackInfos = tracks.map { (s3Key: $0.s3Key, localFileName: $0.localFileName) }
        cachedTrackKeys = Set(trackInfos.map { $0.s3Key })

        let artworkDescriptor = FetchDescriptor<CachedArtwork>()
        let artwork = (try? modelContext.fetch(artworkDescriptor)) ?? []
        let artworkInfos = artwork.map { (remoteUrl: $0.remoteUrl, localFileName: $0.localFileName) }
        cachedArtworkUrls = Set(artworkInfos.map { $0.remoteUrl })

        print("CacheService: Loaded \(cachedTrackKeys.count) track keys, \(cachedArtworkUrls.count) artwork keys from DB")
        return (trackInfos, artworkInfos)
    }

    /// Deferred path: validate files exist on disk, clean up stale records, update backup flags.
    /// Runs in a background Task so it doesn't block app launch.
    /// Uses pre-fetched infos from loadCachedKeysFromDB to avoid a second SwiftData fetch.
    private func validateCachedFilesInBackground(
        trackInfos: [(s3Key: String, localFileName: String)],
        artworkInfos: [(remoteUrl: String, localFileName: String)]
    ) {
        let tracksDir = tracksDirectory
        let artworkDir = artworkDirectory

        // Ensure directories exist
        try? FileManager.default.createDirectory(at: tracksDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)

        let persistTracks = shouldPersistTracks
        let persistArtwork = shouldPersistArtwork

        Task.detached { [weak self] in
            // Validate track files exist on disk
            var staleTrackS3Keys: Set<String> = []
            var trackFilenames: [String] = []

            for info in trackInfos {
                let localURL = tracksDir.appendingPathComponent(info.localFileName)
                if FileManager.default.fileExists(atPath: localURL.path) {
                    trackFilenames.append(info.localFileName)
                } else {
                    staleTrackS3Keys.insert(info.s3Key)
                }
            }

            // Validate artwork files exist on disk
            var staleArtworkUrls: Set<String> = []
            var artworkFilenames: [String] = []

            for info in artworkInfos {
                let localURL = artworkDir.appendingPathComponent(info.localFileName)
                if FileManager.default.fileExists(atPath: localURL.path) {
                    artworkFilenames.append(info.localFileName)
                } else {
                    staleArtworkUrls.insert(info.remoteUrl)
                }
            }

            // Update backup exclusion flags on all valid files (file I/O in background)
            let excludeTracks = !persistTracks
            for filename in trackFilenames {
                var localURL = tracksDir.appendingPathComponent(filename)
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = excludeTracks
                try? localURL.setResourceValues(resourceValues)
            }

            let excludeArtwork = !persistArtwork
            for filename in artworkFilenames {
                var localURL = artworkDir.appendingPathComponent(filename)
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = excludeArtwork
                try? localURL.setResourceValues(resourceValues)
            }

            if !staleTrackS3Keys.isEmpty {
                print("CacheService: Found \(staleTrackS3Keys.count) stale track records (files missing from disk)")
            }
            if !staleArtworkUrls.isEmpty {
                print("CacheService: Found \(staleArtworkUrls.count) stale artwork records (files missing from disk)")
            }

            // Remove stale keys and clean up DB records on MainActor.
            // Uses subtract (not replace) to preserve keys added by downloads during validation.
            if !staleTrackS3Keys.isEmpty || !staleArtworkUrls.isEmpty {
                await MainActor.run { [weak self] in
                    guard let self else { return }

                    // Remove stale keys (preserves any new keys added during validation)
                    self.cachedTrackKeys.subtract(staleTrackS3Keys)
                    self.cachedArtworkUrls.subtract(staleArtworkUrls)

                    // Clean up stale records from DB
                    if !staleTrackS3Keys.isEmpty {
                        let descriptor = FetchDescriptor<CachedTrack>()
                        if let allTracks = try? self.modelContext.fetch(descriptor) {
                            for track in allTracks where staleTrackS3Keys.contains(track.s3Key) {
                                self.modelContext.delete(track)
                            }
                        }
                    }
                    if !staleArtworkUrls.isEmpty {
                        let descriptor = FetchDescriptor<CachedArtwork>()
                        if let allArtwork = try? self.modelContext.fetch(descriptor) {
                            for art in allArtwork where staleArtworkUrls.contains(art.remoteUrl) {
                                self.modelContext.delete(art)
                            }
                        }
                    }
                    try? self.modelContext.save()
                }
            }

            print("CacheService: Validation complete — removed \(staleTrackS3Keys.count) stale tracks, \(staleArtworkUrls.count) stale artwork")
        }
    }

    /// Full reload (called externally, e.g. from settings changes).
    /// Uses the fast DB path + background validation.
    func loadCachedKeys() {
        let infos = loadCachedKeysFromDB()
        validateCachedFilesInBackground(trackInfos: infos.trackInfos, artworkInfos: infos.artworkInfos)
    }

    // MARK: - Directory Management

    private var cacheDirectory: URL {
        // Use Application Support on macOS (not synced by iCloud, appropriate for cache)
        // Use Documents on iOS (more user-accessible for Files app)
        #if os(macOS)
        guard let appSupportPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MusicCache")
        }
        // Use bundle identifier subdirectory for proper organization
        let bundleId = Bundle.main.bundleIdentifier ?? "com.terrillo.Music"
        return appSupportPath.appendingPathComponent(bundleId, isDirectory: true).appendingPathComponent("MusicCache", isDirectory: true)
        #else
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MusicCache")
        }
        return documentsPath.appendingPathComponent("MusicCache", isDirectory: true)
        #endif
    }

    private var tracksDirectory: URL {
        cacheDirectory.appendingPathComponent("tracks", isDirectory: true)
    }

    private var artworkDirectory: URL {
        cacheDirectory.appendingPathComponent("artwork", isDirectory: true)
    }

    private func ensureDirectoriesExist() throws {
        try FileManager.default.createDirectory(at: tracksDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Hash Utilities

    private func sha256Hash(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Cache Status

    func isTrackCached(_ track: Track) -> Bool {
        // Fast O(1) lookup using in-memory cache
        return cachedTrackKeys.contains(track.s3Key)
    }

    func isArtworkCached(_ urlString: String) -> Bool {
        // Fast O(1) lookup using in-memory cache
        return cachedArtworkUrls.contains(urlString)
    }

    /// Fast artwork URL lookup that skips database query by computing path directly
    /// Uses in-memory cache check + deterministic filename computation
    func localArtworkURLFast(for urlString: String) -> URL? {
        // Fast check: is it in our in-memory cache?
        guard cachedArtworkUrls.contains(urlString) else { return nil }

        // Compute the filename directly (same logic as download)
        guard let url = URL(string: urlString) else { return nil }
        let fileExtension = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        let fileName = "\(sha256Hash(urlString)).\(fileExtension)"
        let localURL = artworkDirectory.appendingPathComponent(fileName)

        // Verify file actually exists (handles edge cases)
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            // File missing - clean up stale in-memory entry
            cachedArtworkUrls.remove(urlString)
            return nil
        }

        return localURL
    }

    /// Observable-friendly method for checking if a track is playable.
    /// Checks the trackDownloadStatus dictionary first (triggers SwiftUI updates),
    /// then falls back to SwiftData check for previously cached tracks.
    func isTrackPlayable(_ track: Track) -> Bool {
        // Check observable status first (triggers view updates when status changes)
        if let status = trackDownloadStatus[track.s3Key] {
            switch status {
            case .completed, .cached:
                return true
            case .pending, .downloading, .failed:
                return false
            }
        }
        // Fall back to SwiftData check for tracks cached in previous sessions
        return isTrackCached(track)
    }

    func localURL(for track: Track) -> URL? {
        // Try fast path first (no DB query)
        if let url = localURLFast(for: track) { return url }

        // Fall back to DB query
        guard cachedTrackKeys.contains(track.s3Key) else { return nil }
        let descriptor = FetchDescriptor<CachedTrack>(
            predicate: #Predicate { $0.s3Key == track.s3Key }
        )
        let results = (try? modelContext.fetch(descriptor)) ?? []
        guard let cached = results.first else { return nil }

        let localURL = tracksDirectory.appendingPathComponent(cached.localFileName)
        guard FileManager.default.fileExists(atPath: localURL.path) else { return nil }
        return localURL
    }

    /// Fast track URL lookup without DB query — mirrors localArtworkURLFast pattern
    func localURLFast(for track: Track) -> URL? {
        guard cachedTrackKeys.contains(track.s3Key) else { return nil }

        // Compute filename deterministically (same logic as downloadTrack)
        guard let urlString = track.url, let url = URL(string: urlString) else { return nil }
        let fileExtension = url.pathExtension.isEmpty ? track.format : url.pathExtension
        let fileName = "\(sha256Hash(track.s3Key)).\(fileExtension)"
        let localURL = tracksDirectory.appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: localURL.path) else {
            cachedTrackKeys.remove(track.s3Key)
            return nil
        }

        return localURL
    }

    func localArtworkURL(for urlString: String) -> URL? {
        let descriptor = FetchDescriptor<CachedArtwork>(
            predicate: #Predicate { $0.remoteUrl == urlString }
        )
        let results = (try? modelContext.fetch(descriptor)) ?? []
        guard let cached = results.first else { return nil }

        let localURL = artworkDirectory.appendingPathComponent(cached.localFileName)
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            // File was deleted (e.g., by iOS storage pressure) - clean up stale record
            modelContext.delete(cached)
            try? modelContext.save()
            cachedArtworkUrls.remove(urlString)
            return nil
        }
        return localURL
    }

    // MARK: - Cache Size

    func getCacheSize() -> Int64 {
        let descriptor = FetchDescriptor<CachedTrack>()
        let tracks = (try? modelContext.fetch(descriptor)) ?? []
        return tracks.reduce(0) { $0 + $1.fileSize }
    }

    func formattedCacheSize() -> String {
        let bytes = getCacheSize()
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    func cachedTrackCount() -> Int {
        let descriptor = FetchDescriptor<CachedTrack>()
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    // MARK: - Storage Limit Enforcement

    /// Enforce storage limit by evicting lowest-priority tracks (least played first)
    func enforceStorageLimit() async {
        // Skip if unlimited
        guard hasStorageLimit else { return }

        var currentSize = getCacheSize()
        let maxSize = maxCacheSizeBytes

        // Skip if under limit
        guard currentSize > maxSize else { return }

        // Fetch all cached tracks
        let descriptor = FetchDescriptor<CachedTrack>()
        guard let cachedTracks = try? modelContext.fetch(descriptor), !cachedTracks.isEmpty else { return }

        // Get play counts for all cached tracks
        let trackKeys = Set(cachedTracks.map { $0.s3Key })
        let playCounts = AnalyticsStore.shared.fetchPlayCounts(for: trackKeys)

        // Sort tracks by priority: play count ascending (lowest first), then cachedAt ascending (oldest first)
        let sortedTracks = cachedTracks.sorted { track1, track2 in
            let count1 = playCounts[track1.s3Key] ?? 0
            let count2 = playCounts[track2.s3Key] ?? 0
            if count1 != count2 {
                return count1 < count2  // Lower play count = evict first
            }
            return track1.cachedAt < track2.cachedAt  // Older = evict first
        }

        // Evict tracks until under limit
        for track in sortedTracks {
            guard currentSize > maxSize else { break }

            let freedBytes = track.fileSize
            await deleteCachedTrack(track)
            currentSize -= freedBytes
        }
    }

    /// Check if there is available space for more downloads
    func hasAvailableSpace() -> Bool {
        guard hasStorageLimit else { return true }
        return getCacheSize() < maxCacheSizeBytes
    }

    // MARK: - Auto-Download Favorites

    private var isAutoDownloading = false

    /// Automatically download favorited tracks that aren't yet cached.
    /// Only runs when streaming mode is enabled and space is available.
    func autoDownloadFavoriteTracks(musicService: MusicService) async {
        let autoDownloadEnabled = UserDefaults.standard.bool(forKey: "autoDownloadFavoritesEnabled")
        guard autoDownloadEnabled else { return }

        let streamingEnabled = UserDefaults.standard.bool(forKey: "streamingModeEnabled")
        guard streamingEnabled else { return }

        guard !isAutoDownloading, !isDownloading else { return }
        guard hasAvailableSpace() else { return }

        isAutoDownloading = true
        defer { isAutoDownloading = false }

        // Find uncached favorite tracks
        let favoriteKeys = FavoritesStore.shared.favoriteTrackKeys
        let trackLookup = musicService.trackByS3Key
        let uncachedFavorites = favoriteKeys.compactMap { key -> Track? in
            guard !cachedTrackKeys.contains(key) else { return nil }
            return trackLookup[key]
        }

        guard !uncachedFavorites.isEmpty else { return }

        print("CacheService: Auto-downloading \(uncachedFavorites.count) favorite tracks")

        // Build artist/album lookup for artwork
        var trackToArtist: [String: Artist] = [:]
        var trackToAlbum: [String: Album] = [:]
        if let catalog = musicService.catalog {
            for artist in catalog.artists {
                for album in artist.albums {
                    for track in album.tracks {
                        trackToArtist[track.s3Key] = artist
                        trackToAlbum[track.s3Key] = album
                    }
                }
            }
        }

        do {
            try ensureDirectoriesExist()
        } catch {
            return
        }

        for track in uncachedFavorites {
            // Yield if bulk download started, or if space ran out
            guard hasAvailableSpace(), !isDownloading else {
                print("CacheService: Auto-download stopped — \(isDownloading ? "bulk download started" : "storage limit reached")")
                break
            }

            let artist = trackToArtist[track.s3Key]
            let album = trackToAlbum[track.s3Key]
            await downloadTrackWithRelatedArtwork(track, artist: artist, album: album)
        }

        await enforceStorageLimit()
        print("CacheService: Auto-download complete")
    }

    /// Delete a single cached track (used for eviction)
    func deleteCachedTrack(_ cachedTrack: CachedTrack) async {
        // Delete the file
        let localURL = tracksDirectory.appendingPathComponent(cachedTrack.localFileName)
        try? FileManager.default.removeItem(at: localURL)

        // Remove from in-memory cache
        cachedTrackKeys.remove(cachedTrack.s3Key)

        // Remove download status
        trackDownloadStatus.removeValue(forKey: cachedTrack.s3Key)

        // Delete the database record
        modelContext.delete(cachedTrack)
        try? modelContext.save()
    }

    // MARK: - Artwork Cache Size

    func getArtworkCacheSize() -> Int64 {
        guard FileManager.default.fileExists(atPath: artworkDirectory.path) else { return 0 }

        var totalSize: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: artworkDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
            while let url = enumerator.nextObject() as? URL {
                if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(fileSize)
                }
            }
        }
        return totalSize
    }

    func formattedArtworkCacheSize() -> String {
        let bytes = getArtworkCacheSize()
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    func cachedArtworkCount() -> Int {
        let descriptor = FetchDescriptor<CachedArtwork>()
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    func clearArtworkCache() async {
        do {
            // Delete artwork files only
            if FileManager.default.fileExists(atPath: artworkDirectory.path) {
                try FileManager.default.removeItem(at: artworkDirectory)
            }

            // Delete artwork database records
            let artworkDescriptor = FetchDescriptor<CachedArtwork>()
            let artwork = try modelContext.fetch(artworkDescriptor)
            for art in artwork {
                modelContext.delete(art)
            }

            try modelContext.save()

            // Clear in-memory cache
            cachedArtworkUrls.removeAll()

        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Download All

    // Increased for better throughput - network I/O is the bottleneck, not CPU
    private let maxConcurrentDownloads = 8

    // Optimized URLSession for bulk downloads
    private let downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.urlCache = nil  // Don't cache, we're saving to disk
        return URLSession(configuration: config)
    }()

    func cacheAllMusic(tracks: [Track], artworkUrls: [String], catalog: MusicCatalog? = nil) async {
        guard !isDownloading else { return }

        isDownloading = true
        isCancelled = false
        error = nil
        completedFiles = 0
        currentProgress = 0

        // Build lookup maps for artist/album context
        var trackToArtist: [String: Artist] = [:]
        var trackToAlbum: [String: Album] = [:]

        if let catalog {
            for artist in catalog.artists {
                for album in artist.albums {
                    for track in album.tracks {
                        trackToArtist[track.s3Key] = artist
                        trackToAlbum[track.s3Key] = album
                    }
                }
            }
        }

        // Initialize per-track status and count already cached
        trackDownloadStatus = [:]
        var alreadyCachedCount = 0
        for track in tracks {
            if isTrackCached(track) {
                trackDownloadStatus[track.s3Key] = .cached
                alreadyCachedCount += 1
            } else {
                trackDownloadStatus[track.s3Key] = .pending
            }
        }

        // Count already cached artwork using fast in-memory lookup
        let alreadyCachedArtwork = artworkUrls.filter { isArtworkCached($0) }.count

        // Set totalFiles to only count items needing download
        let tracksToDownloadCount = tracks.count - alreadyCachedCount
        let artworkToDownloadCount = artworkUrls.count - alreadyCachedArtwork
        totalFiles = tracksToDownloadCount + artworkToDownloadCount
        completedFiles = 0
        currentProgress = totalFiles > 0 ? 0 : 1.0

        do {
            try ensureDirectoriesExist()

            // Filter to only uncached items using fast in-memory lookups
            let tracksToDownload = tracks.filter { !isTrackCached($0) }
            let artworkToDownload = artworkUrls.filter { !isArtworkCached($0) }

            // Download tracks and artwork IN PARALLEL for maximum speed
            await withTaskGroup(of: Void.self) { group in
                var activeDownloads = 0
                var trackIndex = 0
                var artworkIndex = 0

                // Process both tracks and artwork together
                while (trackIndex < tracksToDownload.count || artworkIndex < artworkToDownload.count || activeDownloads > 0) {
                    if isCancelled { break }

                    // Add track tasks up to limit (prioritize tracks over artwork)
                    while activeDownloads < maxConcurrentDownloads && trackIndex < tracksToDownload.count {
                        let track = tracksToDownload[trackIndex]
                        let artist = trackToArtist[track.s3Key]
                        let album = trackToAlbum[track.s3Key]
                        trackIndex += 1
                        activeDownloads += 1

                        trackDownloadStatus[track.s3Key] = .downloading(progress: 0)

                        group.addTask {
                            await self.downloadTrackWithRelatedArtwork(track, artist: artist, album: album)
                        }
                    }

                    // Fill remaining slots with artwork downloads
                    while activeDownloads < maxConcurrentDownloads && artworkIndex < artworkToDownload.count {
                        let urlString = artworkToDownload[artworkIndex]
                        artworkIndex += 1
                        activeDownloads += 1

                        group.addTask {
                            await self.downloadArtwork(urlString)
                        }
                    }

                    // Wait for one to complete
                    if activeDownloads > 0 {
                        await group.next()
                        activeDownloads -= 1
                        completedFiles += 1
                        currentProgress = totalFiles > 0 ? Double(completedFiles) / Double(totalFiles) : 1.0
                    }
                }
            }

            // Enforce storage limit once after all downloads complete
            await enforceStorageLimit()

        } catch {
            self.error = error.localizedDescription
        }

        currentFileName = ""
        isDownloading = false
    }

    // MARK: - Related Artwork Caching

    func cacheRelatedArtwork(for track: Track, artist: Artist?, album: Album?) async {
        var artworkUrls: [String] = []

        // Prefer album artwork over embedded artwork to reduce cache size
        // Only use embedded artwork if no album art exists
        if let url = album?.imageUrl {
            artworkUrls.append(url)
        } else if let url = track.embeddedArtworkUrl {
            artworkUrls.append(url)
        }

        // Add artist image
        if let url = artist?.imageUrl {
            artworkUrls.append(url)
        }

        // Download only uncached artwork using fast in-memory lookup
        for urlString in artworkUrls {
            if !isArtworkCached(urlString) {
                await downloadArtwork(urlString)
            }
        }
    }

    private func downloadTrackWithRelatedArtwork(_ track: Track, artist: Artist?, album: Album?) async {
        // Download the track
        await downloadTrack(track)

        // If track download succeeded, cache related artwork
        if case .completed = trackDownloadStatus[track.s3Key] {
            await cacheRelatedArtwork(for: track, artist: artist, album: album)
        }
    }

    private func downloadTrack(_ track: Track) async {
        guard let urlString = track.url, let url = URL(string: urlString) else {
            trackDownloadStatus[track.s3Key] = .failed(error: "Invalid URL")
            return
        }

        do {
            // Use optimized download session with data(from:) instead of slow byte-by-byte streaming
            // This is MUCH faster as URLSession handles buffering efficiently
            let (data, response) = try await downloadSession.data(from: url)

            // Update progress to show download complete
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                trackDownloadStatus[track.s3Key] = .downloading(progress: 1.0)
            }

            let fileExtension = url.pathExtension.isEmpty ? track.format : url.pathExtension
            let fileName = "\(sha256Hash(track.s3Key)).\(fileExtension)"
            var localURL = tracksDirectory.appendingPathComponent(fileName)

            try data.write(to: localURL)

            // Exclude from backup unless user wants unlimited (forever) cache
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = !shouldPersistTracks
            try localURL.setResourceValues(resourceValues)

            let cachedTrack = CachedTrack(
                s3Key: track.s3Key,
                localFileName: fileName,
                fileSize: Int64(data.count)
            )
            modelContext.insert(cachedTrack)
            try modelContext.save()

            // Update in-memory cache for fast lookups
            cachedTrackKeys.insert(track.s3Key)

            trackDownloadStatus[track.s3Key] = .completed

        } catch {
            trackDownloadStatus[track.s3Key] = .failed(error: error.localizedDescription)
            print("Failed to download track \(track.title): \(error)")
        }
    }

    private func downloadArtwork(_ urlString: String) async {
        guard let url = URL(string: urlString) else { return }

        do {
            // Ensure directories exist
            try ensureDirectoriesExist()

            // Use optimized download session
            let (data, _) = try await downloadSession.data(from: url)

            let fileExtension = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let fileName = "\(sha256Hash(urlString)).\(fileExtension)"
            var localURL = artworkDirectory.appendingPathComponent(fileName)

            try data.write(to: localURL)

            // Exclude from backup unless auto-caching is on (persist artwork forever)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = !shouldPersistArtwork
            try localURL.setResourceValues(resourceValues)

            let cachedArtwork = CachedArtwork(
                remoteUrl: urlString,
                localFileName: fileName,
                fileSize: Int64(data.count)
            )
            modelContext.insert(cachedArtwork)
            try modelContext.save()

            // Update in-memory cache for fast lookups
            cachedArtworkUrls.insert(urlString)

        } catch {
            print("Failed to download artwork: \(error)")
        }
    }

    // MARK: - Always-Cache Artwork (for ArtworkImage)

    /// Track in-progress artwork downloads to prevent duplicates
    private var artworkDownloadsInProgress: Set<String> = []

    /// Downloads and caches artwork if not already cached. Used by ArtworkImage for automatic caching.
    /// Returns the local URL if successfully cached.
    func cacheArtworkIfNeeded(_ urlString: String, completion: @escaping (URL?) -> Void) {
        // Skip if already cached
        if isArtworkCached(urlString) {
            completion(localArtworkURL(for: urlString))
            return
        }

        // Skip if already downloading
        if artworkDownloadsInProgress.contains(urlString) {
            return
        }

        artworkDownloadsInProgress.insert(urlString)

        // Fire-and-forget download that won't be cancelled
        Task { [weak self] in
            guard let self = self else { return }
            await self.downloadArtworkBackground(urlString, completion: completion)
        }
    }

    private func downloadArtworkBackground(_ urlString: String, completion: @escaping (URL?) -> Void) async {
        guard let url = URL(string: urlString) else {
            await MainActor.run {
                artworkDownloadsInProgress.remove(urlString)
            }
            completion(nil)
            return
        }

        do {
            // Ensure directories exist
            try ensureDirectoriesExist()

            // Use optimized download session
            let (data, _) = try await downloadSession.data(from: url)

            let fileExtension = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let fileName = "\(sha256Hash(urlString)).\(fileExtension)"
            var localURL = artworkDirectory.appendingPathComponent(fileName)

            try data.write(to: localURL)

            // Exclude from backup unless auto-caching is on (persist artwork forever)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = !shouldPersistArtwork
            try localURL.setResourceValues(resourceValues)

            let fileSize = Int64(data.count)

            await MainActor.run {
                let cachedArtwork = CachedArtwork(
                    remoteUrl: urlString,
                    localFileName: fileName,
                    fileSize: fileSize
                )
                modelContext.insert(cachedArtwork)
                try? modelContext.save()

                // Update in-memory cache for fast lookups
                cachedArtworkUrls.insert(urlString)
                artworkDownloadsInProgress.remove(urlString)
            }

            completion(localURL)

        } catch {
            await MainActor.run {
                artworkDownloadsInProgress.remove(urlString)
            }
            print("Failed to download artwork: \(error)")
            completion(nil)
        }
    }

    // MARK: - Background Artwork Prefetch

    /// Prefetch all artwork in the background after catalog loads.
    /// Respects autoImageCachingEnabled setting, skips already-cached URLs,
    /// and uses 4 concurrent connections to avoid competing with user-initiated downloads.
    /// Each URL is marked in-progress only when its download starts (not batch),
    /// so on-demand downloads from ArtworkImage views aren't blocked for queued URLs.
    private var isPrefetchingArtwork = false

    func prefetchAllArtwork(urls: [String]) {
        guard shouldPersistArtwork, !isPrefetchingArtwork else { return }

        let uncached = urls.filter { !isArtworkCached($0) && !artworkDownloadsInProgress.contains($0) }
        guard !uncached.isEmpty else { return }

        isPrefetchingArtwork = true
        let total = urls.count
        let toDownload = uncached.count
        print("CacheService: Artwork prefetch — downloading \(toDownload) of \(total) URLs")

        Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                var active = 0
                var index = 0
                let maxConcurrent = 4

                while index < uncached.count || active > 0 {
                    while active < maxConcurrent && index < uncached.count {
                        let urlString = uncached[index]
                        index += 1

                        // Skip if on-demand download claimed it or it was cached in the meantime
                        if isArtworkCached(urlString) || artworkDownloadsInProgress.contains(urlString) {
                            continue
                        }

                        // Mark in-progress just before download starts (not batch)
                        artworkDownloadsInProgress.insert(urlString)
                        active += 1
                        group.addTask {
                            await self.downloadArtworkBackground(urlString) { _ in }
                        }
                    }
                    if active > 0 {
                        await group.next()
                        active -= 1
                    }
                }
            }
            isPrefetchingArtwork = false
            print("CacheService: Artwork prefetch complete")
        }
    }

    // MARK: - Single Track Download (for pre-caching)

    func downloadSingleTrack(_ track: Track) async {
        // Skip if already cached
        if isTrackCached(track) { return }

        // Skip if already downloading
        if case .downloading = trackDownloadStatus[track.s3Key] { return }

        trackDownloadStatus[track.s3Key] = .downloading(progress: 0)
        await downloadTrack(track)
    }

    // MARK: - Cancel

    func cancelDownload() {
        isCancelled = true
    }

    // MARK: - Backup Exclusion Updates

    /// Update isExcludedFromBackup on all cached track files based on current storage limit setting
    func updateTrackBackupExclusion() {
        let exclude = !shouldPersistTracks
        let descriptor = FetchDescriptor<CachedTrack>()
        guard let tracks = try? modelContext.fetch(descriptor) else { return }
        let filenames = tracks.map { $0.localFileName }
        let tracksDir = tracksDirectory

        Task.detached {
            for filename in filenames {
                var localURL = tracksDir.appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: localURL.path) else { continue }
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = exclude
                try? localURL.setResourceValues(resourceValues)
            }
        }
    }

    /// Update isExcludedFromBackup on all cached artwork files based on current auto-caching setting
    func updateArtworkBackupExclusion() {
        let exclude = !shouldPersistArtwork
        let descriptor = FetchDescriptor<CachedArtwork>()
        guard let artwork = try? modelContext.fetch(descriptor) else { return }
        let filenames = artwork.map { $0.localFileName }
        let artworkDir = artworkDirectory

        Task.detached {
            for filename in filenames {
                var localURL = artworkDir.appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: localURL.path) else { continue }
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = exclude
                try? localURL.setResourceValues(resourceValues)
            }
        }
    }

    // MARK: - Clear Cache

    func clearCache() async {
        do {
            // Delete files
            if FileManager.default.fileExists(atPath: cacheDirectory.path) {
                try FileManager.default.removeItem(at: cacheDirectory)
            }

            // Delete database records
            let trackDescriptor = FetchDescriptor<CachedTrack>()
            let tracks = try modelContext.fetch(trackDescriptor)
            for track in tracks {
                modelContext.delete(track)
            }

            let artworkDescriptor = FetchDescriptor<CachedArtwork>()
            let artwork = try modelContext.fetch(artworkDescriptor)
            for art in artwork {
                modelContext.delete(art)
            }

            try modelContext.save()

            // Clear in-memory caches
            cachedTrackKeys.removeAll()
            cachedArtworkUrls.removeAll()

        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Clear All Data (Cache + Catalog)

    /// Clears all cache files, cache records, and catalog data from SwiftData.
    /// Use this for "Delete All Data" functionality.
    func clearAllData() async {
        do {
            // Delete cache files
            if FileManager.default.fileExists(atPath: cacheDirectory.path) {
                try FileManager.default.removeItem(at: cacheDirectory)
            }

            // Delete cache records (batch delete works fine for these)
            try modelContext.delete(model: CachedTrack.self)
            try modelContext.delete(model: CachedArtwork.self)

            // Delete catalog records - must fetch and delete individually due to relationships
            // Batch delete doesn't respect cascade rules properly
            let trackDescriptor = FetchDescriptor<CatalogTrack>()
            let tracks = try modelContext.fetch(trackDescriptor)
            for track in tracks {
                modelContext.delete(track)
            }

            let albumDescriptor = FetchDescriptor<CatalogAlbum>()
            let albums = try modelContext.fetch(albumDescriptor)
            for album in albums {
                modelContext.delete(album)
            }

            let artistDescriptor = FetchDescriptor<CatalogArtist>()
            let artists = try modelContext.fetch(artistDescriptor)
            for artist in artists {
                modelContext.delete(artist)
            }

            let metadataDescriptor = FetchDescriptor<CatalogMetadata>()
            let metadata = try modelContext.fetch(metadataDescriptor)
            for meta in metadata {
                modelContext.delete(meta)
            }

            try modelContext.save()

            // Clear in-memory caches
            cachedTrackKeys.removeAll()
            cachedArtworkUrls.removeAll()

        } catch {
            self.error = error.localizedDescription
        }
    }
}
