//
//  MusicService.swift
//  Music
//
//  Loads catalog from SwiftData or fetches from CDN if empty.
//

import Foundation
import SwiftData

@MainActor
@Observable
class MusicService {
    enum LoadingStage: String {
        case idle = "Idle"
        case syncingCloudSettings = "Syncing settings..."
        case checkingLocalCache = "Checking local cache..."
        case fetchingFromCDN = "Fetching catalog..."
        case complete = "Complete"
        case failed = "Failed"
    }

    private(set) var catalog: MusicCatalog?
    private(set) var isLoading = false
    private(set) var loadingStage: LoadingStage = .idle
    private(set) var retryCount: Int = 0
    let maxRetries: Int = 3
    var error: Error?
    private(set) var lastUpdated: Date?

    private var modelContext: ModelContext?
    private var loadCatalogTask: Task<Void, Never>?

    // CDN settings (synced via iCloud Key-Value storage)
    static let defaultCDNBase = "https://terrillo.sfo3.cdn.digitaloceanspaces.com"
    static let defaultCDNPrefix = "music"

    /// Get catalog URL - reads from iCloud Key-Value store (set by macOS uploader)
    private var catalogURL: URL? {
        let store = NSUbiquitousKeyValueStore.default
        let base = store.string(forKey: "cdnBaseURL") ?? Self.defaultCDNBase
        let prefix = store.string(forKey: "cdnPrefix") ?? Self.defaultCDNPrefix
        let timestamp = Int(Date().timeIntervalSince1970)
        return URL(string: "\(base)/\(prefix)/catalog.json?\(timestamp)")
    }

