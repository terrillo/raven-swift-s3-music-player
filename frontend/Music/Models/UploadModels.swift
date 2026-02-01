//
//  UploadModels.swift
//  Music
//
//  SwiftData models for iCloud-synced upload state.
//  These models replace the catalog JSON file - the catalog is built
//  dynamically from these records on each device.
//

import Foundation
import SwiftData

// MARK: - UploadedTrack

/// Core model representing an uploaded track in S3.
/// Synced via iCloud across devices - replaces catalog JSON.
@Model
class UploadedTrack {
    // MARK: - Identity

    /// Unique S3 key (Artist/Album/Track.m4a format)
    /// Note: Uniqueness enforced in code, not via @Attribute(.unique) due to CloudKit limitations
    var s3Key: String = ""

    /// Public CDN URL for streaming
    var url: String = ""

    // MARK: - Track Metadata

    var title: String = ""
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var discTotal: Int?
    var duration: Int?  // seconds
    var year: Int?
    var genre: String?
    var style: String?
    var mood: String?
    var theme: String?
    var composer: String?
    var comment: String?

    // MARK: - Audio Properties

    var format: String = ""  // m4a, mp3, flac
    var originalFormat: String?  // Original format if converted
    var bitrate: Double?  // kbps
    var samplerate: Int?  // Hz
    var channels: Int?
    var filesize: Int?  // bytes

    // MARK: - Artwork

    /// URL to embedded artwork (uploaded to S3)
    var embeddedArtworkUrl: String?

    // MARK: - Upload State

    var uploadedAt: Date = Date()

    // MARK: - Relationships

    /// Reference to parent album (for efficient queries)
    var uploadedAlbumId: String?

    /// Reference to parent artist (for efficient queries)
    var uploadedArtistId: String?

    init(
        s3Key: String,
        url: String,
        title: String,
        format: String,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        trackNumber: Int? = nil,
        trackTotal: Int? = nil,
        discNumber: Int? = nil,
        discTotal: Int? = nil,
        duration: Int? = nil,
        year: Int? = nil,
        genre: String? = nil,
        style: String? = nil,
        mood: String? = nil,
        theme: String? = nil,
        composer: String? = nil,
        comment: String? = nil,
        originalFormat: String? = nil,
        bitrate: Double? = nil,
        samplerate: Int? = nil,
        channels: Int? = nil,
        filesize: Int? = nil,
        embeddedArtworkUrl: String? = nil,
        uploadedAt: Date = Date(),
        uploadedAlbumId: String? = nil,
        uploadedArtistId: String? = nil
    ) {
        self.s3Key = s3Key
        self.url = url
        self.title = title
        self.format = format
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.duration = duration
        self.year = year
        self.genre = genre
        self.style = style
        self.mood = mood
        self.theme = theme
        self.composer = composer
        self.comment = comment
        self.originalFormat = originalFormat
        self.bitrate = bitrate
        self.samplerate = samplerate
        self.channels = channels
        self.filesize = filesize
        self.embeddedArtworkUrl = embeddedArtworkUrl
        self.uploadedAt = uploadedAt
        self.uploadedAlbumId = uploadedAlbumId
        self.uploadedArtistId = uploadedArtistId
    }
}

// MARK: - UploadedArtist

/// Caches TheAudioDB/MusicBrainz artist metadata to avoid repeated API calls.
/// Synced via iCloud across devices.
@Model
class UploadedArtist {
    // MARK: - Identity

    /// Unique identifier (sanitized artist name)
    /// Note: Uniqueness enforced in code, not via @Attribute(.unique) due to CloudKit limitations
    var id: String = ""

    /// Display name (may be corrected from TheAudioDB)
    var name: String = ""

    // MARK: - TheAudioDB Metadata

    var bio: String?
    var imageUrl: String?
    var genre: String?
    var style: String?
    var mood: String?

    // MARK: - MusicBrainz Metadata

    var artistType: String?  // person, group, orchestra, choir
    var area: String?  // country/region
    var beginDate: String?  // formation or birth date
    var endDate: String?  // dissolution or death date
    var disambiguation: String?  // clarifying text

    // MARK: - State

    var lastUpdated: Date = Date()

    init(
        id: String,
        name: String,
        bio: String? = nil,
        imageUrl: String? = nil,
        genre: String? = nil,
        style: String? = nil,
        mood: String? = nil,
        artistType: String? = nil,
        area: String? = nil,
        beginDate: String? = nil,
        endDate: String? = nil,
        disambiguation: String? = nil,
        lastUpdated: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.bio = bio
        self.imageUrl = imageUrl
        self.genre = genre
        self.style = style
        self.mood = mood
        self.artistType = artistType
        self.area = area
        self.beginDate = beginDate
        self.endDate = endDate
        self.disambiguation = disambiguation
        self.lastUpdated = lastUpdated
    }
}

