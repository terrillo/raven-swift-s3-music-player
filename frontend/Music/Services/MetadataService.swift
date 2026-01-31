//
//  MetadataService.swift
//  Music
//
//  Extracts metadata from audio files using AVFoundation.
//

import Foundation
import AVFoundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Track Metadata

/// Metadata extracted from an audio file.
struct ExtractedMetadata {
    var title: String
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
    var composer: String?
    var comment: String?
    var format: String
    var bitrate: Double?  // kbps
    var samplerate: Int?  // Hz
    var channels: Int?
    var filesize: Int?  // bytes

    /// Embedded artwork data
    var artworkData: Data?
    var artworkMimeType: String?
}

// MARK: - MetadataService

/// Service for extracting metadata from audio files using AVFoundation.
class MetadataService {
    private let musicDirectory: URL

    init(musicDirectory: URL) {
        self.musicDirectory = musicDirectory
    }

    // MARK: - Supported Formats

    static let supportedExtensions: Set<String> = ["mp3", "m4a", "flac", "wav", "aac", "aiff"]

    /// Check if a file is a supported audio format.
    static func isSupportedFormat(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Metadata Extraction

    /// Extract metadata from an audio file.
    func extract(from fileURL: URL) async -> ExtractedMetadata {
        let format = fileURL.pathExtension.lowercased()

        // Get file attributes
        var filesize: Int?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int {
            filesize = size
        }

        // Create default metadata with fallbacks
        var metadata = ExtractedMetadata(
            title: fileURL.deletingPathExtension().lastPathComponent,
            format: format,
            filesize: filesize
        )

        // Apply directory structure fallbacks
        applyDirectoryFallbacks(to: &metadata, fileURL: fileURL)

        // Try to extract metadata using AVFoundation
        let asset = AVURLAsset(url: fileURL)

        // Load asset properties
        do {
            // Get duration
            let duration = try await asset.load(.duration)
            metadata.duration = Int(CMTimeGetSeconds(duration))

            // Get format details from tracks
            let tracks = try await asset.load(.tracks)
            if let audioTrack = tracks.first(where: { $0.mediaType == .audio }) {
                let formatDescriptions = try await audioTrack.load(.formatDescriptions)
                if let formatDesc = formatDescriptions.first {
                    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
                    metadata.samplerate = Int(asbd?.mSampleRate ?? 0)
                    metadata.channels = Int(asbd?.mChannelsPerFrame ?? 0)
                }

                // Estimate bitrate from file size and duration
                if let filesize = metadata.filesize, let duration = metadata.duration, duration > 0 {
                    metadata.bitrate = Double(filesize * 8) / Double(duration) / 1000.0
                }
            }

            // Get metadata items
            let commonMetadata = try await asset.load(.commonMetadata)
            extractCommonMetadata(commonMetadata, into: &metadata)

            // Also try format-specific metadata for better coverage
            let formatMetadata = try await asset.load(.metadata)
            extractFormatMetadata(formatMetadata, into: &metadata)

        } catch {
            print("Failed to load metadata from \(fileURL.lastPathComponent): \(error)")
        }

        return metadata
    }

    // MARK: - Common Metadata

    private func extractCommonMetadata(_ items: [AVMetadataItem], into metadata: inout ExtractedMetadata) {
        for item in items {
            guard let key = item.commonKey else { continue }

            switch key {
            case .commonKeyTitle:
                if let value = item.stringValue, !value.isEmpty {
                    metadata.title = value
                }
            case .commonKeyArtist:
                if let value = item.stringValue, !value.isEmpty {
                    metadata.artist = value
                }
            case .commonKeyAlbumName:
                if let value = item.stringValue, !value.isEmpty {
                    metadata.album = value
                }
            case .commonKeyCreationDate:
                if let value = item.stringValue {
                    metadata.year = UploadIdentifiers.extractYear(value)
                }
            case .commonKeyArtwork:
                extractArtwork(from: item, into: &metadata)
            default:
                break
            }
        }
    }

    // MARK: - Format-Specific Metadata

    private func extractFormatMetadata(_ items: [AVMetadataItem], into metadata: inout ExtractedMetadata) {
        for item in items {
            guard let keyString = item.key as? String ?? (item.key as? Int).map({ String($0) }) else { continue }

            // ID3 tags (MP3)
            if keyString == "TCOM" || keyString == "composer" {
                if let value = item.stringValue, !value.isEmpty {
                    metadata.composer = value
                }
            } else if keyString == "TCON" || keyString == "genre" {
                if let value = item.stringValue, !value.isEmpty {
                    metadata.genre = value
                }
            } else if keyString == "TRCK" || keyString == "trackNumber" {
                if let value = item.stringValue {
                    let parsed = parseTrackNumber(value)
                    if metadata.trackNumber == nil { metadata.trackNumber = parsed.0 }
                    if metadata.trackTotal == nil { metadata.trackTotal = parsed.1 }
                }
            } else if keyString == "TPOS" || keyString == "discNumber" {
                if let value = item.stringValue {
                    let parsed = parseTrackNumber(value)
                    if metadata.discNumber == nil { metadata.discNumber = parsed.0 }
                    if metadata.discTotal == nil { metadata.discTotal = parsed.1 }
                }
            } else if keyString == "TPE2" || keyString == "albumArtist" {
                if let value = item.stringValue, !value.isEmpty {
                    metadata.albumArtist = value
                }
            } else if keyString == "COMM" || keyString == "comment" {
                if let value = item.stringValue, !value.isEmpty {
                    metadata.comment = value
                }
            } else if keyString == "APIC" || keyString == "artwork" {
                extractArtwork(from: item, into: &metadata)
            }

            // iTunes/M4A atoms
            if let identifier = item.identifier {
                let idString = identifier.rawValue

                if idString.contains("trkn") {
                    if let data = item.dataValue {
                        let parsed = parseITunesTrackNumber(data)
                        if metadata.trackNumber == nil { metadata.trackNumber = parsed.0 }
                        if metadata.trackTotal == nil { metadata.trackTotal = parsed.1 }
                    }
                } else if idString.contains("disk") {
                    if let data = item.dataValue {
                        let parsed = parseITunesTrackNumber(data)
                        if metadata.discNumber == nil { metadata.discNumber = parsed.0 }
                        if metadata.discTotal == nil { metadata.discTotal = parsed.1 }
                    }
                } else if idString.contains("aART") {
                    if let value = item.stringValue, !value.isEmpty {
                        metadata.albumArtist = value
                    }
                } else if idString.contains("gnre") || idString.contains("©gen") {
                    if let value = item.stringValue, !value.isEmpty {
                        metadata.genre = value
                    }
                } else if idString.contains("©wrt") {
                    if let value = item.stringValue, !value.isEmpty {
                        metadata.composer = value
                    }
                } else if idString.contains("©day") {
                    if let value = item.stringValue {
                        metadata.year = UploadIdentifiers.extractYear(value)
                    }
                } else if idString.contains("covr") {
                    extractArtwork(from: item, into: &metadata)
                }
            }
        }
    }

    // MARK: - Artwork Extraction

    private func extractArtwork(from item: AVMetadataItem, into metadata: inout ExtractedMetadata) {
        // Skip if we already have artwork
        guard metadata.artworkData == nil else { return }

        if let data = item.dataValue, !data.isEmpty {
            metadata.artworkData = data
            metadata.artworkMimeType = detectImageMimeType(data)
        } else if let value = item.value {
            #if os(macOS)
            if let image = value as? NSImage, let tiffData = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
                metadata.artworkData = jpegData
                metadata.artworkMimeType = "image/jpeg"
            }
            #else
            if let image = value as? UIImage, let jpegData = image.jpegData(compressionQuality: 0.9) {
                metadata.artworkData = jpegData
                metadata.artworkMimeType = "image/jpeg"
            }
            #endif
        }
    }

