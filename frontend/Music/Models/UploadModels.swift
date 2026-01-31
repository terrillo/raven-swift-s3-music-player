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
}