// MARK: - UploadedAlbum

/// Caches album metadata and corrected names from TheAudioDB.
/// Synced via iCloud across devices.
@Model
class UploadedAlbum {
    // MARK: - Identity

    /// Unique identifier (Artist/Album format, sanitized)
    /// Note: Uniqueness enforced in code, not via @Attribute(.unique) due to CloudKit limitations
    var id: String = ""

    /// Display name (corrected from TheAudioDB if available)
    var name: String = ""

    /// Local folder name (before correction)
    var localName: String = ""

    /// Parent artist ID
    var artistId: String = ""

    // MARK: - TheAudioDB Metadata

    var imageUrl: String?
    var wiki: String?
    var releaseDate: Int?  // Year
    var genre: String?
    var style: String?
    var mood: String?
    var theme: String?

    // MARK: - MusicBrainz Metadata

    var releaseType: String?  // album, single, EP, compilation
    var country: String?
    var label: String?
    var barcode: String?
    var mediaFormat: String?  // CD, vinyl, digital

    // MARK: - State

    var lastUpdated: Date = Date()

    init(
        id: String,
        name: String,
        localName: String,
        artistId: String,
        imageUrl: String? = nil,
        wiki: String? = nil,
        releaseDate: Int? = nil,
        genre: String? = nil,
        style: String? = nil,
        mood: String? = nil,
        theme: String? = nil,
        releaseType: String? = nil,
        country: String? = nil,
        label: String? = nil,
        barcode: String? = nil,
        mediaFormat: String? = nil,
        lastUpdated: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.localName = localName
        self.artistId = artistId
        self.imageUrl = imageUrl
        self.wiki = wiki
        self.releaseDate = releaseDate
        self.genre = genre
        self.style = style
        self.mood = mood
        self.theme = theme
        self.releaseType = releaseType
        self.country = country
        self.label = label
        self.barcode = barcode
        self.mediaFormat = mediaFormat
        self.lastUpdated = lastUpdated
    }
}

// MARK: - CachedS3Keys

/// Caches the list of S3 keys to avoid repeated API calls.
/// TTL-based expiration (5 minutes) ensures fresh data while avoiding N+1 listings.
@Model
class CachedS3Keys {
    /// The S3 bucket name
    var bucket: String = ""

    /// The S3 prefix (e.g., "music")
    var prefix: String = ""

    /// Cached set of S3 keys (stored as JSON array for SwiftData compatibility)
    var keysData: Data = Data()

    /// When the cache was last refreshed
    var fetchedAt: Date = Date()

    /// Cache time-to-live in seconds (5 minutes)
    static let ttlSeconds: TimeInterval = 300

    /// Check if the cache has expired
    var isExpired: Bool {
        Date().timeIntervalSince(fetchedAt) > Self.ttlSeconds
    }

    /// Age of cache in seconds
    var ageSeconds: Int {
        Int(Date().timeIntervalSince(fetchedAt))
    }

    /// Decode keys from stored data
    var keys: Set<String> {
        get {
            guard !keysData.isEmpty,
                  let array = try? JSONDecoder().decode([String].self, from: keysData) else {
                return []
            }
            return Set(array)
        }
        set {
            keysData = (try? JSONEncoder().encode(Array(newValue))) ?? Data()
        }
    }

    init(bucket: String, prefix: String, keys: Set<String>) {
        self.bucket = bucket
        self.prefix = prefix
        self.keys = keys
        self.fetchedAt = Date()
    }
}

// MARK: - ScannedFile

/// Tracks scanned files for incremental scanning.
/// Stores file path and modification date to detect changed files.
@Model
class ScannedFile {
    /// Full file path
    var path: String = ""

    /// File modification date (from filesystem)
    var modificationDate: Date = Date()

    /// Generated S3 key for this file
    var s3Key: String = ""

    /// Last known S3 existence status
    var existsInS3: Bool = false

    /// When this record was last checked
    var lastChecked: Date = Date()

    init(path: String, modificationDate: Date, s3Key: String) {
        self.path = path
        self.modificationDate = modificationDate
        self.s3Key = s3Key
        self.lastChecked = Date()
    }
}

// MARK: - Utilities

