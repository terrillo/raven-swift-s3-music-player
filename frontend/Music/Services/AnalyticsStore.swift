//
//  AnalyticsStore.swift
//  Music
//

import CoreData
import CloudKit

// MARK: - Time Period

enum TimePeriod: String, CaseIterable, Identifiable {
    case week = "This Week"
    case month = "This Month"
    case allTime = "All Time"

    var id: String { rawValue }

    var startDate: Date? {
        let calendar = Calendar.current
        switch self {
        case .week:
            return calendar.date(byAdding: .day, value: -7, to: Date())
        case .month:
            return calendar.date(byAdding: .month, value: -1, to: Date())
        case .allTime:
            return nil
        }
    }
}

@MainActor
class AnalyticsStore {
    static let shared = AnalyticsStore()

    let container: NSPersistentCloudKitContainer
    var viewContext: NSManagedObjectContext { container.viewContext }

    /// Indicates if analytics is available (Core Data loaded successfully)
    private(set) var isAvailable = false

    private init() {
        container = NSPersistentCloudKitContainer(name: "MusicDB")

        // Configure for CloudKit (gracefully handle missing store description)
        if let description = container.persistentStoreDescriptions.first {
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: "iCloud.com.terrillo.Music"
            )
        } else {
            print("⚠️ No store description found - analytics will be disabled")
        }

        container.loadPersistentStores { [weak self] description, error in
            if let error = error {
                print("❌ Core Data error: \(error)")
                // Analytics disabled but app continues to function
            } else {
                print("✅ Core Data + CloudKit loaded successfully")
                Task { @MainActor in
                    self?.isAvailable = true
                }
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    // MARK: - Record Events

    func recordPlay(track: Track, duration: TimeInterval, trackDuration: TimeInterval? = nil, previousTrackS3Key: String? = nil) {
        guard isAvailable else { return }

        // Capture values for background context
        let s3Key = track.s3Key
        let title = track.title
        let artist = track.artist
        let completionRate: Double
        if let totalDuration = trackDuration, totalDuration > 0 {
            completionRate = min(duration / totalDuration, 1.0)
        } else {
            completionRate = 1.0
        }

        let container = self.container
        Task.detached {
            let bgContext = container.newBackgroundContext()
            bgContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            await bgContext.perform {
                let event = PlayEventEntity(context: bgContext)
                event.trackS3Key = s3Key
                event.trackTitle = title
                event.artistName = artist
                event.playedAt = Date()
                event.duration = duration
                event.previousTrackS3Key = previousTrackS3Key
                event.completionRate = completionRate

                do {
                    try bgContext.save()
                } catch {
                    print("Failed to save play event: \(error)")
                }
            }
        }
    }

    func recordSkip(track: Track, playedDuration: TimeInterval) {
        guard isAvailable else { return }

        let s3Key = track.s3Key
        let title = track.title
        let artist = track.artist

        let container = self.container
        Task.detached {
            let bgContext = container.newBackgroundContext()
            bgContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            await bgContext.perform {
                let event = SkipEventEntity(context: bgContext)
                event.trackS3Key = s3Key
                event.trackTitle = title
                event.artistName = artist
                event.skippedAt = Date()
                event.playedDuration = playedDuration

                do {
                    try bgContext.save()
                } catch {
                    print("Failed to save skip event: \(error)")
                }
            }
        }
    }

    // MARK: - Fetch Top Tracks

    func fetchTopTracks(limit: Int = 100) -> [(s3Key: String, count: Int)] {
        fetchTopTracks(limit: limit, period: .allTime)
    }

    func fetchTopTracks(limit: Int = 100, period: TimePeriod) -> [(s3Key: String, count: Int)] {
        let request = NSFetchRequest<PlayEventEntity>(entityName: "PlayEventEntity")

        if let startDate = period.startDate {
            request.predicate = NSPredicate(format: "playedAt >= %@", startDate as NSDate)
        }

        guard let events = try? viewContext.fetch(request) else {
            return []
        }

        // Count plays per track
        var counts: [String: Int] = [:]
        for event in events {
            guard let key = event.trackS3Key else { continue }
            counts[key, default: 0] += 1
        }

        // Sort by count and take top N
        return counts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { ($0.key, $0.value) }
    }

    // MARK: - Fetch Play Events

    func fetchPlayEvents(period: TimePeriod = .allTime) -> [PlayEventEntity] {
        let request = NSFetchRequest<PlayEventEntity>(entityName: "PlayEventEntity")

        if let startDate = period.startDate {
            request.predicate = NSPredicate(format: "playedAt >= %@", startDate as NSDate)
        }
        request.sortDescriptors = [NSSortDescriptor(keyPath: \PlayEventEntity.playedAt, ascending: false)]

        return (try? viewContext.fetch(request)) ?? []
    }

    // MARK: - Recently Played

    /// Returns unique recently played track keys with their most recent play date.
    /// Deduplicates by s3Key, keeping the most recent play event for each track.
    /// Results are sorted newest-first. Pass `limit: 0` for no limit.
    func fetchRecentlyPlayedTracks(limit: Int = 0) -> [(s3Key: String, playedAt: Date)] {
        let request = NSFetchRequest<PlayEventEntity>(entityName: "PlayEventEntity")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \PlayEventEntity.playedAt, ascending: false)]

        guard let events = try? viewContext.fetch(request) else { return [] }

        var seen = Set<String>()
        var result: [(s3Key: String, playedAt: Date)] = []
        for event in events {
            guard let s3Key = event.trackS3Key,
                  let playedAt = event.playedAt,
                  !seen.contains(s3Key) else { continue }
            seen.insert(s3Key)
            result.append((s3Key: s3Key, playedAt: playedAt))
            if limit > 0 && result.count >= limit { break }
        }
        return result
    }

