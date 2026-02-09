//
//  StatisticsService.swift
//  Music
//

import Foundation
import CoreData

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
    nonisolated static func buildTrackLookup(from songs: [Track]) -> [String: Track] {
        Dictionary(uniqueKeysWithValues: songs.map { ($0.s3Key, $0) })
    }

    // Compute genre breakdown from play events (pure computation, no Core Data access)
    nonisolated static func computeGenreStats(
        playCounts: [String: (count: Int, duration: TimeInterval)],
        limit: Int = 10
    ) -> [GenreStats] {
        return playCounts
            .map { GenreStats(genre: $0.key, playCount: $0.value.count, totalDuration: $0.value.duration) }
            .sorted { $0.playCount > $1.playCount }
            .prefix(limit)
            .map { $0 }
    }

    // Compute artist stats from aggregated data (pure computation)
    nonisolated static func computeArtistStats(
        artistCounts: [String: Int],
        limit: Int = 10
    ) -> [ArtistStats] {
        return artistCounts
            .map { ArtistStats(artistName: $0.key, playCount: $0.value) }
            .sorted { $0.playCount > $1.playCount }
            .prefix(limit)
            .map { $0 }
    }

    // Compute full statistics for a period — async, uses background Core Data context
    static func computeStats(
        for period: TimePeriod,
        songs: [Track]
    ) async -> ListeningStats {
        let trackLookup = buildTrackLookup(from: songs)
        let container = AnalyticsStore.shared.container

        return await Task.detached {
            let bgContext = container.newBackgroundContext()
            bgContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

            return await bgContext.perform {
                // Fetch play events
                let request = NSFetchRequest<PlayEventEntity>(entityName: "PlayEventEntity")
                if let startDate = period.startDate {
                    request.predicate = NSPredicate(format: "playedAt >= %@", startDate as NSDate)
                }
                request.sortDescriptors = [NSSortDescriptor(keyPath: \PlayEventEntity.playedAt, ascending: false)]
                let events = (try? bgContext.fetch(request)) ?? []

                let totalPlays = events.count
                let totalListeningTime = events.reduce(0) { $0 + $1.duration }
                let uniqueTracks = Set(events.compactMap { $0.trackS3Key }).count

                // Aggregate genre stats
                var genreCounts: [String: (count: Int, duration: TimeInterval)] = [:]
                for event in events {
                    guard let s3Key = event.trackS3Key,
                          let track = trackLookup[s3Key],
                          let genre = Genre.normalize(track.genre) else { continue }
                    let existing = genreCounts[genre] ?? (0, 0)
                    genreCounts[genre] = (existing.count + 1, existing.duration + event.duration)
                }
                let topGenres = computeGenreStats(playCounts: genreCounts)

                // Aggregate artist stats
                var artistCounts: [String: Int] = [:]
                for event in events {
                    guard let artistName = event.artistName, !artistName.isEmpty else { continue }
                    artistCounts[artistName, default: 0] += 1
                }
                let topArtists = computeArtistStats(artistCounts: artistCounts)

                // Compute plays by day from the already-fetched events
                let calendar = Calendar.current
                var countsByDay: [Date: Int] = [:]
                for event in events {
                    guard let playedAt = event.playedAt else { continue }
                    let day = calendar.startOfDay(for: playedAt)
                    countsByDay[day, default: 0] += 1
                }
                let playsByDay = countsByDay
                    .sorted { $0.key < $1.key }
                    .map { ($0.key, $0.value) }

                return ListeningStats(
                    totalPlays: totalPlays,
                    totalListeningTime: totalListeningTime,
                    uniqueTracks: uniqueTracks,
                    topGenres: topGenres,
                    topArtists: topArtists,
                    playsByDay: playsByDay
                )
            }
        }.value
    }
}
