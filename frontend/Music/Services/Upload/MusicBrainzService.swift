//
//  MusicBrainzService.swift
//  Music
//
//  Service for fetching MusicBrainz IDs and metadata.
//  Used for more accurate TheAudioDB lookups.
//

import Foundation

#if os(macOS)

/// Detailed artist information from MusicBrainz
struct ArtistDetails {
    var mbid: String?
    var name: String?
    var artistType: String?  // person, group, orchestra, choir, etc.
    var area: String?        // country/region
    var beginDate: String?   // formation or birth date
    var endDate: String?     // dissolution or death date
    var disambiguation: String?  // clarifying text
    var tags: [String] = []
}

/// Detailed release information from MusicBrainz
struct ReleaseDetails {
    var mbid: String?
    var title: String?
    var releaseDate: Int?
    var releaseType: String?  // album, single, EP, compilation
    var country: String?
    var label: String?
    var barcode: String?
    var mediaFormat: String?  // CD, vinyl, digital
    var tags: [String] = []
}

actor MusicBrainzService {
    private static let baseURL = "https://musicbrainz.org/ws/2"
    private static let minRequestInterval: TimeInterval = 1.0  // 1 request per second

    private let userAgent: String
    private let enabled: Bool
    private var artistMBIDCache: [String: String?] = [:]
    private var artistDetailsCache: [String: ArtistDetails] = [:]
    private var releaseCache: [String: ReleaseDetails] = [:]  // Key: "artist|album"
    private var lastRequestTime: Date = .distantPast

    // URLSession with timeout to prevent hangs
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    init(contact: String, enabled: Bool = true) {
        self.userAgent = "MusicApp/1.0 (\(contact))"
        self.enabled = enabled && !contact.isEmpty
    }

    var isEnabled: Bool { enabled }

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
        guard enabled else { return nil }

        await rateLimit()

        var components = URLComponents(string: "\(Self.baseURL)/\(endpoint)")!
        var queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        queryItems.append(URLQueryItem(name: "fmt", value: "json"))
        components.queryItems = queryItems

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        for attempt in 0..<3 {
            do {
                let (data, _) = try await session.data(for: request)
                return try JSONSerialization.jsonObject(with: data) as? [String: Any]
            } catch {
                if attempt < 2 {
                    let sleepTime = pow(2.0, Double(attempt))
                    try? await Task.sleep(for: .seconds(sleepTime))
                    await rateLimit()  // Re-apply rate limit on retry
                }
            }
        }

        return nil
    }

    // MARK: - Lucene Escaping

    /// Escape special Lucene query characters
    private func escapeLucene(_ text: String) -> String {
        let specialChars = "+-&|!(){}[]^\"~*?:\\/<>"
        var escaped = ""
        for char in text {
            if specialChars.contains(char) {
                escaped += "\\\(char)"
            } else {
                escaped += String(char)
            }
        }
        return escaped
    }

    // MARK: - Get Artist MBID

    func getArtistMBID(_ artistName: String) async -> String? {
        guard enabled else { return nil }

        if let cached = artistMBIDCache[artistName] {
            return cached
        }

        var mbid = await searchArtist(artistName, escape: true)

        // Try without escaping for names with special chars
        if mbid == nil && artistName.contains(where: { ".&!".contains($0) }) {
            mbid = await searchArtist(artistName, escape: false)
        }

        artistMBIDCache[artistName] = mbid
        return mbid
    }

    private func searchArtist(_ artistName: String, escape: Bool) async -> String? {
        let safeName = escape ? escapeLucene(artistName) : artistName
        let query = "artist:\"\(safeName)\""

        guard let data = await makeRequest("artist", params: ["query": query, "limit": "5"]),
              let artists = data["artists"] as? [[String: Any]],
              !artists.isEmpty else {
            return nil
        }

        // Find best match - prefer exact name match
        for artist in artists {
            if let name = artist["name"] as? String,
               name.lowercased() == artistName.lowercased() {
                return artist["id"] as? String
            }
        }

        // Return highest scored result
        return artists.first?["id"] as? String
    }

    // MARK: - Get Artist Details

    func getArtistDetails(_ artistName: String) async -> ArtistDetails {
        guard enabled else { return ArtistDetails() }

        if let cached = artistDetailsCache[artistName] {
            return cached
        }

        guard let mbid = await getArtistMBID(artistName) else {
            let result = ArtistDetails()
            artistDetailsCache[artistName] = result
            return result
        }

        let details = await fetchArtistDetails(mbid)
        artistDetailsCache[artistName] = details
        return details
    }

    private func fetchArtistDetails(_ mbid: String) async -> ArtistDetails {
        guard let data = await makeRequest("artist/\(mbid)", params: ["inc": "tags"]) else {
            return ArtistDetails(mbid: mbid)
        }

        // Extract life-span dates
        let lifeSpan = data["life-span"] as? [String: Any] ?? [:]
        let beginDate = lifeSpan["begin"] as? String
        let endDate = lifeSpan["end"] as? String

        // Extract area
        let areaData = data["area"] as? [String: Any] ?? [:]
        let area = areaData["name"] as? String

        // Extract tags
        var tags: [String] = []
        if let tagList = data["tags"] as? [[String: Any]] {
            tags = tagList.prefix(5).compactMap { $0["name"] as? String }
        }

        return ArtistDetails(
            mbid: mbid,
            name: data["name"] as? String,
            artistType: data["type"] as? String,
            area: area,
            beginDate: beginDate,
            endDate: endDate,
            disambiguation: data["disambiguation"] as? String,
            tags: tags
        )
    }

    // MARK: - Get Release Details

    func getReleaseDetails(artist artistName: String, album albumName: String) async -> ReleaseDetails {
        guard enabled else { return ReleaseDetails() }

        let cacheKey = "\(artistName)|\(albumName)"
        if let cached = releaseCache[cacheKey] {
            return cached
        }

        let details = await searchRelease(artistName, albumName)
        releaseCache[cacheKey] = details
        return details
    }

    private func searchRelease(_ artistName: String, _ albumName: String) async -> ReleaseDetails {
        // Try exact search first
        var (mbid, title) = await searchReleaseExact(artistName, albumName)

        // Try fuzzy search with cleaned album name
        if mbid == nil {
            let cleanedAlbum = cleanAlbumName(albumName)
            if cleanedAlbum != albumName {
                (mbid, title) = await searchReleaseFuzzy(artistName, cleanedAlbum)
            }
        }

        guard let releaseMBID = mbid else {
            return ReleaseDetails()
        }

        return await fetchReleaseDetails(releaseMBID, title: title)
    }

    private func searchReleaseExact(_ artistName: String, _ albumName: String) async -> (String?, String?) {
        let safeArtist = escapeLucene(artistName)
        let safeAlbum = escapeLucene(albumName)
        let query = "release:\"\(safeAlbum)\" AND artist:\"\(safeArtist)\""
        return await doReleaseSearch(query)
    }

    private func searchReleaseFuzzy(_ artistName: String, _ albumName: String) async -> (String?, String?) {
        let safeArtist = escapeLucene(artistName)
        let safeAlbum = escapeLucene(albumName)
        let query = "release:\(safeAlbum) AND artist:\(safeArtist)"
        return await doReleaseSearch(query)
    }

    private func doReleaseSearch(_ query: String) async -> (String?, String?) {
        guard let data = await makeRequest("release", params: ["query": query, "limit": "1"]),
              let releases = data["releases"] as? [[String: Any]],
              let release = releases.first else {
            return (nil, nil)
        }

        return (release["id"] as? String, release["title"] as? String)
    }

    private func fetchReleaseDetails(_ mbid: String, title: String?) async -> ReleaseDetails {
        guard let data = await makeRequest("release/\(mbid)", params: ["inc": "labels+media+release-groups+tags"]) else {
            return ReleaseDetails(mbid: mbid, title: title)
        }

        // Extract release type from release-group
        let releaseGroup = data["release-group"] as? [String: Any] ?? [:]
        let releaseType = releaseGroup["primary-type"] as? String

        // Extract label
        var label: String?
        if let labelInfo = data["label-info"] as? [[String: Any]],
           let first = labelInfo.first,
           let labelData = first["label"] as? [String: Any] {
            label = labelData["name"] as? String
        }

        // Extract media format
        var mediaFormat: String?
        if let media = data["media"] as? [[String: Any]], let first = media.first {
            mediaFormat = first["format"] as? String
        }

        // Extract tags
        var tags: [String] = []
        if let tagList = data["tags"] as? [[String: Any]] {
            tags = tagList.prefix(5).compactMap { $0["name"] as? String }
        }

        return ReleaseDetails(
            mbid: mbid,
            title: title ?? data["title"] as? String,
            releaseDate: Identifiers.extractYear(from: data["date"]),
            releaseType: releaseType,
            country: data["country"] as? String,
            label: label,
            barcode: data["barcode"] as? String,
            mediaFormat: mediaFormat,
            tags: tags
        )
    }

    /// Clean album name by removing common suffixes
    private func cleanAlbumName(_ albumName: String) -> String {
        var cleaned = albumName

        let patterns = [
            #"\s*[\.\s]*\([^)]*(?:deluxe|edition|version|remaster|bonus|expanded)[^)]*\)"#,
            #"\s*\[[^\]]*(?:deluxe|edition|version|remaster|bonus|expanded)[^\]]*\]"#,
            #"\s*[\.\s]*\([^)]*\)\s*$"#,
            #"\s*\[[^\]]*\]\s*$"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(cleaned.startIndex..., in: cleaned)
                cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
            }
        }

        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}

#endif