    // MARK: - Statistics Methods

    func fetchTotalListeningTime(period: TimePeriod = .allTime) -> TimeInterval {
        let events = fetchPlayEvents(period: period)
        return events.reduce(0) { $0 + $1.duration }
    }

    func fetchTotalPlayCount(period: TimePeriod = .allTime) -> Int {
        let request = NSFetchRequest<PlayEventEntity>(entityName: "PlayEventEntity")

        if let startDate = period.startDate {
            request.predicate = NSPredicate(format: "playedAt >= %@", startDate as NSDate)
        }

        return (try? viewContext.count(for: request)) ?? 0
    }

    func fetchPlayCountByDay(period: TimePeriod = .month) -> [(date: Date, count: Int)] {
        let events = fetchPlayEvents(period: period)
        let calendar = Calendar.current
        var countsByDay: [Date: Int] = [:]

        for event in events {
            guard let playedAt = event.playedAt else { continue }
            let day = calendar.startOfDay(for: playedAt)
            countsByDay[day, default: 0] += 1
        }

        return countsByDay
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    // MARK: - Shuffle Statistics

    /// Returns play counts for a set of track keys (all-time)
    func fetchPlayCounts(for trackKeys: Set<String>) -> [String: Int] {
        let request = NSFetchRequest<PlayEventEntity>(entityName: "PlayEventEntity")
        request.predicate = NSPredicate(format: "trackS3Key IN %@", trackKeys)
        guard let events = try? viewContext.fetch(request) else { return [:] }

        var counts: [String: Int] = [:]
        for event in events {
            guard let key = event.trackS3Key else { continue }
            counts[key, default: 0] += 1
        }
        return counts
    }

    /// Returns recent skip data (last 7 days) for track keys
    func fetchRecentSkips(for trackKeys: Set<String>, withinDays: Int = 7) -> [String: (count: Int, mostRecent: Date?)] {
        let request = NSFetchRequest<SkipEventEntity>(entityName: "SkipEventEntity")
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -withinDays, to: Date()) ?? Date()
        request.predicate = NSPredicate(format: "skippedAt >= %@", cutoffDate as NSDate)

        guard let events = try? viewContext.fetch(request) else { return [:] }

        var skips: [String: (count: Int, mostRecent: Date?)] = [:]
        for event in events {
            guard let key = event.trackS3Key, trackKeys.contains(key) else { continue }
            let existing = skips[key] ?? (0, nil)
            let mostRecent: Date? = {
                guard let eventDate = event.skippedAt else { return existing.mostRecent }
                guard let existingDate = existing.mostRecent else { return eventDate }
                return eventDate > existingDate ? eventDate : existingDate
            }()
            skips[key] = (existing.count + 1, mostRecent)
        }
        return skips
    }

