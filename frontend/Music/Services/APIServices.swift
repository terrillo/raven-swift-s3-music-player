//
//  APIServices.swift
//  Music
//
//  Swift ports of TheAudioDB, MusicBrainz, and Last.fm API services.
//  Uses Swift actors for thread-safe rate limiting and caching.
//

import Foundation
import SwiftData

// MARK: - Artist Info

struct ArtistInfo {
    var bio: String?
    var imageUrl: String?
    var genre: String?
    var style: String?
    var mood: String?
    var artistType: String?
    var area: String?
    var beginDate: String?
    var endDate: String?
    var disambiguation: String?

    static let empty = ArtistInfo()
}

// MARK: - Album Info

struct AlbumInfo {
    var name: String?
    var imageUrl: String?
    var wiki: String?
    var releaseDate: Int?
    var genre: String?
    var style: String?
    var mood: String?
    var theme: String?
    var releaseType: String?
    var country: String?
    var label: String?
    var barcode: String?      // MusicBrainz: barcode
    var mediaFormat: String?  // MusicBrainz: media[0].format (CD, vinyl, digital)

    static let empty = AlbumInfo()
}

// MARK: - Track Info

struct TrackInfo {
    var name: String?
    var album: String?
    var genre: String?
    var style: String?
    var mood: String?
    var theme: String?

    static let empty = TrackInfo()
}

#if os(macOS)

// MARK: - Rate Limiter

/// Thread-safe rate limiter actor.
actor RateLimiter {
    private let minInterval: TimeInterval
    private var lastRequestTime: Date = .distantPast

    init(requestsPerSecond: Double) {
        self.minInterval = 1.0 / requestsPerSecond
    }

    func wait() async {
        let elapsed = Date().timeIntervalSince(lastRequestTime)
        if elapsed < minInterval {
            let waitTime = minInterval - elapsed
            try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
        }
        lastRequestTime = Date()
    }
}

// MARK: - TheAudioDB Service

