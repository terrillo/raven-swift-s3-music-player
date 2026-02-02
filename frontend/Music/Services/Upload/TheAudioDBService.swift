//
//  TheAudioDBService.swift
//  Music
//
//  Service for fetching artist and album metadata from TheAudioDB.
//  Uses free tier API (no key required).
//

import Foundation

#if os(macOS)

/// Artist metadata from TheAudioDB
struct ArtistInfo: Codable {
    var name: String?       // Canonical artist name from TheAudioDB
    var bio: String?
    var imageUrl: String?
    var genre: String?
    var style: String?
    var mood: String?

    init(name: String? = nil, bio: String? = nil, imageUrl: String? = nil, genre: String? = nil, style: String? = nil, mood: String? = nil) {
        self.name = name
        self.bio = bio
        self.imageUrl = imageUrl
        self.genre = genre
        self.style = style
        self.mood = mood
    }
}

/// Album metadata from TheAudioDB
struct AlbumInfo: Codable {
    var name: String?
    var imageUrl: String?
    var wiki: String?
    var releaseDate: Int?
    var genre: String?
    var style: String?
    var mood: String?
    var theme: String?

    init(name: String? = nil, imageUrl: String? = nil, wiki: String? = nil, releaseDate: Int? = nil, genre: String? = nil, style: String? = nil, mood: String? = nil, theme: String? = nil) {
        self.name = name
        self.imageUrl = imageUrl
        self.wiki = wiki
        self.releaseDate = releaseDate
        self.genre = genre
        self.style = style
        self.mood = mood
        self.theme = theme
    }
}

/// Track metadata from TheAudioDB
struct TrackInfo: Codable {
    var name: String?
    var album: String?
    var genre: String?
    var style: String?
    var mood: String?
    var theme: String?

    init(name: String? = nil, album: String? = nil, genre: String? = nil, style: String? = nil, mood: String? = nil, theme: String? = nil) {
        self.name = name
        self.album = album
        self.genre = genre
        self.style = style
        self.mood = mood
        self.theme = theme
    }
}

/// Disk cache structure for TheAudioDB
private struct TheAudioDBDiskCache: Codable {
    var artists: [String: ArtistInfo]
    var albums: [String: AlbumInfo]
    var tracks: [String: TrackInfo]
}

