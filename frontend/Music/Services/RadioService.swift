//
//  RadioService.swift
//  Music
//
//  Orchestrates radio mode with three-layer scoring:
//  - Layer 1: Local metadata matching (genre, mood, style, theme, artist)
//  - Layer 2: Play history affinity (co-play patterns)
//  - Layer 3: Last.fm similar artists (online enhancement)
//

import Foundation

// MARK: - Radio Seed

/// Defines the starting point for radio mode
enum RadioSeed {
    case track(Track)
    case artist(Artist)
    case album(Album)
    case genre(String)
    case mood(String)

    /// Unique identifier for the seed
    var id: String {
        switch self {
        case .track(let track):
            return "track:\(track.s3Key)"
        case .artist(let artist):
            return "artist:\(artist.id)"
        case .album(let album):
            return "album:\(album.id)"
        case .genre(let genre):
            return "genre:\(genre)"
        case .mood(let mood):
            return "mood:\(mood)"
        }
    }

    var displayName: String {
        switch self {
        case .track(let track):
            return track.title
        case .artist(let artist):
            return artist.name
        case .album(let album):
            return album.name
        case .genre(let genre):
            return genre
        case .mood(let mood):
            return mood
        }
    }

    var displayType: String {
        switch self {
        case .track: return "Track"
        case .artist: return "Artist"
        case .album: return "Album"
        case .genre: return "Genre"
        case .mood: return "Mood"
        }
    }
}

// MARK: - Radio Configuration

/// Tunable weights for radio scoring
struct RadioConfiguration {
    // Layer weights
    var metadataWeight: Double = 1.0
    var affinityWeight: Double = 1.2
    var similarArtistWeight: Double = 0.8

    // Metadata scoring
    var genreMatchScore: Double = 1.0
    var moodMatchScore: Double = 0.8
    var styleMatchScore: Double = 0.6
    var themeMatchScore: Double = 0.4
    var artistMatchScore: Double = 1.5

    // Queue management
    var initialQueueSize: Int = 20
    var replenishThreshold: Int = 3
    var replenishCount: Int = 10

    static let `default` = RadioConfiguration()
}

// MARK: - Track Score

/// Represents a track with its radio score for sorting
private struct ScoredTrack {
    let track: Track
    let metadataScore: Double
    let affinityScore: Double
    let similarArtistScore: Double
    let totalScore: Double
}

// MARK: - Radio Service

@MainActor
@Observable
class RadioService {
    // Current state
    private(set) var currentSeed: RadioSeed?
    private(set) var isActive: Bool = false
    private(set) var generatedCount: Int = 0

    // Configuration
    var configuration = RadioConfiguration.default

    // Dependencies
    private weak var musicService: MusicService?
    private weak var playerService: PlayerService?
    private let shuffleService = ShuffleService()

    // Cached similar artists for current seed
    private var seedSimilarArtists: [SimilarArtist] = []
    private var seedArtistName: String?

    init(musicService: MusicService, playerService: PlayerService) {
        self.musicService = musicService
        self.playerService = playerService
    }

    // MARK: - Public API

    /// Start radio mode from a seed
    func startRadio(from seed: RadioSeed) {
        guard let musicService = musicService,
              let playerService = playerService else { return }

        currentSeed = seed
        isActive = true
        generatedCount = 0

        // Reset session tracking for fresh radio
        playerService.resetSessionTracking()

        // Pre-fetch similar artists if we have an artist seed
        Task {
            await prefetchSimilarArtists(for: seed)
        }

        // Generate initial queue
        let tracks = generateQueue(count: configuration.initialQueueSize)

        guard !tracks.isEmpty else {
            print("Radio: No tracks found for seed")
            stopRadio()
            return
        }

        // Start playing
        playerService.play(track: tracks[0], queue: tracks)
        generatedCount = tracks.count

        print("Radio started: \(seed.displayType) - \(seed.displayName) with \(tracks.count) tracks")
    }

