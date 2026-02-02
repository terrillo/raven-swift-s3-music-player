//
//  LastFMSimilarService.swift
//  Music
//
//  Fetches similar artists from Last.fm API for radio mode Layer 3 scoring.
//  Works on all platforms (iOS + macOS).
//

import Foundation

/// Represents a similar artist from Last.fm
struct SimilarArtist: Codable {
    let name: String
    let match: Double  // 0.0-1.0 similarity score

    init(name: String, match: Double) {
        self.name = name
        self.match = match
    }
}

/// Cache entry for similar artists
private struct SimilarArtistsCacheEntry: Codable {
    let artists: [SimilarArtist]
    let fetchedAt: Date
}

actor LastFMSimilarService {
    static let shared = LastFMSimilarService()

    private static let baseURL = "https://ws.audioscrobbler.com/2.0/"
    private static let minRequestInterval: TimeInterval = 0.25  // 250ms between requests
    private static let cacheValidityDays: Int = 30

    private static var cacheFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lastfm_similar_cache.json")
    }

    private var cache: [String: SimilarArtistsCacheEntry] = [:]
    private var lastRequestTime: Date = .distantPast

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    private init() {
        // Load disk cache on init
        if let diskCache = Self.loadCacheFromDisk() {
            cache = diskCache
        }
    }

    // MARK: - API Key

    /// Get API key from iCloud Key-Value store or UserDefaults
    private var apiKey: String? {
        // Try iCloud first
        let iCloudKey = NSUbiquitousKeyValueStore.default.string(forKey: "lastfmAPIKey")
        if let key = iCloudKey, !key.isEmpty {
            return key
        }

        // Fall back to UserDefaults
        let defaultsKey = UserDefaults.standard.string(forKey: "lastfmAPIKey")
        if let key = defaultsKey, !key.isEmpty {
            return key
        }

        return nil
    }

    var isEnabled: Bool {
        apiKey != nil
    }

    // MARK: - Public API

    /// Fetch similar artists for a given artist name
    /// Returns an array of SimilarArtist sorted by match score (highest first)
    func fetchSimilarArtists(for artistName: String) async -> [SimilarArtist] {
        guard let apiKey = apiKey else { return [] }

        let cacheKey = artistName.lowercased()

        // Check cache
        if let cached = cache[cacheKey] {
            // Check if cache is still valid
            let daysSinceFetch = Calendar.current.dateComponents([.day], from: cached.fetchedAt, to: Date()).day ?? 0
            if daysSinceFetch < Self.cacheValidityDays {
                return cached.artists
            }
        }

        // Rate limit
        await rateLimit()

        // Build request
        var components = URLComponents(string: Self.baseURL)
        components?.queryItems = [
            URLQueryItem(name: "method", value: "artist.getsimilar"),
            URLQueryItem(name: "artist", value: artistName),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: "100")
        ]

        guard let url = components?.url else { return [] }

        do {
            let (data, _) = try await session.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            // Check for API error
            if json?["error"] != nil {
                return []
            }

            // Parse similar artists
            guard let similarArtists = json?["similarartists"] as? [String: Any],
                  let artistArray = similarArtists["artist"] as? [[String: Any]] else {
                return []
            }

            let artists = artistArray.compactMap { artistData -> SimilarArtist? in
                guard let name = artistData["name"] as? String else { return nil }

                // Match can be a string or number
                let match: Double
                if let matchStr = artistData["match"] as? String {
                    match = Double(matchStr) ?? 0
                } else if let matchNum = artistData["match"] as? Double {
                    match = matchNum
                } else {
                    match = 0
                }

                return SimilarArtist(name: name, match: match)
            }
            .sorted { $0.match > $1.match }

            // Cache result
            cache[cacheKey] = SimilarArtistsCacheEntry(artists: artists, fetchedAt: Date())
            await saveCache()

            return artists
        } catch {
            print("Failed to fetch similar artists: \(error)")
            return []
        }
    }

    /// Check if an artist is similar to a seed artist
    /// Returns the match score (0.0-1.0) or nil if not similar
    func similarityScore(artist artistName: String, toSeedArtist seedArtist: String) async -> Double? {
        let similar = await fetchSimilarArtists(for: seedArtist)
        let normalizedArtist = artistName.lowercased()

        for similar in similar {
            if similar.name.lowercased() == normalizedArtist {
                return similar.match
            }
        }

        return nil
    }

    // MARK: - Cache Management

    func clearCache() {
        cache.removeAll()
        try? FileManager.default.removeItem(at: Self.cacheFileURL)
    }

    func cacheStats() -> String {
        "Similar Artists: \(cache.count) artists cached"
    }

    // MARK: - Private Methods

    private func rateLimit() async {
        let elapsed = Date().timeIntervalSince(lastRequestTime)
        if elapsed < Self.minRequestInterval {
            try? await Task.sleep(for: .seconds(Self.minRequestInterval - elapsed))
        }
        lastRequestTime = Date()
    }

    private static func loadCacheFromDisk() -> [String: SimilarArtistsCacheEntry]? {
        guard FileManager.default.fileExists(atPath: cacheFileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: cacheFileURL)
            let cache = try JSONDecoder().decode([String: SimilarArtistsCacheEntry].self, from: data)
            print("Loaded similar artists cache: \(cache.count) entries")
            return cache
        } catch {
            print("Failed to load similar artists cache: \(error)")
            return nil
        }
    }

    private func saveCache() async {
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: Self.cacheFileURL)
        } catch {
            print("Failed to save similar artists cache: \(error)")
        }
    }
}