actor TheAudioDBService {
    private static let baseURL = "https://www.theaudiodb.com/api/v1/json/123"
    private static let minRequestInterval: TimeInterval = 0.5  // 500ms between requests

    private static var cacheFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("theaudiodb_cache.json")
    }

    private let storageService: StorageService?
    private var artistCache: [String: ArtistInfo] = [:]

    // URLSession with timeout to prevent hangs
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()
    private var albumCache: [String: AlbumInfo] = [:]  // Key: "artist|album"
    private var trackCache: [String: TrackInfo] = [:]  // Key: "artist|track"
    private var artistIdCache: [String: (name: String, id: String)] = [:]
    private var lastRequestTime: Date = .distantPast

    init(storageService: StorageService? = nil) {
        self.storageService = storageService

        // Load disk cache on init
        if let cache = Self.loadCacheFromDisk() {
            artistCache = cache.artists
            albumCache = cache.albums
            trackCache = cache.tracks
        }
    }

    // MARK: - Disk Cache

    private static func loadCacheFromDisk() -> TheAudioDBDiskCache? {
        guard FileManager.default.fileExists(atPath: cacheFileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: cacheFileURL)
            let cache = try JSONDecoder().decode(TheAudioDBDiskCache.self, from: data)
            print("📀 Loaded TheAudioDB cache: \(cache.artists.count) artists, \(cache.albums.count) albums, \(cache.tracks.count) tracks")
            return cache
        } catch {
            print("⚠️ Failed to load TheAudioDB cache: \(error.localizedDescription)")
            return nil
        }
    }

    func saveCache() {
        let cache = TheAudioDBDiskCache(artists: artistCache, albums: albumCache, tracks: trackCache)

        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: Self.cacheFileURL)
            print("💾 Saved TheAudioDB cache: \(artistCache.count) artists, \(albumCache.count) albums, \(trackCache.count) tracks")
        } catch {
            print("⚠️ Failed to save TheAudioDB cache: \(error.localizedDescription)")
        }
    }

    // MARK: - Cache Inspection

    /// Returns set of artist names that are cached
    func getCachedArtistKeys() -> Set<String> {
        Set(artistCache.keys)
    }

    /// Returns set of album keys (artist|album format) that are cached
    func getCachedAlbumKeys() -> Set<String> {
        Set(albumCache.keys)
    }

    /// Returns cache statistics for debugging
    func cacheStats() -> String {
        "TheAudioDB: \(artistCache.count) artists, \(albumCache.count) albums, \(trackCache.count) tracks"
    }

    // MARK: - Rate Limiting

    private func rateLimit() async {
        let elapsed = Date().timeIntervalSince(lastRequestTime)
        if elapsed < Self.minRequestInterval {
            try? await Task.sleep(for: .seconds(Self.minRequestInterval - elapsed))
        }
        lastRequestTime = Date()
    }

    // MARK: - API Requests

    private func makeRequest(_ endpoint: String, params: [String: String] = [:]) async -> [String: Any]? {
        await rateLimit()

        guard var components = URLComponents(string: "\(Self.baseURL)/\(endpoint)") else { return nil }
        if !params.isEmpty {
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        guard let url = components.url else { return nil }

        for attempt in 0..<3 {
            do {
                let (data, _) = try await session.data(from: url)
                return try JSONSerialization.jsonObject(with: data) as? [String: Any]
            } catch {
                if attempt < 2 {
                    let sleepTime = pow(2.0, Double(attempt))
                    try? await Task.sleep(for: .seconds(sleepTime))
                }
            }
        }

        return nil
    }

    // MARK: - Name Matching

    private func getNameVariations(_ name: String) -> [String] {
        var variations = [name]

        // Remove periods: "B.O.B" -> "BOB"
        let noPeriods = name.replacingOccurrences(of: ".", with: "")
        if noPeriods != name && !noPeriods.trimmingCharacters(in: .whitespaces).isEmpty {
            variations.append(noPeriods)
        }

        // Replace periods with period+space: "B.O.B" -> "B. O. B"
        let spaced = name.replacingOccurrences(of: ".", with: ". ").trimmingCharacters(in: .whitespaces)
        if spaced != name {
            variations.append(spaced)
        }

        // Remove slashes: "AC/DC" -> "ACDC"
        let noSlashes = name.replacingOccurrences(of: "/", with: "")
        if noSlashes != name && !noSlashes.trimmingCharacters(in: .whitespaces).isEmpty {
            variations.append(noSlashes)
        }

        // Replace slashes with spaces: "AC/DC" -> "AC DC"
        let slashToSpace = name.replacingOccurrences(of: "/", with: " ")
        if slashToSpace != name {
            variations.append(slashToSpace)
        }

        // Dedupe while preserving order
        var seen = Set<String>()
        return variations.filter { seen.insert($0).inserted }
    }

    private func namesMatch(_ searchName: String, _ resultName: String) -> Bool {
        func normalize(_ name: String) -> String {
            name.lowercased().filter { $0.isLetter || $0.isNumber }
        }

        let normSearch = normalize(searchName)
        let normResult = normalize(resultName)

        // Exact match after normalization
        if normSearch == normResult { return true }

        // Check if one is a substring of the other
        if normSearch.count >= 3 && normResult.count >= 3 {
            if normSearch.contains(normResult) || normResult.contains(normSearch) {
                return true
            }
        }

        return false
    }

    /// Normalize album name by stripping edition suffixes.
    private func normalizeAlbumName(_ albumName: String) -> String {
        var normalized = albumName

        let patterns = [
            #"\s*[\.\-]?\s*\(\s*deluxe\s*(version|edition)?\s*\)"#,
            #"\s*[\.\-]?\s*\(\s*special\s+edition\s*\)"#,
            #"\s*[\.\-]?\s*\(\s*expanded\s+edition\s*\)"#,
            #"\s*[\.\-]?\s*\(\s*remaster(ed)?\s*\)"#,
            #"\s*[\.\-]?\s*\(\s*bonus\s+track(s)?\s*\)"#,
            #"\s*-\s*single\s*$"#,
            #"\s*-\s*ep\s*$"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(normalized.startIndex..., in: normalized)
                normalized = regex.stringByReplacingMatches(in: normalized, range: range, withTemplate: "")
            }
        }

        return normalized.trimmingCharacters(in: .whitespaces).isEmpty ? albumName : normalized.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Fetch Artist Info

    func fetchArtistInfo(_ artistName: String) async -> ArtistInfo {
        if let cached = artistCache[artistName] {
            return cached
        }

        var result = ArtistInfo()

        // Search with name variations
        var artistData: [String: Any]?
        for variation in getNameVariations(artistName) {
            if let data = await makeRequest("search.php", params: ["s": variation]),
               let artists = data["artists"] as? [[String: Any]],
               let first = artists.first {
                artistData = first
                break
            }
        }

        if let artistData = artistData {
            // Cache canonical name and ID for album lookups
            let canonicalName = artistData["strArtist"] as? String ?? artistName
            if let artistId = artistData["idArtist"] as? String {
                artistIdCache[artistName] = (canonicalName, artistId)
            }

            // Return canonical name from TheAudioDB
            result.name = canonicalName

            // Extract bio
            if let bio = artistData["strBiographyEN"] as? String, !bio.isEmpty {
                result.bio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Extract metadata
            result.genre = artistData["strGenre"] as? String
            result.style = artistData["strStyle"] as? String
            result.mood = artistData["strMood"] as? String

            // Upload artist image
            let imageUrl = artistData["strArtistThumb"] as? String
                ?? artistData["strArtistFanart"] as? String
                ?? artistData["strArtistFanart2"] as? String

            if let imageUrl = imageUrl, !imageUrl.isEmpty, let storage = storageService {
                result.imageUrl = try? await storage.downloadAndUploadArtistImage(from: imageUrl, artist: artistName)
            }
        }

        artistCache[artistName] = result
        return result
    }

    // MARK: - Fetch Album Info

    func fetchAlbumInfo(artist artistName: String, album albumName: String) async -> AlbumInfo {
        let cacheKey = "\(artistName)|\(albumName)"
        if let cached = albumCache[cacheKey] {
            return cached
        }

        var result = AlbumInfo()

        // Get cached canonical artist info
        let (canonicalName, artistId) = artistIdCache[artistName] ?? (artistName, nil)

        var albumData: [String: Any]?

        // Try name search with normalized album name first
        let normalizedAlbum = normalizeAlbumName(albumName)
        if normalizedAlbum != albumName {
            if let data = await makeRequest("searchalbum.php", params: ["s": canonicalName, "a": normalizedAlbum]),
               let albums = data["album"] as? [[String: Any]],
               let first = albums.first {
                albumData = first
            }
        }

        // Try with original name
        if albumData == nil {
            if let data = await makeRequest("searchalbum.php", params: ["s": canonicalName, "a": albumName]),
               let albums = data["album"] as? [[String: Any]],
               let first = albums.first {
                albumData = first
            }
        }

        // Fallback: get all artist albums by ID and match by name
        if albumData == nil, let artistId = artistId {
            if let data = await makeRequest("album.php", params: ["i": artistId]),
               let albums = data["album"] as? [[String: Any]] {
                let albumNameLower = albumName.lowercased()
                for album in albums {
                    if let name = album["strAlbum"] as? String, name.lowercased() == albumNameLower {
                        albumData = album
                        break
                    }
                }
            }
        }

        if let albumData = albumData {
            // Get corrected album name
            result.name = albumData["strAlbum"] as? String

            // Extract description/wiki
            if let wiki = albumData["strDescriptionEN"] as? String ?? albumData["strDescription"] as? String, !wiki.isEmpty {
                result.wiki = wiki.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Extract release year
            if let year = albumData["intYearReleased"] {
                result.releaseDate = Identifiers.extractYear(from: year)
            }

            // Extract metadata
            result.genre = albumData["strGenre"] as? String
            result.style = albumData["strStyle"] as? String
            result.mood = albumData["strMood"] as? String
            result.theme = albumData["strTheme"] as? String

            // Upload album artwork
            let imageUrl = albumData["strAlbumThumb"] as? String
                ?? albumData["strAlbumThumbHQ"] as? String

            if let imageUrl = imageUrl, !imageUrl.isEmpty, let storage = storageService {
                let s3AlbumName = result.name ?? albumName
                result.imageUrl = try? await storage.downloadAndUploadImage(from: imageUrl, artist: artistName, album: s3AlbumName)
            }
        }

        albumCache[cacheKey] = result
        return result
    }

    // MARK: - Fetch Track Info

    func fetchTrackInfo(artist artistName: String, track trackTitle: String) async -> TrackInfo {
        let cacheKey = "\(artistName)|\(trackTitle)"
        if let cached = trackCache[cacheKey] {
            return cached
        }

        var result = TrackInfo()

        if let data = await makeRequest("searchtrack.php", params: ["s": artistName, "t": trackTitle]),
           let tracks = data["track"] as? [[String: Any]],
           let trackData = tracks.first {

            result.name = trackData["strTrack"] as? String
            result.album = trackData["strAlbum"] as? String
            result.genre = trackData["strGenre"] as? String
            result.style = trackData["strStyle"] as? String
            result.mood = trackData["strMood"] as? String
            result.theme = trackData["strTheme"] as? String
        }

        trackCache[cacheKey] = result
        return result
    }
}

#endif