/// Utilities for sanitizing names for S3 keys and identifiers
enum UploadIdentifiers {
    /// Sanitize a string for use as an S3 key path component.
    /// Only allows A-Z, a-z, 0-9, and dashes.
    static func sanitizeS3Key(_ name: String, fallback: String = "Unknown") -> String {
        guard !name.isEmpty else { return fallback }

        // Replace spaces and underscores with dashes
        var sanitized = name.replacingOccurrences(of: " ", with: "-")
        sanitized = sanitized.replacingOccurrences(of: "_", with: "-")

        // Remove all characters except alphanumeric and dashes
        sanitized = sanitized.filter { $0.isLetter || $0.isNumber || $0 == "-" }

        // Collapse multiple dashes into single dash
        while sanitized.contains("--") {
            sanitized = sanitized.replacingOccurrences(of: "--", with: "-")
        }

        // Trim leading/trailing dashes
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return sanitized.isEmpty ? fallback : sanitized
    }

    /// Generate an album ID from artist and album names
    static func albumId(artist: String, album: String) -> String {
        let safeArtist = sanitizeS3Key(artist, fallback: "Unknown-Artist")
        let safeAlbum = sanitizeS3Key(album, fallback: "Unknown-Album")
        return "\(safeArtist)/\(safeAlbum)"
    }

    /// Generate an artist ID from artist name
    static func artistId(_ name: String) -> String {
        return sanitizeS3Key(name, fallback: "Unknown-Artist")
    }

    /// Extract the year from various date formats
    static func extractYear(_ dateValue: Any?) -> Int? {
        guard let dateValue else { return nil }

        if let intValue = dateValue as? Int {
            return intValue
        }

        if let stringValue = dateValue as? String {
            let trimmed = stringValue.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }

            // Try to extract year from beginning (handles YYYY, YYYY-MM, YYYY-MM-DD)
            let pattern = "^(\\d{4})"
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let range = Range(match.range(at: 1), in: trimmed) {
                return Int(trimmed[range])
            }
        }