/// Service for fetching artist and album metadata from TheAudioDB.
actor TheAudioDBService {
    private let s3Service: S3Service
    private let rateLimiter = RateLimiter(requestsPerSecond: 2.0)  // 2 req/sec

    private var artistCache: [String: ArtistInfo] = [:]
    private var albumCache: [String: AlbumInfo] = [:]
    private var trackCache: [String: TrackInfo] = [:]
    private var artistIdCache: [String: (String, String)] = [:]  // name -> (canonical, id)

    private let baseUrl = "https://www.theaudiodb.com/api/v1/json/123"

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    init(s3Service: S3Service) {
        self.s3Service = s3Service
    }

    // MARK: - Artist Info (with SwiftData cache)

    /// Fetch artist info, checking SwiftData first for persisted data.
    func fetchArtistInfo(_ artistName: String, modelContainer: ModelContainer? = nil) async -> ArtistInfo {
        if let cached = artistCache[artistName] {
            return cached
        }

        // Check SwiftData persistent cache
        if let container = modelContainer {
            let artistId = UploadIdentifiers.artistId(artistName)
            if let stored = await MainActor.run(body: { () -> ArtistInfo? in
                let context = container.mainContext
                let descriptor = FetchDescriptor<UploadedArtist>(
                    predicate: #Predicate { $0.id == artistId }
                )
                guard let artist = try? context.fetch(descriptor).first else { return nil }

                // Only use if we have meaningful data
                guard artist.bio != nil || artist.imageUrl != nil || artist.genre != nil else { return nil }

                return ArtistInfo(
                    bio: artist.bio,
                    imageUrl: artist.imageUrl,
                    genre: artist.genre,
                    style: artist.style,
                    mood: artist.mood,
                    artistType: artist.artistType,
                    area: artist.area,
                    beginDate: artist.beginDate,
                    endDate: artist.endDate,
                    disambiguation: artist.disambiguation
                )
            }) {
                print("[TheAudioDBService] Using cached artist data for '\(artistName)'")
                artistCache[artistName] = stored
                return stored
            }
        }

        var result = ArtistInfo()

        // Try name search with variations
        for variation in getNameVariations(artistName) {
            await rateLimiter.wait()

            if let data = await makeRequest("search.php", params: ["s": variation]),
               let artists = data["artists"] as? [[String: Any]],
               let artistData = artists.first {
                // Cache canonical name and ID
                if let canonicalName = artistData["strArtist"] as? String,
                   let artistId = artistData["idArtist"] as? String {
                    artistIdCache[artistName] = (canonicalName, artistId)
                }

                // Extract bio
                if let bio = artistData["strBiographyEN"] as? String, !bio.isEmpty {
                    result.bio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                // Extract metadata
                result.genre = artistData["strGenre"] as? String
                result.style = artistData["strStyle"] as? String
                result.mood = artistData["strMood"] as? String

                // Get artist image URL - upload to S3
                let imageUrl = artistData["strArtistThumb"] as? String
                    ?? artistData["strArtistFanart"] as? String
                    ?? artistData["strArtistFanart2"] as? String

                if let imageUrl, !imageUrl.isEmpty {
                    let s3Key = "\(UploadIdentifiers.sanitizeS3Key(artistName))/artist.jpg"
                    if let uploadedUrl = try? await s3Service.downloadAndUploadImage(imageUrl, s3Key: s3Key) {
                        result.imageUrl = uploadedUrl
                    }
                }

                break
            }
        }

        artistCache[artistName] = result
        return result
    }

    // MARK: - Album Info (with SwiftData cache)

    /// Fetch album info, checking SwiftData first for persisted data.
    func fetchAlbumInfo(_ artistName: String, _ albumName: String, modelContainer: ModelContainer? = nil) async -> AlbumInfo {
        let cacheKey = "\(artistName)|\(albumName)"
        if let cached = albumCache[cacheKey] {
            return cached
        }

        // Check SwiftData persistent cache
        if let container = modelContainer {
            let albumId = UploadIdentifiers.albumId(artist: artistName, album: albumName)
            if let stored = await MainActor.run(body: { () -> AlbumInfo? in
                let context = container.mainContext
                let descriptor = FetchDescriptor<UploadedAlbum>(
                    predicate: #Predicate { $0.id == albumId }
                )
                guard let album = try? context.fetch(descriptor).first else { return nil }

                // Only use if we have the corrected name (meaning we have API data)
                guard album.name != album.localName || album.imageUrl != nil || album.wiki != nil else { return nil }

                return AlbumInfo(
                    name: album.name,
                    imageUrl: album.imageUrl,
                    wiki: album.wiki,
                    releaseDate: album.releaseDate,
                    genre: album.genre,
                    style: album.style,
                    mood: album.mood,
                    theme: album.theme,
                    releaseType: album.releaseType,
                    country: album.country,
                    label: album.label
                )
            }) {
                print("[TheAudioDBService] Using cached album data for '\(artistName) - \(albumName)'")
                albumCache[cacheKey] = stored
                return stored
            }
        }

        var result = AlbumInfo()

        // Get canonical artist info
        let (canonicalName, artistId) = artistIdCache[artistName] ?? (artistName, nil)

        // Try normalized album name first
        let normalizedAlbum = normalizeAlbumName(albumName)
        if normalizedAlbum != albumName {
            await rateLimiter.wait()
            if let albumData = await searchAlbum(canonicalName, normalizedAlbum) {
                result = await extractAlbumInfo(albumData, artistName: artistName, albumName: albumName)
            }
        }

        // Try original album name
        if result.name == nil {
            await rateLimiter.wait()
            if let albumData = await searchAlbum(canonicalName, albumName) {
                result = await extractAlbumInfo(albumData, artistName: artistName, albumName: albumName)
            }
        }

        // Fallback: search by artist ID
        if result.name == nil, let artistId {
            await rateLimiter.wait()
            if let data = await makeRequest("album.php", params: ["i": artistId]),
               let albums = data["album"] as? [[String: Any]] {
                let albumLower = albumName.lowercased()
                if let albumData = albums.first(where: { ($0["strAlbum"] as? String)?.lowercased() == albumLower }) {
                    result = await extractAlbumInfo(albumData, artistName: artistName, albumName: albumName)
                }
            }
        }

        albumCache[cacheKey] = result
        return result
    }

    private func searchAlbum(_ artist: String, _ album: String) async -> [String: Any]? {
        guard let data = await makeRequest("searchalbum.php", params: ["s": artist, "a": album]),
              let albums = data["album"] as? [[String: Any]],
              let albumData = albums.first else {
            return nil
        }
        return albumData
    }

    private func extractAlbumInfo(_ albumData: [String: Any], artistName: String, albumName: String) async -> AlbumInfo {
        var result = AlbumInfo()

        result.name = albumData["strAlbum"] as? String

        if let wiki = albumData["strDescriptionEN"] as? String ?? albumData["strDescription"] as? String,
           !wiki.isEmpty {
            result.wiki = wiki.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let year = albumData["intYearReleased"] {
            result.releaseDate = UploadIdentifiers.extractYear(year)
        }

        result.genre = albumData["strGenre"] as? String
        result.style = albumData["strStyle"] as? String
        result.mood = albumData["strMood"] as? String
        result.theme = albumData["strTheme"] as? String

        // Upload album artwork
        let imageUrl = albumData["strAlbumThumb"] as? String ?? albumData["strAlbumThumbHQ"] as? String
        if let imageUrl, !imageUrl.isEmpty {
            let s3AlbumName = result.name ?? albumName
            let s3Key = "\(UploadIdentifiers.sanitizeS3Key(artistName))/\(UploadIdentifiers.sanitizeS3Key(s3AlbumName))/cover.jpg"
            if let uploadedUrl = try? await s3Service.downloadAndUploadImage(imageUrl, s3Key: s3Key) {
                result.imageUrl = uploadedUrl
            }
        }

        return result
    }

    // MARK: - Track Info

    func fetchTrackInfo(_ artistName: String, _ trackTitle: String) async -> TrackInfo {
        let cacheKey = "\(artistName)|\(trackTitle)"
        if let cached = trackCache[cacheKey] {
            return cached
        }

        var result = TrackInfo()

        await rateLimiter.wait()
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

    // MARK: - Helpers

    private func makeRequest(_ endpoint: String, params: [String: String]) async -> [String: Any]? {
        var components = URLComponents(string: "\(baseUrl)/\(endpoint)")!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = components.url else { return nil }

        for attempt in 0..<3 {
            do {
                let (data, _) = try await session.data(from: url)
                return try JSONSerialization.jsonObject(with: data) as? [String: Any]
            } catch {
                if attempt < 2 {
                    let waitTime = pow(2.0, Double(attempt))
                    try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
                }
            }
        }
        return nil
    }

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

        return variations
    }

    private func normalizeAlbumName(_ albumName: String) -> String {
        var normalized = albumName

        // Patterns to remove
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
                normalized = regex.stringByReplacingMatches(
                    in: normalized,
                    range: NSRange(normalized.startIndex..., in: normalized),
                    withTemplate: ""
                )
            }
        }

        return normalized.trimmingCharacters(in: .whitespaces).isEmpty ? albumName : normalized.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - MusicBrainz Service

/// Service for fetching MusicBrainz IDs and metadata.
actor MusicBrainzService {
    private let rateLimiter = RateLimiter(requestsPerSecond: 1.0)  // 1 req/sec

    private var artistMbidCache: [String: String?] = [:]
    private var artistDetailsCache: [String: ArtistInfo] = [:]
    private var releaseCache: [String: AlbumInfo] = [:]

    private let baseUrl = "https://musicbrainz.org/ws/2"
    private let userAgent = "MusicApp/1.0 ( contact@example.com )"

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    var enabled: Bool { true }

    // MARK: - Artist MBID

    func getArtistMbid(_ artistName: String) async -> String? {
        if let cached = artistMbidCache[artistName] {
            return cached
        }

        let mbid = await searchArtist(artistName)
        artistMbidCache[artistName] = mbid
        return mbid
    }

    func getArtistDetails(_ artistName: String) async -> ArtistInfo {
        if let cached = artistDetailsCache[artistName] {
            return cached
        }

        guard let mbid = await getArtistMbid(artistName) else {
            return .empty
        }

        await rateLimiter.wait()
        var result = ArtistInfo()

        if let data = await makeRequest("artist/\(mbid)", params: ["inc": "tags", "fmt": "json"]) {
            result.artistType = data["type"] as? String

            if let lifeSpan = data["life-span"] as? [String: Any] {
                result.beginDate = lifeSpan["begin"] as? String
                result.endDate = lifeSpan["end"] as? String
            }

            if let area = data["area"] as? [String: Any] {
                result.area = area["name"] as? String
            }

            result.disambiguation = data["disambiguation"] as? String
        }

        artistDetailsCache[artistName] = result
        return result
    }

    // MARK: - Release Info

    func getReleaseDetails(_ artistName: String, _ albumName: String) async -> AlbumInfo {
        let cacheKey = "\(artistName)|\(albumName)"
        if let cached = releaseCache[cacheKey] {
            return cached
        }

        var result = AlbumInfo()

        // Search for release with fallback strategy (matches backend)
        // 1. Try exact search first
        var mbid: String?
        var title: String?
        (mbid, title) = await searchReleaseExact(artistName, albumName)

        // 2. Fallback: fuzzy search with cleaned album name
        if mbid == nil {
            let cleanedAlbum = cleanAlbumNameForMusicBrainz(albumName)
            if cleanedAlbum != albumName {
                (mbid, title) = await searchReleaseFuzzy(artistName, cleanedAlbum)
            }
        }

        guard let mbid else {
            releaseCache[cacheKey] = result
            return result
        }

        result.name = title

        // Fetch details
        await rateLimiter.wait()
        if let data = await makeRequest("release/\(mbid)", params: ["inc": "labels+media+release-groups+tags", "fmt": "json"]) {
            if let releaseGroup = data["release-group"] as? [String: Any] {
                result.releaseType = releaseGroup["primary-type"] as? String
            }

            if let labelInfo = data["label-info"] as? [[String: Any]],
               let firstLabel = labelInfo.first,
               let label = firstLabel["label"] as? [String: Any] {
                result.label = label["name"] as? String
            }

            result.country = data["country"] as? String

            if let date = data["date"] as? String {
                result.releaseDate = UploadIdentifiers.extractYear(date)
            }

            // Extract barcode (matches backend)
            result.barcode = data["barcode"] as? String

            // Extract media format from first media entry (matches backend)
            if let media = data["media"] as? [[String: Any]],
               let firstMedia = media.first {
                result.mediaFormat = firstMedia["format"] as? String
            }
        }

        releaseCache[cacheKey] = result
        return result
    }

    // MARK: - Search

    private func searchArtist(_ artistName: String) async -> String? {
        await rateLimiter.wait()

        let escapedName = escapeLucene(artistName)
        let query = "artist:\"\(escapedName)\""

        guard let data = await makeRequest("artist", params: ["query": query, "fmt": "json", "limit": "5"]),
              let artists = data["artists"] as? [[String: Any]] else {
            return nil
        }

        // Prefer exact match
        for artist in artists {
            if let name = artist["name"] as? String,
               name.lowercased() == artistName.lowercased(),
               let id = artist["id"] as? String {
                return id
            }
        }

        // Return first result
        return artists.first?["id"] as? String
    }

    /// Exact release search with quoted terms (matches backend)
    private func searchReleaseExact(_ artistName: String, _ albumName: String) async -> (String?, String?) {
        await rateLimiter.wait()

        let escapedArtist = escapeLucene(artistName)
        let escapedAlbum = escapeLucene(albumName)
        let query = "release:\"\(escapedAlbum)\" AND artist:\"\(escapedArtist)\""

        guard let data = await makeRequest("release", params: ["query": query, "fmt": "json", "limit": "1"]),
              let releases = data["releases"] as? [[String: Any]],
              let release = releases.first else {
            return (nil, nil)
        }

        return (release["id"] as? String, release["title"] as? String)
    }

    /// Fuzzy release search without quotes (matches backend fallback)
    private func searchReleaseFuzzy(_ artistName: String, _ albumName: String) async -> (String?, String?) {
        await rateLimiter.wait()

        let escapedArtist = escapeLucene(artistName)
        let escapedAlbum = escapeLucene(albumName)
        // Fuzzy search: no quotes around terms
        let query = "release:\(escapedAlbum) AND artist:\(escapedArtist)"

        guard let data = await makeRequest("release", params: ["query": query, "fmt": "json", "limit": "1"]),
              let releases = data["releases"] as? [[String: Any]],
              let release = releases.first else {
            return (nil, nil)
        }

        return (release["id"] as? String, release["title"] as? String)
    }

    // MARK: - Album Name Cleaning

    /// Clean album name for MusicBrainz search (matches backend _clean_album_name)
    /// More aggressive than TheAudioDB normalization - removes common suffixes and brackets
    private func cleanAlbumNameForMusicBrainz(_ albumName: String) -> String {
        var cleaned = albumName

        // Patterns to remove (matches backend musicbrainz.py)
        let patterns = [
            // Remove parenthetical suffixes with keywords
            #"\s*[\.\-]?\s*\(.*?(deluxe|edition|remaster|bonus|expanded).*?\)"#,
            // Remove trailing square brackets
            #"\s*\[.*?\]$"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned,
                    range: NSRange(cleaned.startIndex..., in: cleaned),
                    withTemplate: ""
                )
            }
        }

        let result = cleaned.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? albumName : result
    }

    // MARK: - Helpers

    private func makeRequest(_ endpoint: String, params: [String: String]) async -> [String: Any]? {
        var components = URLComponents(string: "\(baseUrl)/\(endpoint)")!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        for attempt in 0..<3 {
            do {
                let (data, _) = try await session.data(for: request)
                return try JSONSerialization.jsonObject(with: data) as? [String: Any]
            } catch {
                if attempt < 2 {
                    let waitTime = pow(2.0, Double(attempt))
                    try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
                }
            }
        }
        return nil
    }

    private func escapeLucene(_ text: String) -> String {
        let specialChars = "+-&|!(){}[]^\"~*?:\\/<>"
        var escaped = ""
        for char in text {
            if specialChars.contains(char) {
                escaped += "\\\(char)"
            } else {
                escaped.append(char)
            }
        }
        return escaped
    }
}

