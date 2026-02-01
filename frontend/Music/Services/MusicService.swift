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

    /// Load catalog from SwiftData (iCloud-synced UploadedTrack records).
    func loadCatalog() async {
        guard !isLoading else { return }
        guard let modelContext else {
            print("[MusicService] Not configured with modelContext")
            isLoading = false
            return
        }

        isLoading = true
        error = nil
        invalidateCaches()

        do {
            // Fetch all uploaded tracks from SwiftData
            let trackDescriptor = FetchDescriptor<UploadedTrack>(
                sortBy: [SortDescriptor(\.artist), SortDescriptor(\.album), SortDescriptor(\.trackNumber)]
            )
            let uploadedTracks = try modelContext.fetch(trackDescriptor)

            if uploadedTracks.isEmpty {
                // No tracks yet - show empty state
                catalog = MusicCatalog(artists: [], totalTracks: 0, generatedAt: ISO8601DateFormatter().string(from: Date()))
                isLoading = false
                return
            }

            // Fetch artist/album metadata
            let artistDescriptor = FetchDescriptor<UploadedArtist>()
            let uploadedArtists = try modelContext.fetch(artistDescriptor)
            let artistMap = Dictionary(uniqueKeysWithValues: uploadedArtists.map { ($0.id, $0) })

            let albumDescriptor = FetchDescriptor<UploadedAlbum>()
            let uploadedAlbums = try modelContext.fetch(albumDescriptor)
            let albumMap = Dictionary(uniqueKeysWithValues: uploadedAlbums.map { ($0.id, $0) })

            // Build catalog from SwiftData
            catalog = buildCatalog(from: uploadedTracks, artistMap: artistMap, albumMap: albumMap)
            lastUpdated = uploadedTracks.map(\.uploadedAt).max()
            isUsingLocalDatabase = true

            print("[MusicService] Loaded \(uploadedTracks.count) tracks from SwiftData")

        } catch {
            self.error = error
            print("[MusicService] Failed to load catalog from database: \(error)")
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

                // Fallback: album artwork → first track's embedded artwork
                let albumImageUrl = uploadedAlbum?.imageUrl
                    ?? trackArray.first?.embeddedArtworkUrl

                let album = Album(
                    name: albumName,
                    imageUrl: albumImageUrl,
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

            // Fallback: artist image → first album's artwork
            let artistImageUrl = uploadedArtist?.imageUrl
                ?? albumArray.first?.imageUrl

            let artist = Artist(
                name: artistName,
                imageUrl: artistImageUrl,
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

    /// Refresh catalog from SwiftData.
    func refreshCatalog() async {
        await loadCatalog()
    }

    // MARK: - Clear All Data

    /// Deletes all iCloud-synced catalog data and clears in-memory state.
    func clearAllData() async {
        guard let modelContext else {
            print("[MusicService] No modelContext for clearing data")
            return
        }

        do {
            // Delete all UploadedTrack records
            let trackDescriptor = FetchDescriptor<UploadedTrack>()
            let tracks = try modelContext.fetch(trackDescriptor)
            for track in tracks {
                modelContext.delete(track)
            }

            // Delete all UploadedArtist records
            let artistDescriptor = FetchDescriptor<UploadedArtist>()
            let artists = try modelContext.fetch(artistDescriptor)
            for artist in artists {
                modelContext.delete(artist)
            }

            // Delete all UploadedAlbum records
            let albumDescriptor = FetchDescriptor<UploadedAlbum>()
            let albums = try modelContext.fetch(albumDescriptor)
            for album in albums {
                modelContext.delete(album)
            }

            try modelContext.save()

            // Clear in-memory state
            catalog = nil
            invalidateCaches()
            lastUpdated = nil
            isUsingLocalDatabase = false

            print("[MusicService] All data cleared successfully")
        } catch {
            print("[MusicService] Failed to clear data: \(error)")
        }
    }
}
