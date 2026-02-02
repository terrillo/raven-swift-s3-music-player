//
//  AffinityService.swift
//  Music
//
//  Analyzes co-play patterns from play history to build affinity scores
//  between tracks. Used by RadioService for Layer 2 scoring.
//

import Foundation

@MainActor
class AffinityService {
    static let shared = AffinityService()

    // Configuration
    private enum Config {
        static let halfLifeDays: Double = 45  // Time decay half-life
        static let cacheValiditySeconds: TimeInterval = 300  // 5 minutes
    }

    // Affinity map: [trackS3Key: [relatedTrackS3Key: score]]
    private var affinityMap: [String: [String: Double]] = [:]
    private var lastBuildTime: Date?

    private init() {}

    // MARK: - Public API

    /// Get affinity score between two tracks (0.0-1.0)
    /// Higher scores indicate tracks are frequently played together
    func affinityScore(from sourceKey: String, to targetKey: String) -> Double {
        rebuildIfNeeded()

        // Bidirectional: check both A->B and B->A
        let forwardScore = affinityMap[sourceKey]?[targetKey] ?? 0.0
        let reverseScore = affinityMap[targetKey]?[sourceKey] ?? 0.0

        // Combine scores (average of both directions)
        return min((forwardScore + reverseScore) / 2.0, 1.0)
    }

    /// Get all tracks with affinity to a source track, sorted by score
    func relatedTracks(to sourceKey: String, limit: Int = 50) -> [(s3Key: String, score: Double)] {
        rebuildIfNeeded()

        var combinedScores: [String: Double] = [:]

        // Add forward scores
        if let forward = affinityMap[sourceKey] {
            for (key, score) in forward {
                combinedScores[key, default: 0] += score
            }
        }

        // Add reverse scores (tracks that led to this one)
        for (otherKey, relations) in affinityMap {
            if let score = relations[sourceKey] {
                combinedScores[otherKey, default: 0] += score
            }
        }

        return combinedScores
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { ($0.key, min($0.value, 1.0)) }
    }

    /// Force rebuild of affinity map
    func rebuild() {
        buildAffinityMap()
    }

    /// Invalidate cache to force rebuild on next query
    func invalidate() {
        lastBuildTime = nil
    }

    // MARK: - Private Methods

    private func rebuildIfNeeded() {
        // Check if cache is still valid
        if let lastBuild = lastBuildTime,
           Date().timeIntervalSince(lastBuild) < Config.cacheValiditySeconds {
            return
        }

        buildAffinityMap()
    }

    private func buildAffinityMap() {
        let now = Date()

        // Fetch all co-play pairs from analytics
        let pairs = AnalyticsStore.shared.fetchCoPlayPairs()

        // Build raw counts with time decay
        var rawCounts: [String: [String: Double]] = [:]

        for pair in pairs {
            // Calculate time decay weight
            let daysSince = max(0, Calendar.current.dateComponents([.day], from: pair.playedAt, to: now).day ?? 0)
            let decayWeight = pow(0.5, Double(daysSince) / Config.halfLifeDays)

            // Add to forward relationship (previous -> current)
            rawCounts[pair.previous, default: [:]][pair.current, default: 0] += decayWeight
        }

        // Normalize scores to 0.0-1.0 range
        var normalized: [String: [String: Double]] = [:]

        for (sourceKey, relations) in rawCounts {
            guard !relations.isEmpty else { continue }

            let maxScore = relations.values.max() ?? 1.0
            var normalizedRelations: [String: Double] = [:]

            for (targetKey, score) in relations {
                normalizedRelations[targetKey] = maxScore > 0 ? score / maxScore : 0
            }

            normalized[sourceKey] = normalizedRelations
        }

        affinityMap = normalized
        lastBuildTime = Date()

        print("Built affinity map: \(affinityMap.count) source tracks, \(pairs.count) co-play pairs")
    }
}