    // MARK: - Smart Shuffle Statistics

    /// Returns most recent play date for each track
    func fetchLastPlayDates(for trackKeys: Set<String>) -> [String: Date] {
        let request = NSFetchRequest<PlayEventEntity>(entityName: "PlayEventEntity")
        request.predicate = NSPredicate(format: "trackS3Key IN %@", trackKeys)
        guard let events = try? viewContext.fetch(request) else { return [:] }

        var lastPlayed: [String: Date] = [:]
        for event in events {
            guard let key = event.trackS3Key,
                  let date = event.playedAt,
                  trackKeys.contains(key) else { continue }
            if lastPlayed[key] == nil || date > lastPlayed[key]! {
                lastPlayed[key] = date
            }
        }
        return lastPlayed
    }

    /// Returns average completion rate for tracks (0.0 to 1.0)
    func fetchCompletionRates(for trackKeys: Set<String>) -> [String: Double] {
        let request = NSFetchRequest<PlayEventEntity>(entityName: "PlayEventEntity")
        request.predicate = NSPredicate(format: "trackS3Key IN %@", trackKeys)
        guard let events = try? viewContext.fetch(request) else { return [:] }

        var totals: [String: (sum: Double, count: Int)] = [:]
        for event in events {
            guard let key = event.trackS3Key, trackKeys.contains(key) else { continue }
            let existing = totals[key] ?? (0.0, 0)
            totals[key] = (existing.sum + event.completionRate, existing.count + 1)
        }

        var averages: [String: Double] = [:]
        for (key, data) in totals {
            averages[key] = data.count > 0 ? data.sum / Double(data.count) : 1.0
        }
        return averages
    }

    /// Returns tracks most played during current time period (morning/afternoon/evening/night)
    func fetchTimeOfDayPreferences(for trackKeys: Set<String>) -> [String: Double] {
        let hour = Calendar.current.component(.hour, from: Date())
        let periodRange: (start: Int, end: Int) = {
            switch hour {
            case 5..<12: return (5, 12)      // Morning
            case 12..<17: return (12, 17)    // Afternoon
            case 17..<21: return (17, 21)    // Evening
            default: return (21, 5)          // Night (wraps)
            }
        }()

        let request = NSFetchRequest<PlayEventEntity>(entityName: "PlayEventEntity")
        request.predicate = NSPredicate(format: "trackS3Key IN %@", trackKeys)
        guard let events = try? viewContext.fetch(request) else { return [:] }

        var counts: [String: Int] = [:]
        let calendar = Calendar.current

        for event in events {
            guard let key = event.trackS3Key,
                  let playedAt = event.playedAt,
                  trackKeys.contains(key) else { continue }

            let eventHour = calendar.component(.hour, from: playedAt)

            // Check if event hour falls within the period
            let inPeriod: Bool
            if periodRange.start < periodRange.end {
                // Normal range (e.g., 5..<12)
                inPeriod = eventHour >= periodRange.start && eventHour < periodRange.end
            } else {
                // Wrapping range (e.g., 21..<5 means 21-23 or 0-4)
                inPeriod = eventHour >= periodRange.start || eventHour < periodRange.end
            }

            if inPeriod {
                counts[key, default: 0] += 1
            }
        }

        // Normalize to scores (higher count = higher score)
        var scores: [String: Double] = [:]
        for (key, count) in counts {
            scores[key] = Double(count)
        }
        return scores
    }

    // MARK: - Batch Analytics for ShuffleService

