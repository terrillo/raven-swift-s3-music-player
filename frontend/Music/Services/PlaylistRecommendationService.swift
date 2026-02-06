//
//  PlaylistRecommendationService.swift
//  Music
//
//  Generates track recommendations for playlists using Last.fm similar artists
//  and play history affinity scores.
//

import Foundation

@MainActor
class PlaylistRecommendationService {
    static let shared = PlaylistRecommendationService()

    private init() {}

    // MARK: - Recommendation Generation

    /// Generate track recommendations based on playlist contents
    /// - Parameters:
    ///   - playlist: The playlist to generate recommendations for
    ///   - musicService: The music service containing the catalog
    ///   - limit: Maximum number of recommendations to return
    /// - Returns: Array of recommended tracks sorted by score
    func generateRecommendations(
        for playlist: PlaylistEntity,
        musicService: MusicService,
        limit: Int = 20
    ) async -> [Track] {
        let playlistTracks = PlaylistStore.shared.fetchTracks(for: playlist)

        guard !playlistTracks.isEmpty else { return [] }

        // Build lookup for catalog tracks
        let trackLookup = musicService.trackByS3Key

        // Extract seed data from playlist
        let seedArtists = extractSeedArtists(from: playlistTracks)
        let seedGenres = extractSeedGenres(from: playlistTracks, using: trackLookup)
        let seedMoods = extractSeedMoods(from: playlistTracks, using: trackLookup)
        let seedStyles = extractSeedStyles(from: playlistTracks, using: trackLookup)
        let playlistS3Keys = Set(playlistTracks.compactMap { $0.trackS3Key })

        // Fetch similar artists from Last.fm (limit API calls)
        let similarArtistsMap = await fetchSimilarArtists(for: Array(seedArtists.prefix(5)))

        // Score all catalog tracks
        var scoredTracks: [(track: Track, score: Double)] = []

        for track in musicService.songs {
            // Skip tracks already in playlist
            guard !playlistS3Keys.contains(track.s3Key) else { continue }

            let score = calculateTrackScore(
                track: track,
                seedArtists: seedArtists,
                similarArtistsMap: similarArtistsMap,
                seedGenres: seedGenres,
                seedMoods: seedMoods,
                seedStyles: seedStyles
            )

            if score > 0 {
                scoredTracks.append((track, score))
            }
        }

        // Sort by score and return top results
        return scoredTracks
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0.track }
    }

    // MARK: - Seed Extraction

    private func extractSeedArtists(from tracks: [PlaylistTrackEntity]) -> Set<String> {
        Set(tracks.compactMap { $0.artistName?.lowercased() })
    }

    private func extractSeedGenres(
        from tracks: [PlaylistTrackEntity],
        using lookup: [String: Track]
    ) -> Set<String> {
        var genres = Set<String>()
        for trackEntity in tracks {
            guard let s3Key = trackEntity.trackS3Key,
                  let track = lookup[s3Key],
                  let genre = track.genre?.lowercased() else { continue }
            genres.insert(genre)
        }
        return genres
    }

    private func extractSeedMoods(
        from tracks: [PlaylistTrackEntity],
        using lookup: [String: Track]
    ) -> Set<String> {
        var moods = Set<String>()
        for trackEntity in tracks {
            guard let s3Key = trackEntity.trackS3Key,
                  let track = lookup[s3Key],
                  let mood = track.mood?.lowercased() else { continue }
            moods.insert(mood)
        }
        return moods
    }

    private func extractSeedStyles(
        from tracks: [PlaylistTrackEntity],
        using lookup: [String: Track]
    ) -> Set<String> {
        var styles = Set<String>()
        for trackEntity in tracks {
            guard let s3Key = trackEntity.trackS3Key,
                  let track = lookup[s3Key],
                  let style = track.style?.lowercased() else { continue }
            styles.insert(style)
        }
        return styles
    }

    // MARK: - Similar Artists

    private func fetchSimilarArtists(for artists: [String]) async -> [String: [SimilarArtist]] {
        var result: [String: [SimilarArtist]] = [:]

        for artist in artists {
            let similar = await LastFMSimilarService.shared.fetchSimilarArtists(for: artist)
            result[artist.lowercased()] = similar
        }

        return result
    }

    // MARK: - Scoring

    private func calculateTrackScore(
        track: Track,
        seedArtists: Set<String>,
        similarArtistsMap: [String: [SimilarArtist]],
        seedGenres: Set<String>,
        seedMoods: Set<String>,
        seedStyles: Set<String>
    ) -> Double {
        var score: Double = 0

        let trackArtist = track.artist?.lowercased() ?? ""
        let trackGenre = track.genre?.lowercased() ?? ""
        let trackMood = track.mood?.lowercased() ?? ""
        let trackStyle = track.style?.lowercased() ?? ""

        // Same artist bonus (+0.6)
        if seedArtists.contains(trackArtist) {
            score += 0.6
        }

        // Similar artist match (+1.2 * match score)
        for (_, similarArtists) in similarArtistsMap {
            if let match = similarArtists.first(where: { $0.name.lowercased() == trackArtist }) {
                score += 1.2 * match.match
                break
            }
        }

        // Affinity score from play history (+1.0)
        // Check affinity with tracks in the playlist
        let affinityService = AffinityService.shared
        for seedArtist in seedArtists {
            let affinity = affinityService.affinityScore(from: track.s3Key, to: seedArtist)
            if affinity > 0 {
                score += min(affinity, 1.0)
                break
            }
        }

        // Genre match (+0.8)
        if !trackGenre.isEmpty && seedGenres.contains(trackGenre) {
            score += 0.8
        }

        // Mood match (+0.3)
        if !trackMood.isEmpty && seedMoods.contains(trackMood) {
            score += 0.3
        }

        // Style match (+0.4)
        if !trackStyle.isEmpty && seedStyles.contains(trackStyle) {
            score += 0.4
        }

        return score
    }
}
