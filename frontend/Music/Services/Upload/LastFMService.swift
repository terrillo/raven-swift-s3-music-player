//
//  LastFMService.swift
//  Music
//
//  Service for fetching album metadata from Last.fm.
//  Used as a fallback when TheAudioDB doesn't have album data.
//

import Foundation

#if os(macOS)

actor LastFMService {
    private static let baseURL = "https://ws.audioscrobbler.com/2.0/"
    private static let minRequestInterval: TimeInterval = 0.25  // 250ms between requests

    private static var cacheFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lastfm_cache.json")
    }

    private let apiKey: String
    private let storageService: StorageService?
    private var albumCache: [String: AlbumInfo] = [:]  // Key: "artist|album"
    private var lastRequestTime: Date = .distantPast

    // URLSession with timeout to prevent hangs
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    init(apiKey: String, storageService: StorageService? = nil) {
        self.apiKey = apiKey
        self.storageService = storageService

        // Load disk cache on init
        if let cache = Self.loadCacheFromDisk() {
            albumCache = cache
        }
    }

    var isEnabled: Bool { !apiKey.isEmpty }

    // MARK: - Disk Cache

    private static func loadCacheFromDisk() -> [String: AlbumInfo]? {
        guard FileManager.default.fileExists(atPath: cacheFileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: cacheFileURL)
            let cache = try JSONDecoder().decode([String: AlbumInfo].self, from: data)
            print("📀 Loaded LastFM cache: \(cache.count) albums")
            return cache
        } catch {
            print("⚠️ Failed to load LastFM cache: \(error.localizedDescription)")
            return nil
        }
    }

    func saveCache() {
        do {
            let data = try JSONEncoder().encode(albumCache)
            try data.write(to: Self.cacheFileURL)
            print("💾 Saved LastFM cache: \(albumCache.count) albums")
        } catch {
            print("⚠️ Failed to save LastFM cache: \(error.localizedDescription)")
        }
    }

    // MARK: - Cache Inspection

    /// Returns set of album keys (artist|album format) that are cached
    func getCachedAlbumKeys() -> Set<String> {
        Set(albumCache.keys)
    }

    /// Returns cache statistics for debugging
    func cacheStats() -> String {
        "LastFM: \(albumCache.count) albums"
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

    private func makeRequest(method: String, params: [String: String]) async -> [String: Any]? {
        guard isEnabled else { return nil }

        await rateLimit()

        var allParams = params
        allParams["method"] = method
        allParams["api_key"] = apiKey
        allParams["format"] = "json"

        guard var components = URLComponents(string: Self.baseURL) else { return nil }
        components.queryItems = allParams.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = components.url else { return nil }

        for attempt in 0..<3 {
            do {
                let (data, _) = try await session.data(from: url)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                // Check for API-level errors
                if json?["error"] != nil {
                    return nil
                }

                return json
            } catch {
                if attempt < 2 {
                    let sleepTime = pow(2.0, Double(attempt))
                    try? await Task.sleep(for: .seconds(sleepTime))
                }
            }
        }

        return nil
    }

    // MARK: - Fetch Album Info

    func fetchAlbumInfo(artist artistName: String, album albumName: String) async -> AlbumInfo {
        guard isEnabled else { return AlbumInfo() }

        let cacheKey = "\(artistName)|\(albumName)"
        if let cached = albumCache[cacheKey] {
            return cached
        }

        var result = AlbumInfo()

        let params = [
            "artist": artistName,
            "album": albumName,
            "autocorrect": "1"
        ]

        guard let data = await makeRequest(method: "album.getinfo", params: params),
              let albumData = data["album"] as? [String: Any] else {
            albumCache[cacheKey] = result
            return result
        }

        // Get corrected album name
        result.name = albumData["name"] as? String

        // Extract wiki summary
        if let wiki = albumData["wiki"] as? [String: Any],
           let summary = wiki["summary"] as? String, !summary.isEmpty {
            result.wiki = cleanWikiText(summary)
        }

        // Extract image URL (prefer extralarge or mega)
        if let images = albumData["image"] as? [[String: Any]] {
            if let imageUrl = getBestImage(from: images) {
                if let storage = storageService {
                    result.imageUrl = try? await storage.downloadAndUploadImage(
                        from: imageUrl,
                        artist: artistName,
                        album: albumName
                    )
                } else {
                    result.imageUrl = imageUrl
                }
            }
        }

        albumCache[cacheKey] = result
        return result
    }

    // MARK: - Helper Methods

    /// Extract the best quality image URL from Last.fm image list
    private func getBestImage(from images: [[String: Any]]) -> String? {
        // Priority order for image sizes
        let sizePriority = ["mega", "extralarge", "large", "medium", "small"]

        // Build a map of size -> url
        var sizeMap: [String: String] = [:]
        for img in images {
            if let size = img["size"] as? String,
               let url = img["#text"] as? String, !url.isEmpty {
                sizeMap[size] = url
            }
        }

        // Return the highest quality available
        for size in sizePriority {
            if let url = sizeMap[size], !url.isEmpty {
                return url
            }
        }

        return nil
    }

    /// Clean up wiki text from Last.fm
    private func cleanWikiText(_ text: String) -> String {
        var cleaned = text

        // Remove <a> tags (Read more links)
        if let regex = try? NSRegularExpression(pattern: "<a\\s+[^>]*>.*?</a>", options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
        }

        // Remove any remaining HTML tags
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>") {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
        }

        // Clean up whitespace
        cleaned = cleaned.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}

#endif
