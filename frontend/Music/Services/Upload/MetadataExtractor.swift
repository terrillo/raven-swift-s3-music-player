//
//  MetadataExtractor.swift
//  Music
//
//  Extracts audio metadata from files using AVAsset.
//  Supports mp3, m4a, flac, wav, aac.
//

import Foundation
import AVFoundation

#if os(macOS)

/// Extracted track metadata
struct TrackMetadata: Codable {
    var title: String
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var discTotal: Int?
    var duration: Int?
    var year: Int?
    var genre: String?
    var composer: String?
    var comment: String?
    var bitrate: Double?
    var samplerate: Int?
    var channels: Int?
    var filesize: Int?
    var format: String
}

/// Cached metadata entry with modification date for invalidation
struct CachedMetadataEntry: Codable {
    let metadata: TrackMetadata
    let modificationDate: Date
}

actor MetadataExtractor {
    private let musicDirectory: URL
    private var cache: [String: CachedMetadataEntry] = [:]
    private static let cacheFileName = "metadata_cache.json"

    init(musicDirectory: URL) {
        self.musicDirectory = musicDirectory
        self.cache = Self.loadCacheFromDisk()
    }

    // MARK: - Cache Management

    private static var cacheFileURL: URL {
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(cacheFileName)
        }
        return cacheDir.appendingPathComponent(cacheFileName)
    }

    private static func loadCacheFromDisk() -> [String: CachedMetadataEntry] {
        do {
            let data = try Data(contentsOf: cacheFileURL)
            return try JSONDecoder().decode([String: CachedMetadataEntry].self, from: data)
        } catch {
            // No cache or invalid cache - start fresh
            return [:]
        }
    }

    func saveCache() {
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: Self.cacheFileURL)
        } catch {
            print("⚠️ Failed to save metadata cache: \(error.localizedDescription)")
        }
    }

    private func getCachedMetadata(for fileURL: URL) -> TrackMetadata? {
        let key = fileURL.path

        guard let entry = cache[key] else { return nil }

        // Check if file has been modified since caching
        guard let modDate = getFileModificationDate(fileURL) else { return nil }

        // Use 1-second tolerance for date comparison (avoids sub-second precision issues)
        if abs(entry.modificationDate.timeIntervalSince(modDate)) < 1.0 {
            return entry.metadata
        }

        // File was modified - invalidate cache
        cache.removeValue(forKey: key)
        return nil
    }

    private func cacheMetadata(_ metadata: TrackMetadata, for fileURL: URL) {
        guard let modDate = getFileModificationDate(fileURL) else { return }

        let entry = CachedMetadataEntry(metadata: metadata, modificationDate: modDate)
        cache[fileURL.path] = entry
    }

    private func getFileModificationDate(_ fileURL: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
    }

    // MARK: - Metadata Extraction

    /// Extract metadata from an audio file using AVAsset (with caching)
    func extract(from fileURL: URL) async -> TrackMetadata {
        // Check cache first
        if let cached = getCachedMetadata(for: fileURL) {
            return cached
        }

        let metadata = await extractFromFile(fileURL)
        cacheMetadata(metadata, for: fileURL)
        return metadata
    }

    /// Extract metadata directly from file (no cache check)
    private func extractFromFile(_ fileURL: URL) async -> TrackMetadata {
        let asset = AVURLAsset(url: fileURL)
        let format = fileURL.pathExtension.lowercased()

        // Get file size
        let filesize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil

        // Get duration
        var duration: Int?
        do {
            let durationTime = try await asset.load(.duration)
            if durationTime.isValid && !durationTime.isIndefinite {
                duration = Int(CMTimeGetSeconds(durationTime))
            }
        } catch {
            // Duration not available
        }

        // Load metadata
        var metadata: [AVMetadataItem] = []
        do {
            metadata = try await asset.load(.metadata)
        } catch {
            // Metadata not available, use fallbacks
        }

        // Extract metadata values
        let title = metadataValue(from: metadata, identifier: .commonIdentifierTitle)
            ?? fileURL.deletingPathExtension().lastPathComponent

        let artist = metadataValue(from: metadata, identifier: .commonIdentifierArtist)
        let album = metadataValue(from: metadata, identifier: .commonIdentifierAlbumName)
        let albumArtist = metadataValue(from: metadata, identifier: .iTunesMetadataAlbumArtist)
            ?? metadataValue(from: metadata, key: "TPE2", keySpace: .id3)  // ID3v2 album artist
        let genre = metadataValue(from: metadata, identifier: .commonIdentifierType)
            ?? metadataValue(from: metadata, key: "TCON", keySpace: .id3)  // ID3v2 content type
        let composer = metadataValue(from: metadata, identifier: .commonIdentifierCreator)
            ?? metadataValue(from: metadata, key: "TCOM", keySpace: .id3)  // ID3v2 composer

        // Parse track number (may be "1/10" format or just "1")
        let (trackNum, trackTotal) = parseTrackNumber(
            metadataValue(from: metadata, key: "TRCK", keySpace: .id3)
            ?? metadataValue(from: metadata, identifier: .iTunesMetadataTrackNumber)
        )

        // Parse disc number
        let (discNum, discTotal) = parseTrackNumber(
            metadataValue(from: metadata, key: "TPOS", keySpace: .id3)
            ?? metadataValue(from: metadata, identifier: .iTunesMetadataDiscNumber)
        )

        // Extract year
        let yearString = metadataValue(from: metadata, identifier: .commonIdentifierCreationDate)
            ?? metadataValue(from: metadata, key: "TDRC", keySpace: .id3)  // ID3v2 recording time
            ?? metadataValue(from: metadata, key: "TYER", keySpace: .id3)  // ID3v2 year
        let year = Identifiers.extractYear(from: yearString)

        // Extract comment
        let comment = metadataValue(from: metadata, identifier: .commonIdentifierDescription)
            ?? metadataValue(from: metadata, key: "COMM", keySpace: .id3)  // ID3v2 comment

        // Get audio properties
        var bitrate: Double?
        var samplerate: Int?
        var channels: Int?

        do {
            let tracks = try await asset.load(.tracks)
            if let audioTrack = tracks.first(where: { $0.mediaType == .audio }) {
                let formatDescriptions = try await audioTrack.load(.formatDescriptions)
                if let formatDesc = formatDescriptions.first {
                    let basicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
                    if let desc = basicDesc?.pointee {
                        samplerate = Int(desc.mSampleRate)
                        channels = Int(desc.mChannelsPerFrame)
                    }
                }

                // Estimate bitrate from file size and duration
                if let duration = duration, duration > 0, let filesize = filesize {
                    bitrate = Double(filesize * 8) / Double(duration) / 1000.0  // kbps
                }
            }
        } catch {
            // Audio properties not available
        }

        var resultMetadata = TrackMetadata(
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            trackNumber: trackNum,
            trackTotal: trackTotal,
            discNumber: discNum,
            discTotal: discTotal,
            duration: duration,
            year: year,
            genre: genre,
            composer: composer,
            comment: comment,
            bitrate: bitrate,
            samplerate: samplerate,
            channels: channels,
            filesize: filesize,
            format: format
        )

        // Apply fallbacks from directory structure
        return applyFallbacks(to: resultMetadata, fileURL: fileURL)
    }

    // MARK: - Helper Methods

    private func metadataValue(from metadata: [AVMetadataItem], identifier: AVMetadataIdentifier) -> String? {
        let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier)
        return items.first?.stringValue?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    private func metadataValue(from metadata: [AVMetadataItem], key: String, keySpace: AVMetadataKeySpace) -> String? {
        let items = AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: keySpace)
        return items.first?.stringValue?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    /// Parse track number from "1/10" or "1" format
    private func parseTrackNumber(_ value: String?) -> (Int?, Int?) {
        guard let value = value else { return (nil, nil) }

        if value.contains("/") {
            let parts = value.components(separatedBy: "/")
            guard let first = parts.first else { return (nil, nil) }
            let num = Int(first.trimmingCharacters(in: CharacterSet.whitespaces))
            let total = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: CharacterSet.whitespaces)) : nil
            return (num, total)
        }

        return (Int(value.trimmingCharacters(in: CharacterSet.whitespaces)), nil)
    }

    /// Apply fallback extraction from filename and directory structure
    private func applyFallbacks(to metadata: TrackMetadata, fileURL: URL) -> TrackMetadata {
        var result = metadata

        // Fallback: extract track number from filename (e.g., "01 Song Name.mp3")
        if result.trackNumber == nil {
            let filename = fileURL.deletingPathExtension().lastPathComponent
            if let match = filename.range(of: #"^(\d+)\s+"#, options: .regularExpression) {
                let numStr = filename[match].trimmingCharacters(in: CharacterSet.whitespaces)
                result.trackNumber = Int(numStr)
            }
        }

        // Fallback: extract artist/album from directory structure
        // Expected structure: music/Artist/Album/Track.mp3
        let relativePath = fileURL.path.replacingOccurrences(of: musicDirectory.path + "/", with: "")
        let parts = relativePath.components(separatedBy: "/")
        if parts.count >= 3 {
            if result.artist == nil, let artistPart = parts.first {
                result.artist = artistPart
            }
            if result.album == nil, parts.count >= 2 {
                result.album = parts[1]
            }
        }

        return result
    }
}

#endif