    /// Stop radio mode
    func stopRadio() {
        currentSeed = nil
        isActive = false
        generatedCount = 0
        seedSimilarArtists = []
        seedArtistName = nil
        print("Radio stopped")
    }

    /// Check if queue needs replenishment and add more tracks
    func checkAndReplenish() {
        guard isActive,
              let playerService = playerService else { return }

        let remainingInQueue = playerService.queue.count - playerService.currentIndex - 1

        if remainingInQueue <= configuration.replenishThreshold {
            let newTracks = generateQueue(count: configuration.replenishCount)

            if !newTracks.isEmpty {
                // Append to existing queue
                var updatedQueue = playerService.queue
                updatedQueue.append(contentsOf: newTracks)
                playerService.queue = updatedQueue
                generatedCount += newTracks.count

                print("Radio replenished: added \(newTracks.count) tracks, total \(generatedCount)")
            }
        }
    }

    /// Generate a queue of tracks based on the current seed
    func generateQueue(count: Int) -> [Track] {
        guard let seed = currentSeed,
              let musicService = musicService,
              let playerService = playerService else { return [] }

        // Get all playable tracks excluding current queue
        let currentQueueKeys = Set(playerService.queue.map { $0.s3Key })
        let allTracks = musicService.songs.filter { track in
            playerService.isTrackPlayable(track) && !currentQueueKeys.contains(track.s3Key)
        }

        guard !allTracks.isEmpty else { return [] }

        // Score all tracks
        let scoredTracks = scoreTracksForSeed(allTracks, seed: seed)

        // Apply ShuffleService factors (skip penalty, completion rate, etc.)
        let context = ShuffleContext()
        let shuffleWeights = shuffleService.calculateWeights(for: scoredTracks.map { $0.track }, context: context)
        let shuffleWeightMap = Dictionary(uniqueKeysWithValues: shuffleWeights.map { ($0.track.s3Key, $0.weight) })

        // Combine radio score with shuffle weight
        var finalScored = scoredTracks.map { scored -> (track: Track, score: Double) in
            let shuffleWeight = shuffleWeightMap[scored.track.s3Key] ?? 1.0
            return (scored.track, scored.totalScore * shuffleWeight)
        }

        // Sort by score and take top candidates
        finalScored.sort { $0.score > $1.score }

        // Use weighted random selection from top candidates
        let topCandidates = Array(finalScored.prefix(count * 3))
        var selected: [Track] = []
        var remaining = topCandidates

        while selected.count < count && !remaining.isEmpty {
            if let next = weightedRandomSelect(from: remaining) {
                selected.append(next.track)
                remaining.removeAll { $0.track.s3Key == next.track.s3Key }
            } else {
                break
            }
        }

        return selected
    }

    // MARK: - Scoring

    private func scoreTracksForSeed(_ tracks: [Track], seed: RadioSeed) -> [ScoredTrack] {
        return tracks.map { track in
            let metadataScore = calculateMetadataScore(track: track, seed: seed)
            let affinityScore = calculateAffinityScore(track: track, seed: seed)
            let similarScore = calculateSimilarArtistScore(track: track, seed: seed)

            let totalScore = (metadataScore * configuration.metadataWeight) +
                            (affinityScore * configuration.affinityWeight) +
                            (similarScore * configuration.similarArtistWeight)

            return ScoredTrack(
                track: track,
                metadataScore: metadataScore,
                affinityScore: affinityScore,
                similarArtistScore: similarScore,
                totalScore: totalScore
            )
        }
    }

