//
//  Identifiers.swift
//  Music
//
//  Utilities for S3 key sanitization and identifier management.
//  Ported from backend/utils/identifiers.py
//

import Foundation

#if os(macOS)

enum Identifiers {

    // MARK: - S3 Key Sanitization

    /// Sanitize a string for use as an S3 key path component.
    ///
    /// - Parameters:
    ///   - name: The string to sanitize (artist, album, or track name)
    ///   - fallback: Value to use if name is empty after sanitization
    /// - Returns: A sanitized string safe for use in S3 keys (only A-Z, a-z, 0-9, and dashes)
    static func sanitizeS3Key(_ name: String, fallback: String = "Unknown") -> String {
        guard !name.isEmpty else { return fallback }

        // Replace spaces and underscores with dashes
        var sanitized = name.replacingOccurrences(
            of: "[\\s_]+",
            with: "-",
            options: .regularExpression
        )

        // Remove all characters except alphanumeric and dashes
        sanitized = sanitized.replacingOccurrences(
            of: "[^A-Za-z0-9-]",
            with: "",
            options: .regularExpression
        )

        // Collapse multiple dashes into single dash
        sanitized = sanitized.replacingOccurrences(
            of: "-+",
            with: "-",
            options: .regularExpression
        )

        // Trim leading/trailing dashes
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        // Handle empty result
        return sanitized.isEmpty ? fallback : sanitized
    }

    // MARK: - Year Extraction

    /// Extract the year as an integer from various date formats.
    ///
    /// Handles:
    /// - Integer year: 2024 -> 2024
    /// - String year: "2024" -> 2024
    /// - ISO date: "2024-01-15" -> 2024
    /// - Partial date: "2024-01" -> 2024
    ///
    /// - Parameter value: The date value to extract year from
    /// - Returns: The year as an integer, or nil if extraction fails
    static func extractYear(from value: Any?) -> Int? {
        guard let value = value else { return nil }

        if let intValue = value as? Int {
            return intValue
        }

        if let stringValue = value as? String {
            let trimmed = stringValue.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }

            // Try to extract year from beginning of string (handles YYYY, YYYY-MM, YYYY-MM-DD)
            let pattern = "^(\\d{4})"
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let range = Range(match.range(at: 1), in: trimmed) {
                return Int(trimmed[range])
            }
        }

        return nil
    }

    // MARK: - Artist Name Normalization

    /// Normalize artist name by extracting first artist from multi-artist strings.
    ///
    /// Splits by "/" and returns the first artist, stripped of whitespace.
    /// Example: "Justin Timberlake/50 Cent" -> "Justin Timberlake"
    ///
    /// - Parameter name: The artist name to normalize
    /// - Returns: Normalized artist name, or nil if input is nil
    static func normalizeArtistName(_ name: String?) -> String? {
        guard let name = name, !name.isEmpty else { return name }

        if name.contains("/") {
            return name.components(separatedBy: "/").first?.trimmingCharacters(in: .whitespaces)
        }

        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Get case-insensitive key for artist grouping.
    ///
    /// Example: "Afrojack" and "afrojack" -> "afrojack"
    ///
    /// - Parameter name: The artist name
    /// - Returns: Lowercased, normalized artist name for grouping
    static func getArtistGroupingKey(_ name: String) -> String {
        let normalized = normalizeArtistName(name)
        return normalized?.lowercased() ?? ""
    }

    // MARK: - S3 Key Generation

    /// Generate a complete S3 key for a track.
    ///
    /// - Parameters:
    ///   - artist: Artist name
    ///   - album: Album name (corrected/canonical name)
    ///   - title: Track title
    ///   - format: File format extension (e.g., "m4a", "mp3")
    /// - Returns: S3 key in format "Artist/Album/Title.format"
    static func generateS3Key(
        artist: String,
        album: String,
        title: String,
        format: String
    ) -> String {
        let safeArtist = sanitizeS3Key(artist, fallback: "Unknown-Artist")
        let safeAlbum = sanitizeS3Key(album, fallback: "Unknown-Album")
        let safeTitle = sanitizeS3Key(title, fallback: "Unknown-Track")
        return "\(safeArtist)/\(safeAlbum)/\(safeTitle).\(format)"
    }

    /// Generate S3 key for album cover artwork.
    ///
    /// - Parameters:
    ///   - artist: Artist name
    ///   - album: Album name
    /// - Returns: S3 key in format "Artist/Album/cover.jpg"
    static func generateCoverArtworkKey(artist: String, album: String) -> String {
        let safeArtist = sanitizeS3Key(artist, fallback: "Unknown-Artist")
        let safeAlbum = sanitizeS3Key(album, fallback: "Unknown-Album")
        return "\(safeArtist)/\(safeAlbum)/cover.jpg"
    }

    /// Generate S3 key for embedded artwork.
    ///
    /// - Parameters:
    ///   - artist: Artist name
    ///   - album: Album name
    ///   - mimeType: MIME type of the image (determines extension)
    /// - Returns: S3 key in format "Artist/Album/embedded.jpg" or "embedded.png"
    static func generateEmbeddedArtworkKey(artist: String, album: String, mimeType: String) -> String {
        let safeArtist = sanitizeS3Key(artist, fallback: "Unknown-Artist")
        let safeAlbum = sanitizeS3Key(album, fallback: "Unknown-Album")
        let ext = mimeType.contains("png") ? "png" : "jpg"
        return "\(safeArtist)/\(safeAlbum)/embedded.\(ext)"
    }

    /// Generate S3 key for artist image.
    ///
    /// - Parameter artist: Artist name
    /// - Returns: S3 key in format "Artist/artist.jpg"
    static func generateArtistImageKey(artist: String) -> String {
        let safeArtist = sanitizeS3Key(artist, fallback: "Unknown-Artist")
        return "\(safeArtist)/artist.jpg"
    }
}

#endif
