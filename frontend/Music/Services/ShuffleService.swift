//
//  ShuffleService.swift
//  Music
//

import Foundation

struct TrackWeight {
    let track: Track
    let weight: Double
}

/// Context for smart shuffle decisions
struct ShuffleContext {
    var recentArtists: [String] = []      // Last N artists played
    var recentAlbums: [String] = []       // Last N albums played
    var sessionPlayed: Set<String> = []   // All tracks played this session
    var lastPlayedGenre: String? = nil    // Genre of last track
    var lastPlayedMood: String? = nil     // Mood of last track
}

@MainActor
class ShuffleService {

    // MARK: - Weight Configuration

    private enum WeightConfig {
        // Base weights by play count
        static let neverPlayed: Double = 10.0      // 0 plays
        static let rarelyPlayed: Double = 7.0      // 1-2 plays
        static let normalPlay: Double = 5.0        // 3-10 plays
        static let frequentPlay: Double = 3.0      // 11+ plays

        // Skip penalties
        static let skipDecayBase: Double = 0.3     // Per skip multiplier (0.3^n)
        static let recentSkipMultiplier: Double = 0.5  // Additional penalty for < 24h
        static let minimumWeight: Double = 0.1     // Never completely excluded

        // Recent skip threshold
        static let recentSkipHours: Int = 24

        // Artist diversity
        static let sameArtistPenalty: Double = 0.3      // Recent artist penalty
        static let artistRecencyWindow: Int = 5         // Last N tracks to check

        // Album spread
        static let sameAlbumPenalty: Double = 0.5       // Recent album penalty

        // Session memory
        static let sessionRepeatPenalty: Double = 0.1   // Heavily penalize repeats

        // Rediscovery
        static let rediscoveryBoostDays: Int = 30       // Boost after N days
        static let rediscoveryMultiplier: Double = 1.5  // Boost amount

        // Genre/Mood continuity
        static let genreMatchBoost: Double = 1.5        // Same genre boost
        static let moodMatchBoost: Double = 1.3         // Same mood boost

        // Completion rate
        static let lowCompletionThreshold: Double = 0.7 // Below this = penalty
        static let completionPenaltyBase: Double = 0.5  // Base penalty for low completion

        // Time of day
        static let timeOfDayBoost: Double = 1.2         // Boost for time-appropriate tracks
        static let timeOfDayNormalizeThreshold: Double = 5.0  // Plays needed for full boost
    }

    // MARK: - Public Methods

    /// Calculate weights for all tracks based on play history and context
    func calculateWeights(
        for tracks: [Track],
        context: ShuffleContext = ShuffleContext()
    ) -> [TrackWeight] {
        guard !tracks.isEmpty else { return [] }

        let trackKeys = Set(tracks.map { $0.s3Key })

        // Fetch all analytics data
        let playCounts = AnalyticsStore.shared.fetchPlayCounts(for: trackKeys)
        let skipData = AnalyticsStore.shared.fetchRecentSkips(for: trackKeys)
        let lastPlayDates = AnalyticsStore.shared.fetchLastPlayDates(for: trackKeys)
        let completionRates = AnalyticsStore.shared.fetchCompletionRates(for: trackKeys)
        let timeOfDayScores = AnalyticsStore.shared.fetchTimeOfDayPreferences(for: trackKeys)

        return tracks.map { track in
            let weight = calculateWeight(
                for: track,
                playCount: playCounts[track.s3Key] ?? 0,
                skipData: skipData[track.s3Key],
                lastPlayDate: lastPlayDates[track.s3Key],
                completionRate: completionRates[track.s3Key],
                timeOfDayScore: timeOfDayScores[track.s3Key],
                context: context
            )
            return TrackWeight(track: track, weight: weight)
        }
    }

    /// Select next track using weighted random selection with smart shuffle
    func selectNextTrack(
        from queue: [Track],
        excluding currentTrack: Track?,
        context: ShuffleContext = ShuffleContext(),
        playableFilter: (Track) -> Bool
    ) -> Track? {
        // Filter to playable tracks, excluding current
        let candidates = queue.filter { track in
            playableFilter(track) && track.id != currentTrack?.id
        }

        guard !candidates.isEmpty else { return nil }

        let weights = calculateWeights(for: candidates, context: context)
        return weightedRandomSelect(from: weights)
    }

    // MARK: - Private Methods