    /// Layer 1: Local metadata matching (0.0-4.0+)
    private func calculateMetadataScore(track: Track, seed: RadioSeed) -> Double {
        var score: Double = 0

        // Extract seed attributes
        let seedGenre: String?
        let seedMood: String?
        let seedStyle: String?
        let seedTheme: String?
        let seedArtist: String?

        switch seed {
        case .track(let seedTrack):
            seedGenre = Genre.normalize(seedTrack.genre)
            seedMood = seedTrack.mood
            seedStyle = seedTrack.style
            seedTheme = seedTrack.theme
            seedArtist = seedTrack.artist
        case .artist(let artist):
            seedGenre = Genre.normalize(artist.genre)
            seedMood = artist.mood
            seedStyle = artist.style
            seedTheme = nil
            seedArtist = artist.name
        case .album(let album):
            seedGenre = Genre.normalize(album.genre)
            seedMood = album.mood
            seedStyle = album.style
            seedTheme = album.theme
            seedArtist = album.tracks.first?.artist
        case .genre(let genre):
            seedGenre = Genre.normalize(genre)
            seedMood = nil
            seedStyle = nil
            seedTheme = nil
            seedArtist = nil
        case .mood(let mood):
            seedGenre = nil
            seedMood = mood
            seedStyle = nil
            seedTheme = nil
            seedArtist = nil
        }

        // Genre match
        if let sg = seedGenre, let tg = Genre.normalize(track.genre), sg == tg {
            score += configuration.genreMatchScore
        }

        // Mood match
        if let sm = seedMood, let tm = track.mood, sm == tm {
            score += configuration.moodMatchScore
        }

        // Style match
        if let ss = seedStyle, let ts = track.style, ss == ts {
            score += configuration.styleMatchScore
        }

        // Theme match
        if let st = seedTheme, let tt = track.theme, st == tt {
            score += configuration.themeMatchScore
        }

        // Artist match (high value for same artist)
        if let sa = seedArtist, let ta = track.artist, sa == ta {
            score += configuration.artistMatchScore
        }

        return score
    }

    /// Layer 2: Play history affinity (0.0-1.0)
    private func calculateAffinityScore(track: Track, seed: RadioSeed) -> Double {
        // Get the seed track's s3Key for affinity lookup
        let seedKey: String?

        switch seed {
        case .track(let seedTrack):
            seedKey = seedTrack.s3Key
        case .album(let album):
            // Use first track of album
            seedKey = album.tracks.first?.s3Key
        default:
            seedKey = nil
        }

        guard let key = seedKey else { return 0 }

        return AffinityService.shared.affinityScore(from: key, to: track.s3Key)
    }

    /// Layer 3: Last.fm similar artists (0.0-1.0)
    private func calculateSimilarArtistScore(track: Track, seed: RadioSeed) -> Double {
        guard let trackArtist = track.artist else { return 0 }

        // Use pre-fetched similar artists
        let normalizedArtist = trackArtist.lowercased()

        for similar in seedSimilarArtists {
            if similar.name.lowercased() == normalizedArtist {
                return similar.match
            }
        }

        return 0
    }

    // MARK: - Helper Methods

    private func prefetchSimilarArtists(for seed: RadioSeed) async {
        let artistName: String?

        switch seed {
        case .track(let track):
            artistName = track.artist
        case .artist(let artist):
            artistName = artist.name
        case .album(let album):
            artistName = album.tracks.first?.artist
        default:
            artistName = nil
        }

        guard let name = artistName else { return }

        seedArtistName = name
        seedSimilarArtists = await LastFMSimilarService.shared.fetchSimilarArtists(for: name)

        print("Radio: Fetched \(seedSimilarArtists.count) similar artists for \(name)")
    }

    private func weightedRandomSelect(from items: [(track: Track, score: Double)]) -> (track: Track, score: Double)? {
        guard !items.isEmpty else { return nil }

        let totalWeight = items.reduce(0) { $0 + max($1.score, 0.1) }
        guard totalWeight > 0 else { return items.randomElement() }

        var randomValue = Double.random(in: 0..<totalWeight)

        for item in items {
            randomValue -= max(item.score, 0.1)
            if randomValue <= 0 {
                return item
            }
        }

        return items.last
    }
}