// MARK: - Last.fm Service

/// Service for fetching album metadata from Last.fm as a fallback.
actor LastFMService {
    private let apiKey: String
    private let s3Service: S3Service
    private let rateLimiter = RateLimiter(requestsPerSecond: 4.0)  // 4 req/sec

    private var albumCache: [String: AlbumInfo] = [:]

    private let baseUrl = "https://ws.audioscrobbler.com/2.0/"

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    init(apiKey: String, s3Service: S3Service) {
        self.apiKey = apiKey
        self.s3Service = s3Service
    }

    var enabled: Bool { !apiKey.isEmpty }

    // MARK: - Album Info

    func fetchAlbumInfo(_ artistName: String, _ albumName: String) async -> AlbumInfo {
        guard enabled else { return .empty }

        let cacheKey = "\(artistName)|\(albumName)"
        if let cached = albumCache[cacheKey] {
            return cached
        }

        var result = AlbumInfo()

        await rateLimiter.wait()

        let params = [
            "method": "album.getinfo",
            "artist": artistName,
            "album": albumName,
            "autocorrect": "1",
            "api_key": apiKey,
            "format": "json"
        ]

        if let data = await makeRequest(params),
           let album = data["album"] as? [String: Any] {
            result.name = album["name"] as? String

            // Extract wiki
            if let wiki = album["wiki"] as? [String: Any],
               let summary = wiki["summary"] as? String, !summary.isEmpty {
                result.wiki = cleanWikiText(summary)
            }

            // Extract image
            if let images = album["image"] as? [[String: Any]] {
                let imageUrl = getBestImage(images)
                if let imageUrl {
                    let s3Key = "\(UploadIdentifiers.sanitizeS3Key(artistName))/\(UploadIdentifiers.sanitizeS3Key(albumName))/cover.jpg"
                    if let uploadedUrl = try? await s3Service.downloadAndUploadImage(imageUrl, s3Key: s3Key) {
                        result.imageUrl = uploadedUrl
                    }
                }
            }
        }

        albumCache[cacheKey] = result
        return result
    }

    // MARK: - Helpers

    private func makeRequest(_ params: [String: String]) async -> [String: Any]? {
        var components = URLComponents(string: baseUrl)!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = components.url else { return nil }

        for attempt in 0..<3 {
            do {
                let (data, _) = try await session.data(from: url)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                // Check for API error
                if json?["error"] != nil {
                    return nil
                }

                return json
            } catch {
                if attempt < 2 {
                    let waitTime = pow(2.0, Double(attempt))
                    try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
                }
            }
        }
        return nil
    }

    private func getBestImage(_ images: [[String: Any]]) -> String? {
        let sizePriority = ["mega", "extralarge", "large", "medium", "small"]
        var sizeMap: [String: String] = [:]

        for img in images {
            if let size = img["size"] as? String,
               let url = img["#text"] as? String, !url.isEmpty {
                sizeMap[size] = url
            }
        }

        for size in sizePriority {
            if let url = sizeMap[size] {
                return url
            }
        }

        return nil
    }

    private func cleanWikiText(_ text: String) -> String {
        var cleaned = text

        // Remove <a> tags
        if let regex = try? NSRegularExpression(pattern: "<a\\s+[^>]*>.*?</a>", options: .caseInsensitive) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }

        // Remove remaining HTML tags
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>") {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }

        // Clean up whitespace
        cleaned = cleaned.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}

#else

// iOS stubs

actor RateLimiter {
    init(requestsPerSecond: Double) {}
    func wait() async {}
}

actor TheAudioDBService {
    init(s3Service: S3Service) {}
    func fetchArtistInfo(_ artistName: String) async -> ArtistInfo { .empty }
    func fetchAlbumInfo(_ artistName: String, _ albumName: String) async -> AlbumInfo { .empty }
    func fetchTrackInfo(_ artistName: String, _ trackTitle: String) async -> TrackInfo { .empty }
}

actor MusicBrainzService {
    var enabled: Bool { false }
    func getArtistMbid(_ artistName: String) async -> String? { nil }
    func getArtistDetails(_ artistName: String) async -> ArtistInfo { .empty }
    func getReleaseDetails(_ artistName: String, _ albumName: String) async -> AlbumInfo { .empty }
}

actor LastFMService {
    init(apiKey: String, s3Service: S3Service) {}
    var enabled: Bool { false }
    func fetchAlbumInfo(_ artistName: String, _ albumName: String) async -> AlbumInfo { .empty }
}

#endif
