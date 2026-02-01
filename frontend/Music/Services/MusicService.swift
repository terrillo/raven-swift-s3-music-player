//
//  MusicService.swift
//  Music
//
//  Loads catalog exclusively from SwiftData (populated by macOS upload feature).
//

import Foundation
import SwiftData

@MainActor
@Observable
class MusicService {
    private(set) var catalog: MusicCatalog?
    private(set) var isLoading = false
    var error: Error?
    private(set) var lastUpdated: Date?

    private var modelContext: ModelContext?

    // Cached computed properties for performance with large catalogs
    private var _cachedSongs: [Track]?
    private var _cachedAlbums: [Album]?
    private var _cachedArtists: [Artist]?

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
        invalidateCaches()

        // Load exclusively from SwiftData
        await loadFromSwiftData()

        isLoading = false
    }

    /// Load catalog from SwiftData (populated by macOS upload, synced via CloudKit)
    private func loadFromSwiftData() async {
        guard let modelContext else {
            // No model context - catalog will be empty
            catalog = MusicCatalog(artists: [], totalTracks: 0, generatedAt: Date().ISO8601Format())
            return
        }

        let descriptor = FetchDescriptor<CatalogArtist>()
        guard let catalogArtists = try? modelContext.fetch(descriptor), !catalogArtists.isEmpty else {
            // No catalog data yet - this is expected on fresh install
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
}