    struct AnalyticsBatch {
        var playCounts: [String: Int] = [:]
        var skipData: [String: (count: Int, mostRecent: Date?)] = [:]
        var lastPlayDates: [String: Date] = [:]
        var completionRates: [String: Double] = [:]
        var timeOfDayScores: [String: Double] = [:]
    }

    /// Fetch all analytics needed by ShuffleService in a single batch (fewer DB queries)
    func fetchAllAnalytics(for trackKeys: Set<String>) -> AnalyticsBatch {
        var batch = AnalyticsBatch()

        // Single fetch for play events
        let playRequest = NSFetchRequest<PlayEventEntity>(entityName: "PlayEventEntity")
        playRequest.predicate = NSPredicate(format: "trackS3Key IN %@", trackKeys)
        let playEvents = (try? viewContext.fetch(playRequest)) ?? []

        // Compute time-of-day period
        let hour = Calendar.current.component(.hour, from: Date())
        let periodRange: (start: Int, end: Int) = {
            switch hour {
            case 5..<12: return (5, 12)
            case 12..<17: return (12, 17)
            case 17..<21: return (17, 21)
            default: return (21, 5)
            }
        }()
        let calendar = Calendar.current

        // Single pass over play events to compute all metrics
        var completionTotals: [String: (sum: Double, count: Int)] = [:]
        for event in playEvents {
            guard let key = event.trackS3Key else { continue }

            // Play count
            batch.playCounts[key, default: 0] += 1

            // Last play date
            if let date = event.playedAt {
                if batch.lastPlayDates[key] == nil || date > batch.lastPlayDates[key]! {
                    batch.lastPlayDates[key] = date
                }

                // Time of day
                let eventHour = calendar.component(.hour, from: date)
                let inPeriod: Bool
                if periodRange.start < periodRange.end {
                    inPeriod = eventHour >= periodRange.start && eventHour < periodRange.end
                } else {
                    inPeriod = eventHour >= periodRange.start || eventHour < periodRange.end
                }
                if inPeriod {
                    batch.timeOfDayScores[key, default: 0] += 1
                }
            }

            // Completion rate
            let existing = completionTotals[key] ?? (0.0, 0)
            completionTotals[key] = (existing.sum + event.completionRate, existing.count + 1)
        }

        for (key, data) in completionTotals {
            batch.completionRates[key] = data.count > 0 ? data.sum / Double(data.count) : 1.0
        }

        // Single fetch for skip events
        let skipRequest = NSFetchRequest<SkipEventEntity>(entityName: "SkipEventEntity")
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        skipRequest.predicate = NSPredicate(format: "trackS3Key IN %@ AND skippedAt >= %@", trackKeys, cutoffDate as NSDate)
        let skipEvents = (try? viewContext.fetch(skipRequest)) ?? []

        for event in skipEvents {
            guard let key = event.trackS3Key else { continue }
            let existing = batch.skipData[key] ?? (0, nil)
            let mostRecent: Date? = {
                guard let eventDate = event.skippedAt else { return existing.mostRecent }
                guard let existingDate = existing.mostRecent else { return eventDate }
                return eventDate > existingDate ? eventDate : existingDate
            }()
            batch.skipData[key] = (existing.count + 1, mostRecent)
        }

        return batch
    }

    // MARK: - Background Analytics Fetch (for ShuffleService)