    private func calculateWeight(
        for track: Track,
        playCount: Int,
        skipData: (count: Int, mostRecent: Date?)?,
        lastPlayDate: Date?,
        completionRate: Double?,
        timeOfDayScore: Double?,
        context: ShuffleContext
    ) -> Double {
        // Favorites get same weight as frequently played tracks
        let isFavorite = FavoritesStore.shared.isTrackFavorite(track.s3Key)
        var weight = isFavorite ? WeightConfig.frequentPlay : baseWeight(for: playCount)

        // 1. Skip penalty (existing)
        let skipCount = skipData?.count ?? 0
        if skipCount > 0 {
            // Exponential decay: 0.3^n
            let skipPenalty = pow(WeightConfig.skipDecayBase, Double(skipCount))
            weight *= skipPenalty

            // Additional penalty for recent skips (< 24 hours)
            if let mostRecent = skipData?.mostRecent, isRecent(mostRecent) {
                weight *= WeightConfig.recentSkipMultiplier
            }
        }

        // 2. Artist diversity penalty
        if let artist = track.artist, !context.recentArtists.isEmpty {
            if let recencyIndex = context.recentArtists.firstIndex(of: artist) {
                // More recent = stronger penalty (index 0 = most recent)
                let recency = recencyIndex + 1
                weight *= pow(WeightConfig.sameArtistPenalty, Double(WeightConfig.artistRecencyWindow - recency + 1) / Double(WeightConfig.artistRecencyWindow))
            }
        }

        // 3. Album spread penalty
        if let album = track.album, context.recentAlbums.contains(album) {
            weight *= WeightConfig.sameAlbumPenalty
        }

        // 4. Session repeat penalty (strong)
        if context.sessionPlayed.contains(track.s3Key) {
            weight *= WeightConfig.sessionRepeatPenalty
        }

        // 5. Rediscovery boost for tracks not played in 30+ days
        if let lastPlayed = lastPlayDate {
            let daysSince = Calendar.current.dateComponents([.day], from: lastPlayed, to: Date()).day ?? 0
            if daysSince > WeightConfig.rediscoveryBoostDays {
                weight *= WeightConfig.rediscoveryMultiplier
            }
        }

        // 6. Genre continuity boost
        if let currentGenre = context.lastPlayedGenre,
           let trackGenre = Genre.normalize(track.genre),
           trackGenre == currentGenre {
            weight *= WeightConfig.genreMatchBoost
        }

        // 7. Mood continuity boost
        if let currentMood = context.lastPlayedMood,
           let trackMood = track.mood,
           trackMood == currentMood {
            weight *= WeightConfig.moodMatchBoost
        }

        // 8. Completion rate penalty
        if let avgCompletion = completionRate, avgCompletion < WeightConfig.lowCompletionThreshold {
            // Scale 0.5-0.85 based on completion
            weight *= (WeightConfig.completionPenaltyBase + avgCompletion * WeightConfig.completionPenaltyBase)
        }

        // 9. Time-of-day boost
        if let timeScore = timeOfDayScore, timeScore > 0 {
            // Gradually increase boost based on how often this track is played at this time
            let normalizedScore = min(timeScore / WeightConfig.timeOfDayNormalizeThreshold, 1.0)
            weight *= (1.0 + (WeightConfig.timeOfDayBoost - 1.0) * normalizedScore)
        }

        // Ensure minimum weight (never completely excluded)
        return max(weight, WeightConfig.minimumWeight)
    }

    private func baseWeight(for playCount: Int) -> Double {
        switch playCount {
        case 0:
            return WeightConfig.neverPlayed
        case 1...2:
            return WeightConfig.rarelyPlayed
        case 3...10:
            return WeightConfig.normalPlay
        default:
            return WeightConfig.frequentPlay
        }
    }

    private func isRecent(_ date: Date) -> Bool {
        let threshold = Calendar.current.date(
            byAdding: .hour,
            value: -WeightConfig.recentSkipHours,
            to: Date()
        ) ?? Date()
        return date > threshold
    }

    private func weightedRandomSelect(from weights: [TrackWeight]) -> Track? {
        guard !weights.isEmpty else { return nil }

        let totalWeight = weights.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else {
            // Fallback to random if all weights are zero
            return weights.randomElement()?.track
        }

        var randomValue = Double.random(in: 0..<totalWeight)

        for trackWeight in weights {
            randomValue -= trackWeight.weight
            if randomValue <= 0 {
                return trackWeight.track
            }
        }

        // Fallback (should not reach here)
        return weights.last?.track
    }
}
