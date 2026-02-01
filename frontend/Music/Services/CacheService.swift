//
//  CacheService.swift
//  Music
//

import Foundation
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

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        loadCachedKeys()
    }

    /// Load all cached keys into memory for O(1) lookups
    func loadCachedKeys() {
        // Load cached track s3Keys
        let trackDescriptor = FetchDescriptor<CachedTrack>()
        let tracks = (try? modelContext.fetch(trackDescriptor)) ?? []
        cachedTrackKeys = Set(tracks.map { $0.s3Key })

        // Load cached artwork URLs
        let artworkDescriptor = FetchDescriptor<CachedArtwork>()
        let artwork = (try? modelContext.fetch(artworkDescriptor)) ?? []
        cachedArtworkUrls = Set(artwork.map { $0.remoteUrl })
    }

    // MARK: - Directory Management

    private var cacheDirectory: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("MusicCache", isDirectory: true)
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
        let descriptor = FetchDescriptor<CachedTrack>(
            predicate: #Predicate { $0.s3Key == track.s3Key }
        )
        let results = (try? modelContext.fetch(descriptor)) ?? []
        guard let cached = results.first else { return nil }

        let localURL = tracksDirectory.appendingPathComponent(cached.localFileName)
        guard FileManager.default.fileExists(atPath: localURL.path) else { return nil }
        return localURL
    }

    func localArtworkURL(for urlString: String) -> URL? {
        let descriptor = FetchDescriptor<CachedArtwork>(
            predicate: #Predicate { $0.remoteUrl == urlString }
        )
        let results = (try? modelContext.fetch(descriptor)) ?? []
        guard let cached = results.first else { return nil }

        let localURL = artworkDirectory.appendingPathComponent(cached.localFileName)
        guard FileManager.default.fileExists(atPath: localURL.path) else { return nil }
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

    // MARK: - Artwork Cache Size

    func getArtworkCacheSize() -> Int64 {
        guard FileManager.default.fileExists(atPath: artworkDirectory.path) else { return 0 }

        let files = try? FileManager.default.contentsOfDirectory(
            at: artworkDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        return files?.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        } ?? 0
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
            // Delete artwork files
            if FileManager.default.fileExists(atPath: artworkDirectory.path) {
                try FileManager.default.removeItem(at: artworkDirectory)
            }

            // Delete artwork database records
            let descriptor = FetchDescriptor<CachedArtwork>()
            let artwork = try modelContext.fetch(descriptor)
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
        totalFiles = tracks.count + artworkUrls.count
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

        // Update progress for already cached items
        completedFiles = alreadyCachedCount + alreadyCachedArtwork
        currentProgress = Double(completedFiles) / Double(totalFiles)

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
                        currentProgress = Double(completedFiles) / Double(totalFiles)
                    }
                }
            }

        } catch {
            self.error = error.localizedDescription
        }

        currentFileName = ""
        isDownloading = false
    }

    // MARK: - Related Artwork Caching

    func cacheRelatedArtwork(for track: Track, artist: Artist?, album: Album?) async {
        var artworkUrls: [String] = []

        // Add track's embedded artwork
        if let url = track.embeddedArtworkUrl {
            artworkUrls.append(url)
        }

        // Add album artwork
        if let url = album?.imageUrl {
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
            let localURL = tracksDirectory.appendingPathComponent(fileName)

            try data.write(to: localURL)

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
            let localURL = artworkDirectory.appendingPathComponent(fileName)

            try data.write(to: localURL)

            let cachedArtwork = CachedArtwork(
                remoteUrl: urlString,
                localFileName: fileName
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
        Task.detached { [weak self] in
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
            let localURL = artworkDirectory.appendingPathComponent(fileName)

            try data.write(to: localURL)

            await MainActor.run {
                let cachedArtwork = CachedArtwork(
                    remoteUrl: urlString,
                    localFileName: fileName
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
}