    /// Fetch all analytics on a background context — does not block main thread.
    /// Returns a Sendable AnalyticsBatch that can be used from any isolation context.
    nonisolated func fetchAllAnalyticsInBackground(for trackKeys: Set<String>) async -> AnalyticsBatch {
        let bgContext = container.newBackgroundContext()
        bgContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        return await bgContext.perform {
            var batch = AnalyticsBatch()

            // Single fetch for play events
            let playRequest = NSFetchRequest<PlayEventEntity>(entityName: "PlayEventEntity")
            playRequest.predicate = NSPredicate(format: "trackS3Key IN %@", trackKeys)
            let playEvents = (try? bgContext.fetch(playRequest)) ?? []

            // Compute time-of-day period
            let hour = Calendar.current.component(.hour, from: Date())
            let periodRange: (start: Int, end: Int) = {
                switch hour {
                case 5..<12: return (5, 12)
                case 12..<17: return (12, 17)
                case 17..<21: return (17, 21)
                default: return (21, 5)
                }
            }()
            let calendar = Calendar.current

            // Single pass over play events to compute all metrics
            var completionTotals: [String: (sum: Double, count: Int)] = [:]
            for event in playEvents {
                guard let key = event.trackS3Key else { continue }

                batch.playCounts[key, default: 0] += 1

                if let date = event.playedAt {
                    if batch.lastPlayDates[key] == nil || date > batch.lastPlayDates[key]! {
                        batch.lastPlayDates[key] = date
                    }

                    let eventHour = calendar.component(.hour, from: date)
                    let inPeriod: Bool
                    if periodRange.start < periodRange.end {
                        inPeriod = eventHour >= periodRange.start && eventHour < periodRange.end
                    } else {
                        inPeriod = eventHour >= periodRange.start || eventHour < periodRange.end
                    }
                    if inPeriod {
                        batch.timeOfDayScores[key, default: 0] += 1
                    }
                }

                let existing = completionTotals[key] ?? (0.0, 0)
                completionTotals[key] = (existing.sum + event.completionRate, existing.count + 1)
            }

            for (key, data) in completionTotals {
                batch.completionRates[key] = data.count > 0 ? data.sum / Double(data.count) : 1.0
            }

            // Single fetch for skip events
            let skipRequest = NSFetchRequest<SkipEventEntity>(entityName: "SkipEventEntity")
            let cutoffDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            skipRequest.predicate = NSPredicate(format: "trackS3Key IN %@ AND skippedAt >= %@", trackKeys, cutoffDate as NSDate)
            let skipEvents = (try? bgContext.fetch(skipRequest)) ?? []

            for event in skipEvents {
                guard let key = event.trackS3Key else { continue }
                let existing = batch.skipData[key] ?? (0, nil)
                let mostRecent: Date? = {
                    guard let eventDate = event.skippedAt else { return existing.mostRecent }
                    guard let existingDate = existing.mostRecent else { return eventDate }
                    return eventDate > existingDate ? eventDate : existingDate
                }()
                batch.skipData[key] = (existing.count + 1, mostRecent)
            }

            return batch
        }
    }

    // MARK: - Co-Play Pairs for Affinity

    /// Returns co-play pairs (previousTrack -> currentTrack) for affinity analysis
    /// Each pair represents a track that was played after another track
    func fetchCoPlayPairs(since date: Date? = nil) -> [(previous: String, current: String, playedAt: Date)] {
        let request = NSFetchRequest<PlayEventEntity>(entityName: "PlayEventEntity")

        if let startDate = date {
            request.predicate = NSPredicate(format: "playedAt >= %@ AND previousTrackS3Key != nil", startDate as NSDate)
        } else {
            request.predicate = NSPredicate(format: "previousTrackS3Key != nil")
        }

        guard let events = try? viewContext.fetch(request) else { return [] }

        return events.compactMap { event in
            guard let previous = event.previousTrackS3Key,
                  let current = event.trackS3Key,
                  let playedAt = event.playedAt else { return nil }
            return (previous: previous, current: current, playedAt: playedAt)
        }
    }

    // MARK: - Clear All Data

    func clearAllData() {
        let playRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "PlayEventEntity")
        let skipRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "SkipEventEntity")

        let playDelete = NSBatchDeleteRequest(fetchRequest: playRequest)
        let skipDelete = NSBatchDeleteRequest(fetchRequest: skipRequest)

        do {
            try viewContext.execute(playDelete)
            try viewContext.execute(skipDelete)
            try viewContext.save()
            print("✅ Analytics data cleared successfully")
        } catch {
            print("❌ Failed to clear analytics: \(error)")
        }
    }
}