    /// Sync iCloud Key-Value store on launch
    static func syncCloudSettings() {
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    // Cached computed properties for performance with large catalogs
    private var _cachedSongs: [Track]?
    private var _cachedAlbums: [Album]?
    private var _cachedArtists: [Artist]?
    private var _artistByName: [String: Artist]?
    private var _trackByS3Key: [String: Track]?
    private var _cachedRecentlyAdded: [Track]?

    /// Whether the catalog is empty (no music uploaded yet)
    var isEmpty: Bool {
        catalog?.artists.isEmpty ?? true
    }

    var artists: [Artist] {
        if let cached = _cachedArtists { return cached }
        guard let rawArtists = catalog?.artists else { return [] }

        // Group artists by primary name (before comma or &)
        var grouped: [String: [Artist]] = [:]
        for artist in rawArtists {
            let primary = primaryArtistName(artist.name)
            grouped[primary, default: []].append(artist)
        }

        // Consolidate each group into a single artist
        let consolidated = grouped.compactMap { (primaryName, artists) -> Artist? in
            // Combine albums from all matching artists
            let allAlbums = artists.flatMap { $0.albums }

            // Use metadata from first artist that has each field
            guard let base = artists.first else { return nil }
            return Artist(
                name: primaryName,
                imageUrl: artists.compactMap(\.imageUrl).first ?? allAlbums.compactMap(\.imageUrl).first,
                bio: artists.compactMap(\.bio).first ?? base.bio,
                genre: artists.compactMap(\.genre).first ?? base.genre,
                style: artists.compactMap(\.style).first ?? base.style,
                mood: artists.compactMap(\.mood).first ?? base.mood,
                albums: allAlbums,
                artistType: artists.compactMap(\.artistType).first ?? base.artistType,
                area: artists.compactMap(\.area).first ?? base.area,
                beginDate: artists.compactMap(\.beginDate).first ?? base.beginDate,
                endDate: artists.compactMap(\.endDate).first ?? base.endDate,
                disambiguation: artists.compactMap(\.disambiguation).first ?? base.disambiguation
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        _cachedArtists = consolidated
        return consolidated
    }

    var albums: [Album] {
        if let cached = _cachedAlbums { return cached }
        let result = catalog?.artists.flatMap { $0.albums } ?? []
        _cachedAlbums = result
        return result
    }

    var songs: [Track] {
        if let cached = _cachedSongs { return cached }
        let sorted = (catalog?.artists.flatMap { $0.albums.flatMap { $0.tracks } } ?? [])
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        _cachedSongs = sorted
        return sorted
    }

    /// O(1) lookup for artists by name
    var artistByName: [String: Artist] {
        if let cached = _artistByName { return cached }
        let map = Dictionary(uniqueKeysWithValues: artists.map { ($0.name, $0) })
        _artistByName = map
        return map
    }

    /// O(1) lookup for tracks by s3Key
    var trackByS3Key: [String: Track] {
        if let cached = _trackByS3Key { return cached }
        let map = Dictionary(uniqueKeysWithValues: songs.map { ($0.s3Key, $0) })
        _trackByS3Key = map
        return map
    }

    /// 20 most recently added songs, sorted by addedAt descending
    var recentlyAddedSongs: [Track] {
        if let cached = _cachedRecentlyAdded { return cached }
        let sorted = songs
            .filter { $0.addedAt != nil }
            .sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
            .prefix(20)
        let result = Array(sorted)
        _cachedRecentlyAdded = result
        return result
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func invalidateCaches() {
        _cachedSongs = nil
        _cachedAlbums = nil
        _cachedArtists = nil
        _artistByName = nil
        _trackByS3Key = nil
        _cachedRecentlyAdded = nil
    }

    private func primaryArtistName(_ name: String) -> String {
        let separators = [", ", " & "]
        var result = name
        for separator in separators {
            if let range = result.range(of: separator) {
                result = String(result[..<range.lowerBound])
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    func loadCatalog(forceRefresh: Bool = false) async {
        // Cancel any existing load task
        loadCatalogTask?.cancel()

        loadCatalogTask = Task {
            await performLoadCatalog(forceRefresh: forceRefresh)
        }

        await loadCatalogTask?.value
    }

    /// Load catalog with automatic retry on failure (up to maxRetries with exponential backoff)
    func loadCatalogWithRetry(forceRefresh: Bool = false) async {
        retryCount = 0
        error = nil

        while retryCount <= maxRetries {
            await loadCatalog(forceRefresh: forceRefresh)

            // Success: catalog loaded or legitimately empty (no error)
            if error == nil {
                loadingStage = .complete
                return
            }

            retryCount += 1

            // If we've exhausted retries, mark as failed
            if retryCount > maxRetries {
                loadingStage = .failed
                return
            }

            // Exponential backoff: 1s, 2s, 4s
            let delay = pow(2.0, Double(retryCount - 1))
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// Clear error state for manual retry
    func resetError() {
        error = nil
        loadingStage = .idle
        retryCount = 0
    }

    private func performLoadCatalog(forceRefresh: Bool) async {
        guard !isLoading else { return }

        isLoading = true
        error = nil
        invalidateCaches()

        // Sync iCloud settings first (get latest CDN prefix from macOS)
        loadingStage = .syncingCloudSettings
        Self.syncCloudSettings()

        // Clear cache if force refreshing
        if forceRefresh {
            await clearSwiftDataCache()
        }

        // Try loading from SwiftData first
        loadingStage = .checkingLocalCache
        await loadFromSwiftData()

        // Only fetch from CDN when explicitly requested (via Settings "Sync Catalog")
        if forceRefresh && (catalog?.artists.isEmpty ?? true) {
            loadingStage = .fetchingFromCDN
            await fetchFromCDN()
        }

        loadingStage = error == nil ? .complete : .failed
        isLoading = false
    }

    /// Load catalog from SwiftData
    private func loadFromSwiftData() async {
        guard let modelContext else {
            catalog = MusicCatalog(artists: [], totalTracks: 0, generatedAt: Date().ISO8601Format())
            return
        }

        let descriptor = FetchDescriptor<CatalogArtist>()
        guard let catalogArtists = try? modelContext.fetch(descriptor), !catalogArtists.isEmpty else {
            catalog = MusicCatalog(artists: [], totalTracks: 0, generatedAt: Date().ISO8601Format())
            return
        }

        // Get catalog metadata
        let metadataDescriptor = FetchDescriptor<CatalogMetadata>(
            predicate: #Predicate { $0.id == "main" }
        )
        let metadata = try? modelContext.fetch(metadataDescriptor).first

        // Convert SwiftData models to existing Codable models
        let artists = catalogArtists
            .map { $0.toArtist() }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let totalTracks = metadata?.totalTracks ?? artists.flatMap { $0.albums.flatMap { $0.tracks } }.count
        let generatedAt = metadata?.generatedAt.ISO8601Format() ?? Date().ISO8601Format()

        catalog = MusicCatalog(artists: artists, totalTracks: totalTracks, generatedAt: generatedAt)
        lastUpdated = metadata?.updatedAt ?? Date()
    }

    /// Fetch catalog.json from CDN and populate SwiftData
    private func fetchFromCDN() async {
        guard let url = catalogURL else {
            print("⚠️ Invalid catalog URL")
            return
        }

        do {
            print("📡 Fetching catalog from: \(url)")
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("⚠️ Catalog not found on CDN (status: \((response as? HTTPURLResponse)?.statusCode ?? 0)) \(url)")
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let remoteCatalog = try decoder.decode(MusicCatalog.self, from: data)

            // Save to SwiftData for offline access
            await saveCatalogToSwiftData(remoteCatalog)

            catalog = remoteCatalog
            lastUpdated = Date()
            print("✅ Fetched catalog from CDN: \(remoteCatalog.artists.count) artists")
        } catch {
            print("❌ Failed to fetch catalog from CDN: \(error)")
            self.error = error
        }
    }

    /// Save fetched catalog to SwiftData for offline access
    private func saveCatalogToSwiftData(_ remoteCatalog: MusicCatalog) async {
        guard let modelContext else { return }

        // Delete existing catalog data
        try? modelContext.delete(model: CatalogTrack.self)
        try? modelContext.delete(model: CatalogAlbum.self)
        try? modelContext.delete(model: CatalogArtist.self)
        try? modelContext.delete(model: CatalogMetadata.self)

        // Convert and insert artists
        for artist in remoteCatalog.artists {
            let catalogArtist = CatalogArtist(
                id: artist.id,
                name: artist.name,
                bio: artist.bio,
                imageUrl: artist.imageUrl,
                genre: artist.genre,
                style: artist.style,
                mood: artist.mood,
                artistType: artist.artistType,
                area: artist.area,
                beginDate: artist.beginDate,
                endDate: artist.endDate,
                disambiguation: artist.disambiguation
            )

            for album in artist.albums {
                let catalogAlbum = CatalogAlbum(
                    id: album.id,
                    name: album.name,
                    imageUrl: album.imageUrl,
                    wiki: album.wiki,
                    releaseDate: album.releaseDate,
                    genre: album.genre,
                    style: album.style,
                    mood: album.mood,
                    theme: album.theme,
                    releaseType: album.releaseType,
                    country: album.country,
                    label: album.label,
                    barcode: album.barcode,
                    mediaFormat: album.mediaFormat
                )
                catalogAlbum.artist = catalogArtist
                if catalogArtist.albums == nil { catalogArtist.albums = [] }
                catalogArtist.albums?.append(catalogAlbum)

                for track in album.tracks {
                    let catalogTrack = CatalogTrack(
                        s3Key: track.s3Key,
                        title: track.title,
                        artistName: track.artist,
                        albumName: track.album,
                        trackNumber: track.trackNumber,
                        duration: track.duration,
                        format: track.format,
                        url: track.url,
                        embeddedArtworkUrl: track.embeddedArtworkUrl,
                        genre: track.genre,
                        style: track.style,
                        mood: track.mood,
                        theme: track.theme,
                        albumArtist: track.albumArtist,
                        trackTotal: track.trackTotal,
                        discNumber: track.discNumber,
                        discTotal: track.discTotal,
                        year: track.year,
                        composer: track.composer,
                        comment: track.comment,
                        bitrate: track.bitrate,
                        samplerate: track.samplerate,
                        channels: track.channels,
                        filesize: track.filesize,
                        originalFormat: track.originalFormat,
                        addedAt: track.addedAt
                    )
                    catalogTrack.catalogAlbum = catalogAlbum
                    if catalogAlbum.tracks == nil { catalogAlbum.tracks = [] }
                    catalogAlbum.tracks?.append(catalogTrack)
                }
            }

            modelContext.insert(catalogArtist)
        }

        // Save metadata
        let metadata = CatalogMetadata(totalTracks: remoteCatalog.totalTracks)
        modelContext.insert(metadata)

        try? modelContext.save()
    }

    /// Clear SwiftData catalog cache for force refresh
    private func clearSwiftDataCache() async {
        guard let modelContext else { return }
        try? modelContext.delete(model: CatalogTrack.self)
        try? modelContext.delete(model: CatalogAlbum.self)
        try? modelContext.delete(model: CatalogArtist.self)
        try? modelContext.delete(model: CatalogMetadata.self)
        try? modelContext.save()
    }
}