    private func detectImageMimeType(_ data: Data) -> String {
        guard data.count > 4 else { return "image/jpeg" }

        let bytes = [UInt8](data.prefix(4))

        // Check for PNG signature
        if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
            return "image/png"
        }

        // Check for JPEG signature
        if bytes[0] == 0xFF && bytes[1] == 0xD8 {
            return "image/jpeg"
        }

        // Check for WebP signature
        if data.count > 12 {
            let webpBytes = [UInt8](data.prefix(12))
            if webpBytes[0] == 0x52 && webpBytes[1] == 0x49 && webpBytes[2] == 0x46 && webpBytes[3] == 0x46 &&
               webpBytes[8] == 0x57 && webpBytes[9] == 0x45 && webpBytes[10] == 0x42 && webpBytes[11] == 0x50 {
                return "image/webp"
            }
        }

        return "image/jpeg"
    }

    // MARK: - Track Number Parsing

    private func parseTrackNumber(_ value: String) -> (Int?, Int?) {
        let parts = value.components(separatedBy: "/")
        let trackNum = parts.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let trackTotal = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        return (trackNum, trackTotal)
    }

    private func parseITunesTrackNumber(_ data: Data) -> (Int?, Int?) {
        // iTunes track number is stored as 8 bytes:
        // 2 bytes: unused
        // 2 bytes: track number (big endian)
        // 2 bytes: track total (big endian)
        // 2 bytes: unused
        guard data.count >= 6 else { return (nil, nil) }

        let trackNum = Int(data[2]) << 8 | Int(data[3])
        let trackTotal = Int(data[4]) << 8 | Int(data[5])

        return (trackNum > 0 ? trackNum : nil, trackTotal > 0 ? trackTotal : nil)
    }

    // MARK: - Directory Fallbacks

    private func applyDirectoryFallbacks(to metadata: inout ExtractedMetadata, fileURL: URL) {
        // Extract track number from filename (e.g., "01 Song Name.mp3")
        let filename = fileURL.deletingPathExtension().lastPathComponent
        if let match = filename.range(of: "^(\\d+)\\s+", options: .regularExpression) {
            let numStr = filename[match].trimmingCharacters(in: .whitespaces)
            if let num = Int(numStr) {
                metadata.trackNumber = num
            }
        }

        // Extract artist/album from directory structure: music/Artist/Album/Track.mp3
        do {
            let relativePath = fileURL.path.replacingOccurrences(of: musicDirectory.path + "/", with: "")
            let parts = relativePath.components(separatedBy: "/")

            if parts.count >= 3 {
                if metadata.artist == nil {
                    metadata.artist = parts[0]
                }
                if metadata.album == nil {
                    metadata.album = parts[1]
                }
            }
        }
    }

    // MARK: - Scan Directory

    // TODO: Remove after testing - temporary limit for development
    private static let testFileLimit = 500

    /// Scan a directory for audio files with progress callback.
    func scanDirectory(_ directory: URL, progress: ((Int, Int) -> Void)? = nil) throws -> [URL] {
        var audioFiles: [URL] = []

        print("[MetadataService] scanDirectory called for: \(directory.path)")
        print("[MetadataService] Directory exists: \(FileManager.default.fileExists(atPath: directory.path))")
        print("[MetadataService] Is readable: \(FileManager.default.isReadableFile(atPath: directory.path))")

        // Start accessing security-scoped resource if needed
        let didStartAccess = directory.startAccessingSecurityScopedResource()
        print("[MetadataService] Started security-scoped access: \(didStartAccess)")

        defer {
            if didStartAccess {
                directory.stopAccessingSecurityScopedResource()
            }
        }

        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        )

        print("[MetadataService] Enumerator created: \(enumerator != nil)")

        var totalFilesChecked = 0
        var lastProgressUpdate = 0
        while let url = enumerator?.nextObject() as? URL {
            // TODO: Remove after testing - stop early if limit reached
            if audioFiles.count >= Self.testFileLimit {
                print("[MetadataService] TEST MODE: Stopping scan at \(Self.testFileLimit) audio files")
                break
            }

            totalFilesChecked += 1

            // Report progress every 100 files
            if totalFilesChecked - lastProgressUpdate >= 100 {
                progress?(totalFilesChecked, audioFiles.count)
                lastProgressUpdate = totalFilesChecked
                print("[MetadataService] Scanning... \(totalFilesChecked) items checked, \(audioFiles.count) audio files found")
            }

            guard let resourceValues = try? url.resourceValues(forKeys: Set(resourceKeys)),
                  resourceValues.isRegularFile == true else {
                continue
            }

            if Self.isSupportedFormat(url) {
                audioFiles.append(url)
            }
        }

        print("[MetadataService] Total items enumerated: \(totalFilesChecked)")
        print("[MetadataService] Audio files found: \(audioFiles.count)")

        return audioFiles.sorted { $0.path < $1.path }
    }
}