        return nil
    }

    /// Normalize artist name by extracting first artist from multi-artist strings
    static func normalizeArtistName(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }

        if name.contains("/") {
            return name.components(separatedBy: "/").first?.trimmingCharacters(in: .whitespaces)
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Extract artist and album from folder structure when metadata is missing.
    /// Handles: /path/to/Artist/Album/Track.flac or /path/to/Artist/[E]  Album [123] [2024]/Track.flac
    /// Returns: (artist, album) cleaned of Tidal formatting
    static func extractFromFolderPath(_ fileURL: URL, scanFolderURL: URL) -> (artist: String?, album: String?) {
        // Get path relative to scan folder
        let filePath = fileURL.path
        let scanPath = scanFolderURL.path

        // If scan folder is the artist folder (e.g., /Tidal/Ab-Soul), extract artist from folder name
        let scanFolderName = scanFolderURL.lastPathComponent

        // Get relative path from scan folder to file
        guard filePath.hasPrefix(scanPath) else {
            return (nil, nil)
        }

        let relativePath = String(filePath.dropFirst(scanPath.count + 1)) // +1 for trailing /
        let parts = relativePath.components(separatedBy: "/")

        // Case 1: Scanning from artist folder (e.g., /Tidal/Ab-Soul)
        // Relative path: [E]  Album [123] [2024]/Track.flac
        // parts = ["[E]  Album [123] [2024]", "Track.flac"]
        if parts.count == 2 {
            let artist = scanFolderName // Use scan folder name as artist
            let album = cleanTidalFolderName(parts[0])
            return (artist, album)
        }

        // Case 2: Scanning from music root (e.g., /Tidal)
        // Relative path: Ab-Soul/[E]  Album [123] [2024]/Track.flac
        // parts = ["Ab-Soul", "[E]  Album [123] [2024]", "Track.flac"]
        if parts.count >= 3 {
            let artist = parts[0]
            let album = cleanTidalFolderName(parts[1])
            return (artist, album)
        }

        return (nil, nil)
    }

    /// Clean Tidal folder name by removing prefixes like "[E]  " and suffixes like "[123456] [2024]".
    /// Examples:
    ///   "[E]  Do What Thou Wilt [67884317] [2016]" -> "Do What Thou Wilt"
    ///   "[E]  These Days [305303726] [2014]" -> "These Days"
    static func cleanTidalFolderName(_ name: String) -> String {
        var cleaned = name.trimmingCharacters(in: .whitespaces)

        // Remove Tidal explicit marker prefix "[E]  " or "[E] "
        if let regex = try? NSRegularExpression(pattern: #"^\[E\]\s+"#, options: .caseInsensitive) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }

        // Remove ALL bracketed content (Tidal adds [ID] [Year])
        cleaned = cleaned.replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: "", options: .regularExpression)

        let result = cleaned.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? name : result
    }

    /// Clean album name by removing Tidal-style IDs, years, and edition suffixes.
    /// Examples:
    ///   " Sula Bassana [371430601] [2024]" -> "Sula Bassana"
    ///   "Album (Deluxe Edition) [2024]" -> "Album"
    ///   "[E]  Do What Thou Wilt [67884317] [2016]" -> "Do What Thou Wilt"
    static func cleanAlbumName(_ name: String) -> String {
        var cleaned = name.trimmingCharacters(in: .whitespaces)

        // Remove Tidal explicit marker prefix "[E]  " or "[E] " first
        if let regex = try? NSRegularExpression(pattern: #"^\[E\]\s+"#, options: .caseInsensitive) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }

        // Remove ALL bracketed content (Tidal adds [ID] [Year])
        cleaned = cleaned.replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: "", options: .regularExpression)

        // Remove common suffixes in parentheses
        let patterns = [
            #"\s*\([^)]*(?:deluxe|edition|remaster|bonus|expanded)[^)]*\)"#,
            #"\s*\([^)]*\d{4}[^)]*\)"#  // Year in parens like (2024)
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
        return result.isEmpty ? name : result
    }

    /// Clean track title by removing Tidal-style formatting.
    /// Examples:
    ///   "01 - Ab-Soul - RAW (backwards)" with artist "Ab-Soul" -> "RAW (backwards)"
    ///   "01 - 20syl - Tempest Ouverture" -> "Tempest Ouverture"
    ///   "9 Mile(Explicit)" -> "9 Mile"
    ///   "05. Artist - Song Name" -> "Song Name"
    ///   "1 Song Name" -> "Song Name"
    static func cleanTrackTitle(_ title: String, artist: String?) -> String {
        var cleaned = title.trimmingCharacters(in: .whitespaces)

        // Remove Tidal explicit marker suffix "(Explicit)" or "[Explicit]"
        if let regex = try? NSRegularExpression(pattern: #"\s*[\(\[]Explicit[\)\]]$"#, options: .caseInsensitive) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }

        // Priority 1: If we know the artist, use it for precise matching
        // Handles: "01 - Ab-Soul - RAW" where artist contains hyphens
        if let artist, !artist.isEmpty {
            let escapedArtist = NSRegularExpression.escapedPattern(for: artist)
            // Pattern: "01 - Artist - Title" or "01. Artist - Title"
            let artistPattern = #"^\d{1,2}\s*[\.\-]\s*"# + escapedArtist + #"\s*-\s*(.+)$"#
            if let regex = try? NSRegularExpression(pattern: artistPattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: cleaned) {
                return String(cleaned[range]).trimmingCharacters(in: .whitespaces)
            }
        }

        // Priority 2: "01 - Something" pattern, then strip artist if present
        if let regex = try? NSRegularExpression(pattern: #"^\d{1,2}\s*[\.\-]\s*(.+)$"#),
           let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: cleaned) {
            let result = String(cleaned[range]).trimmingCharacters(in: .whitespaces)

            // If result starts with artist name, remove it (handles unknown artist case)
            if let artist, !artist.isEmpty {
                let escapedArtist = NSRegularExpression.escapedPattern(for: artist)
                let artistPattern = "^\(escapedArtist)\\s*-\\s*"
                if let artistRegex = try? NSRegularExpression(pattern: artistPattern, options: .caseInsensitive) {
                    let strippedResult = artistRegex.stringByReplacingMatches(
                        in: result,
                        range: NSRange(result.startIndex..., in: result),
                        withTemplate: ""
                    ).trimmingCharacters(in: .whitespaces)
                    if !strippedResult.isEmpty {
                        return strippedResult
                    }
                }
            }

            // Fallback: try generic "Something - Title" pattern (for unknown artist)
            // Use last occurrence of " - " to handle hyphenated artist names
            if let lastDashRange = result.range(of: " - ", options: .backwards) {
                let afterDash = String(result[lastDashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !afterDash.isEmpty {
                    return afterDash
                }
            }

            return result
        }

        // Priority 3: "01 Title" (just track number prefix with space)
        if let regex = try? NSRegularExpression(pattern: #"^\d{1,2}\s+(.+)$"#),
           let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: cleaned) {
            return String(cleaned[range]).trimmingCharacters(in: .whitespaces)
        }

        return cleaned
    }
}
