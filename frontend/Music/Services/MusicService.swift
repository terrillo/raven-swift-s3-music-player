//
//  MusicService.swift
//  Music
//

import Foundation
import SwiftData

@MainActor
@Observable
class MusicService {
    private(set) var catalog: MusicCatalog?
    private(set) var isLoading = false
    var error: Error?  // Settable to allow clearing from UI
    private(set) var isOffline = false
    private(set) var lastUpdated: Date?

    /// Whether catalog was built from iCloud-synced SwiftData records
    private(set) var isUsingLocalDatabase = false

    private var modelContext: ModelContext?
    private let catalogBaseURL = "https://terrillo.sfo3.cdn.digitaloceanspaces.com/music/music_catalog.json"

    // Cached computed properties for performance with large catalogs
    private var _cachedSongs: [Track]?
    private var _cachedAlbums: [Album]?
    private var _cachedArtists: [Artist]?

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
        let consolidated = grouped.map { (primaryName, artists) -> Artist in
            // Combine albums from all matching artists
            let allAlbums = artists.flatMap { $0.albums }

            // Use metadata from first artist that has each field
            let base = artists.first!
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

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    private func invalidateCaches() {
        _cachedSongs = nil
        _cachedAlbums = nil
        _cachedArtists = nil
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

    func loadCatalog() async {
        guard !isLoading else { return }

        isLoading = true
        error = nil
        isOffline = false
        invalidateCaches()

        // Add timestamp cache breaker to bypass CDN cache
        let timestamp = Int(Date().timeIntervalSince1970)
        guard let catalogURL = URL(string: "\(catalogBaseURL)?\(timestamp)") else {
            self.error = URLError(.badURL)
            isLoading = false
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: catalogURL)
            let decoder = JSONDecoder()
            let fetchedCatalog = try decoder.decode(MusicCatalog.self, from: data)
            catalog = fetchedCatalog
            lastUpdated = Date()

            // Save to cache
            await saveCatalogToCache(data: data, catalog: fetchedCatalog)
        } catch {
            // Check if this is actually a network unavailability error
            let isNetworkUnavailable: Bool
            if let urlError = error as? URLError {
                isNetworkUnavailable = [
                    .notConnectedToInternet,
                    .networkConnectionLost,
                    .dataNotAllowed,
                    .internationalRoamingOff
                ].contains(urlError.code)
            } else {
                isNetworkUnavailable = false
            }

            // Only fall back to cache and show offline mode for actual network unavailability
            if isNetworkUnavailable {
                if let cachedCatalog = await loadCatalogFromCache() {
                    catalog = cachedCatalog
                    isOffline = true
                } else {
                    self.error = error
                    print("Failed to load catalog (offline, no cache): \(error)")
                }
            } else {
                // Other errors (server errors, decoding errors, etc.) - keep existing catalog if available
                if catalog == nil {
                    if let cachedCatalog = await loadCatalogFromCache() {
                        catalog = cachedCatalog
                    } else {
                        self.error = error
                    }
                }
                print("Failed to refresh catalog: \(error)")
            }
        }

        isLoading = false
    }

    private func saveCatalogToCache(data: Data, catalog: MusicCatalog) async {
        guard let modelContext else { return }

        // Delete existing cached catalog
        let descriptor = FetchDescriptor<CachedCatalog>(
            predicate: #Predicate { $0.id == "main" }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            modelContext.delete(existing)
        }

        let cached = CachedCatalog(
            catalogData: data,
            totalTracks: catalog.totalTracks,
            generatedAt: catalog.generatedAt
        )
        modelContext.insert(cached)
        try? modelContext.save()
    }

    private func loadCatalogFromCache() async -> MusicCatalog? {
        guard let modelContext else { return nil }

        let descriptor = FetchDescriptor<CachedCatalog>(
            predicate: #Predicate { $0.id == "main" }
        )
        guard let cached = try? modelContext.fetch(descriptor).first else { return nil }

        let decoder = JSONDecoder()
        lastUpdated = cached.cachedAt
        return try? decoder.decode(MusicCatalog.self, from: cached.catalogData)
    }

    // MARK: - Build Catalog from SwiftData

    /// Build a MusicCatalog from iCloud-synced UploadedTrack records.
    /// This replaces the need for a JSON catalog file.
    func loadCatalogFromDatabase() async {
        guard !isLoading else { return }
        guard let modelContext else { return }

        isLoading = true
        error = nil
        invalidateCaches()

        do {
            // Fetch all uploaded tracks
            let trackDescriptor = FetchDescriptor<UploadedTrack>(
                sortBy: [SortDescriptor(\.artist), SortDescriptor(\.album), SortDescriptor(\.trackNumber)]
            )
            let uploadedTracks = try modelContext.fetch(trackDescriptor)

            // If no tracks in database, fall back to CDN catalog
            if uploadedTracks.isEmpty {
                isLoading = false
                await loadCatalog()
                return
            }

            // Fetch all artists and albums for metadata
            let artistDescriptor = FetchDescriptor<UploadedArtist>()
            let uploadedArtists = try modelContext.fetch(artistDescriptor)
            let artistMap = Dictionary(uniqueKeysWithValues: uploadedArtists.map { ($0.id, $0) })

            let albumDescriptor = FetchDescriptor<UploadedAlbum>()
            let uploadedAlbums = try modelContext.fetch(albumDescriptor)
            let albumMap = Dictionary(uniqueKeysWithValues: uploadedAlbums.map { ($0.id, $0) })

            // Build catalog structure
            let catalog = buildCatalog(
                from: uploadedTracks,
                artistMap: artistMap,
                albumMap: albumMap
            )

            self.catalog = catalog
            self.lastUpdated = uploadedTracks.map(\.uploadedAt).max()
            self.isUsingLocalDatabase = true

        } catch {
            self.error = error
            print("Failed to load catalog from database: \(error)")
        }

        isLoading = false
    }

    private func buildCatalog(
        from tracks: [UploadedTrack],
        artistMap: [String: UploadedArtist],
        albumMap: [String: UploadedAlbum]
    ) -> MusicCatalog {
        // Group tracks by artist -> album
        var artistAlbums: [String: [String: [UploadedTrack]]] = [:]

        for track in tracks {
            let artistKey = track.uploadedArtistId ?? UploadIdentifiers.artistId(track.artist ?? "Unknown Artist")
            let albumKey = track.uploadedAlbumId ?? UploadIdentifiers.albumId(
                artist: track.artist ?? "Unknown Artist",
                album: track.album ?? "Unknown Album"
            )

            if artistAlbums[artistKey] == nil {
                artistAlbums[artistKey] = [:]
            }
            if artistAlbums[artistKey]![albumKey] == nil {
                artistAlbums[artistKey]![albumKey] = []
            }
            artistAlbums[artistKey]![albumKey]!.append(track)
        }

        // Build Artist array
        var artists: [Artist] = []

        for (artistId, albums) in artistAlbums.sorted(by: { $0.key < $1.key }) {
            let uploadedArtist = artistMap[artistId]
            let artistName = uploadedArtist?.name ?? artistId.replacingOccurrences(of: "-", with: " ")

            var albumArray: [Album] = []
            for (albumId, albumTracks) in albums.sorted(by: { $0.key < $1.key }) {
                let uploadedAlbum = albumMap[albumId]
                let albumName = uploadedAlbum?.name ?? albumId.components(separatedBy: "/").last ?? "Unknown Album"

                // Build Track array
                let trackArray = albumTracks.sorted {
                    ($0.discNumber ?? 1, $0.trackNumber ?? 0) < ($1.discNumber ?? 1, $1.trackNumber ?? 0)
                }.map { track in
                    Track(
                        title: track.title,
                        artist: track.artist,
                        album: track.album,
                        trackNumber: track.trackNumber,
                        duration: track.duration,
                        format: track.format,
                        s3Key: track.s3Key,
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
                        originalFormat: track.originalFormat
                    )
                }

                let album = Album(
                    name: albumName,
                    imageUrl: uploadedAlbum?.imageUrl,
                    wiki: uploadedAlbum?.wiki,
                    releaseDate: uploadedAlbum?.releaseDate,
                    genre: uploadedAlbum?.genre,
                    style: uploadedAlbum?.style,
                    mood: uploadedAlbum?.mood,
                    theme: uploadedAlbum?.theme,
                    tracks: trackArray,
                    releaseType: uploadedAlbum?.releaseType,
                    country: uploadedAlbum?.country,
                    label: uploadedAlbum?.label,
                    barcode: uploadedAlbum?.barcode,
                    mediaFormat: uploadedAlbum?.mediaFormat
                )
                albumArray.append(album)
            }

            let artist = Artist(
                name: artistName,
                imageUrl: uploadedArtist?.imageUrl,
                bio: uploadedArtist?.bio,
                genre: uploadedArtist?.genre,
                style: uploadedArtist?.style,
                mood: uploadedArtist?.mood,
                albums: albumArray,
                artistType: uploadedArtist?.artistType,
                area: uploadedArtist?.area,
                beginDate: uploadedArtist?.beginDate,
                endDate: uploadedArtist?.endDate,
                disambiguation: uploadedArtist?.disambiguation
            )
            artists.append(artist)
        }

        return MusicCatalog(
            artists: artists,
            totalTracks: tracks.count,
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    /// Refresh catalog, preferring database if available, falling back to CDN
    func refreshCatalog() async {
        guard let modelContext else {
            await loadCatalog()
            return
        }

        // Check if we have any uploaded tracks
        let descriptor = FetchDescriptor<UploadedTrack>()
        let count = (try? modelContext.fetchCount(descriptor)) ?? 0

        if count > 0 {
            await loadCatalogFromDatabase()
        } else {
            await loadCatalog()
        }
    }
}
