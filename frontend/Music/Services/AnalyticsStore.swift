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

    private init() {
        container = NSPersistentCloudKitContainer(name: "MusicDB")

        // Configure for CloudKit
        guard let description = container.persistentStoreDescriptions.first else {
            fatalError("No store description found")
        }
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
            containerIdentifier: "iCloud.com.terrillo.Music"
        )

        container.loadPersistentStores { description, error in
            if let error = error {
                print("❌ Core Data error: \(error)")
            } else {
                print("✅ Core Data + CloudKit loaded successfully")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    // MARK: - Record Events

    func recordPlay(track: Track, duration: TimeInterval, trackDuration: TimeInterval? = nil) {
        let event = PlayEventEntity(context: viewContext)
        event.trackS3Key = track.s3Key
        event.trackTitle = track.title
        event.artistName = track.artist
        event.playedAt = Date()
        event.duration = duration

        // Calculate completion rate if track duration is provided
        if let totalDuration = trackDuration, totalDuration > 0 {
            event.completionRate = min(duration / totalDuration, 1.0)
        } else {
            event.completionRate = 1.0  // Default to 100% if unknown
        }

        do {
            try viewContext.save()
        } catch {
            print("Failed to save play event: \(error)")
        }
    }

    func recordSkip(track: Track, playedDuration: TimeInterval) {
        let event = SkipEventEntity(context: viewContext)
        event.trackS3Key = track.s3Key
        event.trackTitle = track.title
        event.artistName = track.artist
        event.skippedAt = Date()
        event.playedDuration = playedDuration

        do {
            try viewContext.save()
        } catch {
            print("Failed to save skip event: \(error)")
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
        guard let events = try? viewContext.fetch(request) else { return [:] }

        var counts: [String: Int] = [:]
        for event in events {
            guard let key = event.trackS3Key, trackKeys.contains(key) else { continue }
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
