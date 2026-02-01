//
//  MetadataService.swift
//  Music
//
//  Extracts metadata from audio files using AVFoundation.
//

import Foundation
import AVFoundation
import SwiftData

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
    /// Uses AVFoundation with ffprobe fallback for FLAC files.
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
        var avFoundationSucceeded = false

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

            avFoundationSucceeded = true
        } catch {
            print("Failed to load metadata from \(fileURL.lastPathComponent): \(error)")
        }

        // FLAC fallback: Use ffprobe if AVFoundation failed or returned incomplete metadata
        #if os(macOS)
        if format == "flac" && (metadata.artist == nil || metadata.album == nil || !avFoundationSucceeded) {
            if let ffprobeMetadata = await extractWithFFprobe(from: fileURL) {
                metadata = mergeMetadata(primary: ffprobeMetadata, fallback: metadata)
                print("[MetadataService] Used ffprobe fallback for FLAC: \(fileURL.lastPathComponent)")
            }
        }
        #endif

        return metadata
    }

    #if os(macOS)
    // MARK: - FFprobe Fallback

    /// Extract metadata using ffprobe (fallback for FLAC files).
    private func extractWithFFprobe(from fileURL: URL) async -> ExtractedMetadata? {
        // Try common ffprobe locations
        let ffprobePaths = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe"
        ]

        var ffprobePath: String?
        for path in ffprobePaths {
            if FileManager.default.fileExists(atPath: path) {
                ffprobePath = path
                break
            }
        }

        guard let ffprobePath else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffprobePath)
                process.arguments = [
                    "-v", "quiet",
                    "-print_format", "json",
                    "-show_format",
                    "-show_streams",
                    fileURL.path
                ]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let result = self.parseFFprobeOutput(data, format: fileURL.pathExtension.lowercased()) {
                        continuation.resume(returning: result)
                        return
                    }
                } catch {
                    print("[MetadataService] ffprobe failed: \(error)")
                }

                continuation.resume(returning: nil)
            }
        }
    }

    /// Parse ffprobe JSON output into ExtractedMetadata.
    private func parseFFprobeOutput(_ data: Data, format: String) -> ExtractedMetadata? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formatInfo = json["format"] as? [String: Any] else {
            return nil
        }

        // Get tags from format section
        let tags = formatInfo["tags"] as? [String: Any] ?? [:]

        // Helper to get case-insensitive tag
        func getTag(_ key: String) -> String? {
            // Try exact match first
            if let value = tags[key] as? String, !value.isEmpty {
                return value
            }
            // Try case-insensitive
            let lowerKey = key.lowercased()
            for (k, v) in tags {
                if k.lowercased() == lowerKey, let str = v as? String, !str.isEmpty {
                    return str
                }
            }
            return nil
        }

        var metadata = ExtractedMetadata(
            title: getTag("TITLE") ?? getTag("title") ?? "",
            format: format
        )

        metadata.artist = getTag("ARTIST") ?? getTag("artist")
        metadata.album = getTag("ALBUM") ?? getTag("album")
        metadata.albumArtist = getTag("ALBUMARTIST") ?? getTag("album_artist")
        metadata.genre = getTag("GENRE") ?? getTag("genre")
        metadata.composer = getTag("COMPOSER") ?? getTag("composer")
        metadata.comment = getTag("COMMENT") ?? getTag("comment")

        // Track number (may be "1/12" format)
        if let trackStr = getTag("TRACKNUMBER") ?? getTag("track") {
            let parts = trackStr.components(separatedBy: "/")
            metadata.trackNumber = Int(parts[0].trimmingCharacters(in: .whitespaces))
            if parts.count > 1 {
                metadata.trackTotal = Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }

        // Disc number
        if let discStr = getTag("DISCNUMBER") ?? getTag("disc") {
            let parts = discStr.components(separatedBy: "/")
            metadata.discNumber = Int(parts[0].trimmingCharacters(in: .whitespaces))
            if parts.count > 1 {
                metadata.discTotal = Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }

        // Year/Date
        if let dateStr = getTag("DATE") ?? getTag("date") ?? getTag("YEAR") ?? getTag("year") {
            metadata.year = UploadIdentifiers.extractYear(dateStr)
        }

        // Duration (in seconds)
        if let durationStr = formatInfo["duration"] as? String,
           let duration = Double(durationStr) {
            metadata.duration = Int(duration)
        }

        // Get audio stream info
        if let streams = json["streams"] as? [[String: Any]] {
            for stream in streams {
                if stream["codec_type"] as? String == "audio" {
                    if let sampleRate = stream["sample_rate"] as? String {
                        metadata.samplerate = Int(sampleRate)
                    }
                    if let channels = stream["channels"] as? Int {
                        metadata.channels = channels
                    }
                    break
                }
            }
        }

        // File size
        if let sizeStr = formatInfo["size"] as? String {
            metadata.filesize = Int(sizeStr)
        }

        // Calculate bitrate
        if let bitrateStr = formatInfo["bit_rate"] as? String,
           let bitrate = Double(bitrateStr) {
            metadata.bitrate = bitrate / 1000.0  // Convert to kbps
        }

        return metadata
    }

    /// Merge metadata, preferring primary values over fallback.
    private func mergeMetadata(primary: ExtractedMetadata, fallback: ExtractedMetadata) -> ExtractedMetadata {
        var result = primary

        // Use fallback title if primary is empty
        if result.title.isEmpty {
            result.title = fallback.title
        }

        // Merge optional fields (prefer primary)
        result.artist = result.artist ?? fallback.artist
        result.album = result.album ?? fallback.album
        result.albumArtist = result.albumArtist ?? fallback.albumArtist
        result.trackNumber = result.trackNumber ?? fallback.trackNumber
        result.trackTotal = result.trackTotal ?? fallback.trackTotal
        result.discNumber = result.discNumber ?? fallback.discNumber
        result.discTotal = result.discTotal ?? fallback.discTotal
        result.duration = result.duration ?? fallback.duration
        result.year = result.year ?? fallback.year
        result.genre = result.genre ?? fallback.genre
        result.composer = result.composer ?? fallback.composer
        result.comment = result.comment ?? fallback.comment
        result.format = primary.format  // Always use primary format
        result.bitrate = result.bitrate ?? fallback.bitrate
        result.samplerate = result.samplerate ?? fallback.samplerate
        result.channels = result.channels ?? fallback.channels
        result.filesize = result.filesize ?? fallback.filesize
        result.artworkData = result.artworkData ?? fallback.artworkData
        result.artworkMimeType = result.artworkMimeType ?? fallback.artworkMimeType

        return result
    }
    #endif

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

    #if os(macOS)
    // MARK: - Incremental Scanning

    /// Result of incremental scan comparing to previously scanned files.
    struct IncrementalScanResult {
        var newFiles: [URL]       // Never seen before
        var changedFiles: [URL]   // Modified since last scan
        var unchangedFiles: [URL] // Same modification date
        var deletedPaths: [String] // Previously scanned but no longer exist

        var totalFiles: Int { newFiles.count + changedFiles.count + unchangedFiles.count }
        var filesToProcess: [URL] { newFiles + changedFiles }
    }

    /// Scan directory incrementally, tracking file modification dates in SwiftData.
    /// Only processes new or changed files.
    func scanDirectoryIncremental(
        _ directory: URL,
        modelContainer: ModelContainer,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> IncrementalScanResult {
        print("[MetadataService] Incremental scan for: \(directory.path)")

        // Fetch all previously scanned files
        let previousScans: [String: ScannedFile] = MainActor.assumeIsolated {
            let context = modelContainer.mainContext
            let descriptor = FetchDescriptor<ScannedFile>()
            let scans = (try? context.fetch(descriptor)) ?? []
            return Dictionary(uniqueKeysWithValues: scans.map { ($0.path, $0) })
        }
        print("[MetadataService] Found \(previousScans.count) previously scanned files")

        // Scan current directory
        var newFiles: [URL] = []
        var changedFiles: [URL] = []
        var unchangedFiles: [URL] = []
        var currentPaths = Set<String>()

        let didStartAccess = directory.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                directory.stopAccessingSecurityScopedResource()
            }
        }

        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        )

        var totalFilesChecked = 0
        var lastProgressUpdate = 0

        while let url = enumerator?.nextObject() as? URL {
            totalFilesChecked += 1

            if totalFilesChecked - lastProgressUpdate >= 100 {
                progress?(totalFilesChecked, newFiles.count + changedFiles.count)
                lastProgressUpdate = totalFilesChecked
            }

            guard let resourceValues = try? url.resourceValues(forKeys: Set(resourceKeys)),
                  resourceValues.isRegularFile == true else {
                continue
            }

            guard Self.isSupportedFormat(url) else {
                continue
            }

            let path = url.path
            currentPaths.insert(path)

            let modDate = resourceValues.contentModificationDate ?? Date()

            if let existingScan = previousScans[path] {
                // Check if modified
                if existingScan.modificationDate == modDate {
                    unchangedFiles.append(url)
                } else {
                    changedFiles.append(url)
                }
            } else {
                newFiles.append(url)
            }
        }

        // Find deleted files
        let deletedPaths = previousScans.keys.filter { !currentPaths.contains($0) }

        print("[MetadataService] Incremental scan results:")
        print("[MetadataService]   New files: \(newFiles.count)")
        print("[MetadataService]   Changed files: \(changedFiles.count)")
        print("[MetadataService]   Unchanged files: \(unchangedFiles.count)")
        print("[MetadataService]   Deleted files: \(deletedPaths.count)")

        return IncrementalScanResult(
            newFiles: newFiles.sorted { $0.path < $1.path },
            changedFiles: changedFiles.sorted { $0.path < $1.path },
            unchangedFiles: unchangedFiles.sorted { $0.path < $1.path },
            deletedPaths: Array(deletedPaths)
        )
    }

    /// Update the scanned file cache after processing.
    func updateScannedFileCache(
        _ files: [(url: URL, s3Key: String, existsInS3: Bool)],
        modelContainer: ModelContainer
    ) {
        MainActor.assumeIsolated {
            let context = modelContainer.mainContext

            for (url, s3Key, existsInS3) in files {
                let path = url.path

                // Get modification date
                let modDate: Date
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let date = attrs[.modificationDate] as? Date {
                    modDate = date
                } else {
                    modDate = Date()
                }

                // Check for existing record
                let descriptor = FetchDescriptor<ScannedFile>(
                    predicate: #Predicate { $0.path == path }
                )

                if let existing = try? context.fetch(descriptor).first {
                    // Update existing
                    existing.modificationDate = modDate
                    existing.s3Key = s3Key
                    existing.existsInS3 = existsInS3
                    existing.lastChecked = Date()
                } else {
                    // Create new
                    let scanned = ScannedFile(path: path, modificationDate: modDate, s3Key: s3Key)
                    scanned.existsInS3 = existsInS3
                    context.insert(scanned)
                }
            }

            try? context.save()
        }
    }

    /// Remove deleted files from the scanned file cache.
    func removeFromScannedFileCache(_ paths: [String], modelContainer: ModelContainer) {
        MainActor.assumeIsolated {
            let context = modelContainer.mainContext

            for path in paths {
                let descriptor = FetchDescriptor<ScannedFile>(
                    predicate: #Predicate { $0.path == path }
                )

                if let existing = try? context.fetch(descriptor).first {
                    context.delete(existing)
                }
            }

            try? context.save()
        }
    }
    #endif
}
