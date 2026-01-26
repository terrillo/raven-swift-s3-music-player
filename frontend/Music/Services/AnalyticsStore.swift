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

    func recordPlay(track: Track, duration: TimeInterval) {
        let event = PlayEventEntity(context: viewContext)
        event.trackS3Key = track.s3Key
        event.trackTitle = track.title
        event.artistName = track.artist
        event.playedAt = Date()
        event.duration = duration

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
