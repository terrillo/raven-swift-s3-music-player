//
//  StatisticsService.swift
//  Music
//

import Foundation

// MARK: - Data Structures

struct GenreStats: Identifiable {
    let id = UUID()
    let genre: String
    let playCount: Int
    let totalDuration: TimeInterval
}

struct ArtistStats: Identifiable {
    let id = UUID()
    let artistName: String
    let playCount: Int
}

struct ListeningStats {
    let totalPlays: Int
    let totalListeningTime: TimeInterval
    let uniqueTracks: Int
    let topGenres: [GenreStats]
    let topArtists: [ArtistStats]
    let playsByDay: [(date: Date, count: Int)]

    var formattedListeningTime: String {
        let hours = Int(totalListeningTime) / 3600
        let minutes = (Int(totalListeningTime) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

// MARK: - Statistics Service

@MainActor
class StatisticsService {

    // Build lookup dictionary for track metadata
    static func buildTrackLookup(from songs: [Track]) -> [String: Track] {
        Dictionary(uniqueKeysWithValues: songs.map { ($0.s3Key, $0) })
    }

    // Compute genre breakdown from play events
    static func computeGenreStats(
        events: [PlayEventEntity],
        trackLookup: [String: Track],
        limit: Int = 10
    ) -> [GenreStats] {
        var genreCounts: [String: (count: Int, duration: TimeInterval)] = [:]

        for event in events {
            guard let s3Key = event.trackS3Key,
                  let track = trackLookup[s3Key],
                  let genre = Genre.normalize(track.genre) else { continue }

            let existing = genreCounts[genre] ?? (0, 0)
            genreCounts[genre] = (existing.count + 1, existing.duration + event.duration)
        }

        return genreCounts
            .map { GenreStats(genre: $0.key, playCount: $0.value.count, totalDuration: $0.value.duration) }
            .sorted { $0.playCount > $1.playCount }
            .prefix(limit)
            .map { $0 }
    }

    // Compute artist stats from play events
    static func computeArtistStats(
        events: [PlayEventEntity],
        limit: Int = 10
    ) -> [ArtistStats] {
        var artistCounts: [String: Int] = [:]

        for event in events {
            guard let artistName = event.artistName, !artistName.isEmpty else { continue }
            artistCounts[artistName, default: 0] += 1
        }

        return artistCounts
            .map { ArtistStats(artistName: $0.key, playCount: $0.value) }
            .sorted { $0.playCount > $1.playCount }
            .prefix(limit)
            .map { $0 }
    }

    // Compute full statistics for a period
    static func computeStats(
        for period: TimePeriod,
        songs: [Track]
    ) -> ListeningStats {
        let events = AnalyticsStore.shared.fetchPlayEvents(period: period)
        let trackLookup = buildTrackLookup(from: songs)

        let totalPlays = events.count
        let totalListeningTime = events.reduce(0) { $0 + $1.duration }
        let uniqueTracks = Set(events.compactMap { $0.trackS3Key }).count
        let topGenres = computeGenreStats(events: events, trackLookup: trackLookup)
        let topArtists = computeArtistStats(events: events)
        let playsByDay = AnalyticsStore.shared.fetchPlayCountByDay(period: period)

        return ListeningStats(
            totalPlays: totalPlays,
            totalListeningTime: totalListeningTime,
            uniqueTracks: uniqueTracks,
            topGenres: topGenres,
            topArtists: topArtists,
            playsByDay: playsByDay
        )
    }
}
