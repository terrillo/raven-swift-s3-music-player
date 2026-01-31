//
//  UploadService.swift
//  Music
//
//  Orchestrates the upload workflow: scan folder, extract metadata,
//  fetch API corrections, convert formats, upload to S3, save to SwiftData.
//

import Foundation
import SwiftData

#if os(macOS)

// MARK: - Upload Progress

/// Progress information for an upload operation.
struct UploadProgress {
    var totalFiles: Int = 0
    var completedFiles: Int = 0
    var currentFile: String = ""
    var currentPhase: UploadPhase = .idle

    var progress: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(completedFiles) / Double(totalFiles)
    }
}

enum UploadPhase: String {
    case idle = "Idle"
    case scanning = "Scanning..."
    case extractingMetadata = "Extracting metadata..."
    case fetchingApiData = "Fetching metadata from APIs..."
    case converting = "Converting..."
    case uploading = "Uploading..."
    case savingDatabase = "Saving to database..."
    case completed = "Completed"
    case cancelled = "Cancelled"
    case failed = "Failed"
}

// MARK: - Upload Result

struct UploadResult {
    var uploaded: Int = 0
    var skipped: Int = 0
    var failed: Int = 0
    var errors: [String] = []
}

// MARK: - Upload Preparation

/// Result of comparing local folder to remote S3.
struct UploadPreparation {
    var filesToUpload: [URL]      // New files to upload
    var filesToSkip: [URL]        // Already exist in S3
    var totalLocalFiles: Int
    var folderURL: URL
    var cachedS3Keys: Set<String> // Cached for use during upload
}

// MARK: - UploadService

/// Service that orchestrates the upload workflow.
@MainActor
@Observable
class UploadService {
    private(set) var progress = UploadProgress()
    private(set) var isUploading = false
    private(set) var isPreparing = false
    private(set) var preparationResult: UploadPreparation?
    private(set) var preparationProgress: Double = 0
    private(set) var preparationStatus: String = ""
    private(set) var lastResult: UploadResult?
    var error: Error?

    private var isCancelled = false

    private let maxConcurrentUploads = 4
    private var modelContext: ModelContext?

    // TODO: Remove after testing - temporary limit for development
    private let testFileLimit = 500

    // Track deduplication: s3_keys already processed in this session (matches backend catalog.py)
    // After album name correction, multiple local folders may map to the same S3 key
    private var processedS3Keys: Set<String> = []

    // Force re-upload flag (when true, skip existence checks)
    private var forceReupload: Bool = false

    // Services (created per-upload with credentials)
    private var s3Service: S3Service?
    private var metadataService: MetadataService?
    private var conversionService: AudioConversionService?
    private var theAudioDBService: TheAudioDBService?
    private var musicBrainzService: MusicBrainzService?
    private var lastFMService: LastFMService?

    init() {}

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Upload

    /// Upload all music files from a folder to S3.
    /// - Parameters:
    ///   - folderURL: The folder containing audio files
    ///   - credentials: S3 credentials
    ///   - lastFMApiKey: Optional Last.fm API key for metadata fallback
    ///   - forceReupload: When true, re-upload files even if they already exist in S3
    func uploadFolder(_ folderURL: URL, credentials: S3Credentials, lastFMApiKey: String = "", forceReupload: Bool = false) async {
        guard !isUploading else { return }
        guard let modelContext else {
            error = UploadError.notConfigured
            return
        }

        isUploading = true
        isCancelled = false
        error = nil
        progress = UploadProgress()
        processedS3Keys = []  // Clear deduplication set for new upload
        self.forceReupload = forceReupload  // Store for processFile()

        var result = UploadResult()

        // Create services
        let s3 = S3Service(credentials: credentials)
        self.s3Service = s3

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MusicConversions")
        conversionService = AudioConversionService(outputDirectory: tempDir)
        metadataService = MetadataService(musicDirectory: folderURL)
        theAudioDBService = TheAudioDBService(s3Service: s3)
        musicBrainzService = MusicBrainzService()

        if !lastFMApiKey.isEmpty {
            lastFMService = LastFMService(apiKey: lastFMApiKey, s3Service: s3)
        }

        do {
            // Phase 1: Scan for audio files
            progress.currentPhase = .scanning
            var audioFiles = try metadataService!.scanDirectory(folderURL)

            // TODO: Remove after testing - apply temporary file limit
            if audioFiles.count > testFileLimit {
                print("[UploadService] TEST MODE: Limiting to \(testFileLimit) files (found \(audioFiles.count))")
                audioFiles = Array(audioFiles.prefix(testFileLimit))
            }

            progress.totalFiles = audioFiles.count

            if audioFiles.isEmpty {
                progress.currentPhase = .completed
                isUploading = false
                return
            }

            // Phase 2: List existing files in S3
            progress.currentPhase = .fetchingApiData
            let existingKeys = try await s3.listAllFiles()
            await s3.setExistingKeysCache(existingKeys)

            // Phase 3: Process files with concurrency
            progress.currentPhase = .uploading

            await withTaskGroup(of: (URL, Bool, String?).self) { group in
                var activeUploads = 0
                var fileIndex = 0

                while (fileIndex < audioFiles.count || activeUploads > 0) && !isCancelled {
                    // Add new tasks up to limit
                    while activeUploads < maxConcurrentUploads && fileIndex < audioFiles.count && !isCancelled {
                        let fileURL = audioFiles[fileIndex]
                        fileIndex += 1
                        activeUploads += 1

                        group.addTask {
                            await self.processFile(fileURL, folderURL: folderURL, credentials: credentials)
                        }
                    }

                    // Wait for one to complete
                    if activeUploads > 0 {
                        if let (url, success, errorMsg) = await group.next() {
                            activeUploads -= 1
                            progress.completedFiles += 1
                            progress.currentFile = url.lastPathComponent

                            if success {
                                result.uploaded += 1
                            } else if errorMsg == "skipped" {
                                result.skipped += 1
                            } else {
                                result.failed += 1
                                if let errorMsg {
                                    result.errors.append("\(url.lastPathComponent): \(errorMsg)")
                                }
                            }
                        }
                    }
                }
            }

            progress.currentPhase = isCancelled ? .cancelled : .completed
            lastResult = result

            // Cleanup conversion temp files
            await conversionService?.cleanupAll()

        } catch {
            self.error = error
            progress.currentPhase = .failed
        }

        isUploading = false
    }

    // MARK: - Process Single File

    private func processFile(_ fileURL: URL, folderURL: URL, credentials: S3Credentials) async -> (URL, Bool, String?) {
        guard let s3 = s3Service,
              let metadataService,
              let theAudioDBService,
              let modelContext else {
            return (fileURL, false, "Services not configured")
        }

        // Extract metadata
        let metadata = await metadataService.extract(from: fileURL)

        // Get artist and album names
        let artistName = UploadIdentifiers.normalizeArtistName(metadata.albumArtist ?? metadata.artist) ?? "Unknown Artist"
        let albumName = metadata.album ?? "Unknown Album"

        // Fetch corrected album name from TheAudioDB
        let albumInfo = await theAudioDBService.fetchAlbumInfo(artistName, albumName)
        let correctedAlbumName = albumInfo.name ?? albumName

        // Build S3 key
        let safeArtist = UploadIdentifiers.sanitizeS3Key(artistName)
        let safeAlbum = UploadIdentifiers.sanitizeS3Key(correctedAlbumName)
        let safeTitle = UploadIdentifiers.sanitizeS3Key(metadata.title)
        let ext = (metadata.format == "flac" || metadata.format == "wav") ? "m4a" : metadata.format
        let s3Key = "\(safeArtist)/\(safeAlbum)/\(safeTitle).\(ext)"

        // Track deduplication: skip if this s3_key was already processed in this session
        // After album name correction, multiple local folders may map to the same S3 key
        // (e.g., "Album-Deluxe-Version/" and "Album/" both become "Album/")
        if await MainActor.run(body: { processedS3Keys.contains(s3Key) }) {
            print("[UploadService] Skipping duplicate s3_key: \(s3Key)")
            return (fileURL, false, "skipped")
        }
        await MainActor.run { processedS3Keys.insert(s3Key) }

        // Check if already uploaded to S3 (skip unless forceReupload is true)
        if !forceReupload {
            do {
                if try await s3.fileExists(s3Key) {
                    return (fileURL, false, "skipped")
                }
            } catch {
                return (fileURL, false, "Check failed: \(error.localizedDescription)")
            }
        }

        // Convert if needed (FLAC, WAV to M4A)
        var uploadURL = fileURL
        var needsCleanup = false

        if metadata.format == "flac" || metadata.format == "wav" {
            do {
                // Try AVFoundation first, fall back to ffmpeg
                if let converted = try? await conversionService?.convertToM4A(fileURL: fileURL) {
                    uploadURL = converted
                    needsCleanup = true
                } else if let converted = try? await conversionService?.convertWithFFmpeg(fileURL: fileURL) {
                    uploadURL = converted
                    needsCleanup = true
                } else {
                    // If conversion fails, skip the file
                    return (fileURL, false, "Conversion failed")
                }
            }
        }

        // Upload file
        let url: String
        do {
            let contentType = AudioContentType.forExtension(ext)
            let data = try Data(contentsOf: uploadURL)
            url = try await s3.uploadData(data, s3Key: s3Key, contentType: contentType)

            // Cleanup converted file
            if needsCleanup {
                await conversionService?.cleanup(uploadURL)
            }
        } catch {
            if needsCleanup {
                await conversionService?.cleanup(uploadURL)
            }
            return (fileURL, false, "Upload failed: \(error.localizedDescription)")
        }

        // Upload embedded artwork (with validation - matches backend)
        var embeddedArtworkUrl: String?
        if let artworkData = metadata.artworkData,
           let mimeType = metadata.artworkMimeType {
            let artworkExt = mimeType.contains("png") ? "png" : "jpg"
            let artworkKey = "\(safeArtist)/\(safeAlbum)/embedded.\(artworkExt)"
            // Use validated upload method - skips oversized or invalid images
            if let artworkUrl = try? await s3.uploadArtworkData(artworkData, s3Key: artworkKey, contentType: mimeType) {
                embeddedArtworkUrl = artworkUrl
            }
        }

        // Fetch additional metadata
        var artistInfo = ArtistInfo.empty
        var mbArtistDetails = ArtistInfo.empty
        var mbReleaseDetails = AlbumInfo.empty

        // Fetch artist info (for first track of each artist)
        artistInfo = await theAudioDBService.fetchArtistInfo(artistName)

        if let mb = musicBrainzService {
            mbArtistDetails = await mb.getArtistDetails(artistName)
            mbReleaseDetails = await mb.getReleaseDetails(artistName, albumName)
        }

        // Last.fm fallback for album info
        if albumInfo.imageUrl == nil && albumInfo.wiki == nil,
           let lastfm = lastFMService {
            let lastfmInfo = await lastfm.fetchAlbumInfo(artistName, albumName)
            // Merge (prefer TheAudioDB)
            let mergedAlbumInfo = AlbumInfo(
                name: albumInfo.name ?? lastfmInfo.name,
                imageUrl: albumInfo.imageUrl ?? lastfmInfo.imageUrl,
                wiki: albumInfo.wiki ?? lastfmInfo.wiki,
                releaseDate: albumInfo.releaseDate ?? lastfmInfo.releaseDate,
                genre: albumInfo.genre ?? lastfmInfo.genre,
                style: albumInfo.style ?? lastfmInfo.style,
                mood: albumInfo.mood ?? lastfmInfo.mood,
                theme: albumInfo.theme ?? lastfmInfo.theme,
                releaseType: albumInfo.releaseType ?? lastfmInfo.releaseType,
                country: albumInfo.country ?? lastfmInfo.country,
                label: albumInfo.label ?? lastfmInfo.label
            )
            _ = mergedAlbumInfo  // Use merged info below
        }

        // Save to SwiftData
        await MainActor.run {
            let artistId = UploadIdentifiers.artistId(artistName)
            let albumId = UploadIdentifiers.albumId(artist: artistName, album: correctedAlbumName)

            // Create or update artist
            let artistDescriptor = FetchDescriptor<UploadedArtist>(
                predicate: #Predicate { $0.id == artistId }
            )
            if (try? modelContext.fetch(artistDescriptor))?.first == nil {
                let uploadedArtist = UploadedArtist(
                    id: artistId,
                    name: artistName,
                    bio: artistInfo.bio,
                    imageUrl: artistInfo.imageUrl,
                    genre: artistInfo.genre,
                    style: artistInfo.style,
                    mood: artistInfo.mood,
                    artistType: mbArtistDetails.artistType,
                    area: mbArtistDetails.area,
                    beginDate: mbArtistDetails.beginDate,
                    endDate: mbArtistDetails.endDate,
                    disambiguation: mbArtistDetails.disambiguation
                )
                modelContext.insert(uploadedArtist)
            }

            // Create or update album
            let albumDescriptor = FetchDescriptor<UploadedAlbum>(
                predicate: #Predicate { $0.id == albumId }
            )
            if (try? modelContext.fetch(albumDescriptor))?.first == nil {
                let uploadedAlbum = UploadedAlbum(
                    id: albumId,
                    name: correctedAlbumName,
                    localName: albumName,
                    artistId: artistId,
                    imageUrl: albumInfo.imageUrl,
                    wiki: albumInfo.wiki,
                    releaseDate: albumInfo.releaseDate ?? mbReleaseDetails.releaseDate,
                    genre: albumInfo.genre,
                    style: albumInfo.style,
                    mood: albumInfo.mood,
                    theme: albumInfo.theme,
                    releaseType: mbReleaseDetails.releaseType,
                    country: mbReleaseDetails.country,
                    label: mbReleaseDetails.label
                )
                modelContext.insert(uploadedAlbum)
            }

            // Create track
            let uploadedTrack = UploadedTrack(
                s3Key: s3Key,
                url: url,
                title: metadata.title,
                format: ext,
                artist: artistName,
                album: correctedAlbumName,
                albumArtist: metadata.albumArtist,
                trackNumber: metadata.trackNumber,
                trackTotal: metadata.trackTotal,
                discNumber: metadata.discNumber,
                discTotal: metadata.discTotal,
                duration: metadata.duration,
                year: metadata.year ?? albumInfo.releaseDate ?? mbReleaseDetails.releaseDate,
                genre: metadata.genre ?? albumInfo.genre,
                style: albumInfo.style,
                mood: albumInfo.mood,
                theme: albumInfo.theme,
                composer: metadata.composer,
                comment: metadata.comment,
                originalFormat: metadata.format != ext ? metadata.format : nil,
                bitrate: metadata.bitrate,
                samplerate: metadata.samplerate,
                channels: metadata.channels,
                filesize: metadata.filesize,
                embeddedArtworkUrl: embeddedArtworkUrl ?? albumInfo.imageUrl,
                uploadedAlbumId: albumId,
                uploadedArtistId: artistId
            )
            modelContext.insert(uploadedTrack)
            try? modelContext.save()
        }

        return (fileURL, true, nil)
    }

    // MARK: - Prepare Upload

    /// Compare local folder to remote S3 and return what will be uploaded vs skipped.
    /// - Parameters:
    ///   - folderURL: The folder containing audio files
    ///   - credentials: S3 credentials
    ///   - useAPILookups: If true, uses TheAudioDB to get corrected album names (accurate but slower).
    ///                    If false, uses path-based estimation (fast but may miss corrected names).
    ///   - forceReupload: When true, all files are marked for upload (ignores existing S3 files).
    func prepareUpload(_ folderURL: URL, credentials: S3Credentials, useAPILookups: Bool = true, forceReupload: Bool = false) async {
        guard !isPreparing && !isUploading else { return }

        isPreparing = true
        preparationProgress = 0
        preparationResult = nil
        error = nil

        print("[UploadService] prepareUpload() called for \(folderURL.path) (useAPILookups: \(useAPILookups))")

        let s3 = S3Service(credentials: credentials)
        let metadataService = MetadataService(musicDirectory: folderURL)
        let theAudioDBService = TheAudioDBService(s3Service: s3)

        do {
            // Phase 1: Scan local folder (0-10%)
            preparationStatus = "Scanning local folder..."
            print("[UploadService] Scanning local folder...")

            let audioFiles: [URL] = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        var lastStatusUpdate = 0
                        let files = try metadataService.scanDirectory(folderURL) { itemsChecked, audioFound in
                            // Dispatch UI updates to main thread
                            if itemsChecked - lastStatusUpdate >= 100 {
                                DispatchQueue.main.async {
                                    self.preparationStatus = "Scanning... \(itemsChecked.formatted()) items, \(audioFound.formatted()) audio files"
                                    self.preparationProgress = min(0.10, Double(itemsChecked) / 10000.0 * 0.10)
                                }
                                lastStatusUpdate = itemsChecked
                            }
                        }
                        continuation.resume(returning: files)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            print("[UploadService] Found \(audioFiles.count) local audio files")

            // TODO: Remove after testing - apply temporary file limit
            var limitedAudioFiles = audioFiles
            if audioFiles.count > testFileLimit {
                print("[UploadService] TEST MODE: Limiting to \(testFileLimit) files (found \(audioFiles.count))")
                limitedAudioFiles = Array(audioFiles.prefix(testFileLimit))
            }

            preparationProgress = 0.10

            if limitedAudioFiles.isEmpty {
                preparationStatus = "No audio files found"
                preparationResult = UploadPreparation(
                    filesToUpload: [],
                    filesToSkip: [],
                    totalLocalFiles: 0,
                    folderURL: folderURL,
                    cachedS3Keys: []
                )
                isPreparing = false
                return
            }

            // Phase 2: List existing S3 keys (10-20%)
            preparationStatus = "Listing remote files... (this may take a moment)"
            preparationProgress = 0.10
            print("[UploadService] Listing existing S3 files...")
            let existingKeys = try await s3.listAllFiles()
            print("[UploadService] Found \(existingKeys.count) existing S3 keys")
            preparationProgress = 0.20
            preparationStatus = "Found \(existingKeys.count.formatted()) remote files"

            // Phase 3: Process files - extract metadata and compare (20-95%)
            if useAPILookups {
                // Accurate mode: extract metadata + API lookups for corrected album names
                preparationStatus = "Processing \(limitedAudioFiles.count.formatted()) files with metadata..."
                print("[UploadService] Processing files with metadata extraction and API lookups...")

                var filesToUpload: [URL] = []
                var filesToSkip: [URL] = []
                let total = limitedAudioFiles.count

                for (index, fileURL) in limitedAudioFiles.enumerated() {
                    // Extract metadata
                    let metadata = await metadataService.extract(from: fileURL)

                    let artistName = UploadIdentifiers.normalizeArtistName(
                        metadata.albumArtist ?? metadata.artist
                    ) ?? "Unknown Artist"
                    let albumName = metadata.album ?? "Unknown Album"

                    // Lookup corrected album name from TheAudioDB (cached per artist+album)
                    let albumInfo = await theAudioDBService.fetchAlbumInfo(artistName, albumName)
                    let correctedAlbum = albumInfo.name ?? albumName

                    // Build accurate S3 key using corrected album name
                    let safeArtist = UploadIdentifiers.sanitizeS3Key(artistName)
                    let safeAlbum = UploadIdentifiers.sanitizeS3Key(correctedAlbum)
                    let safeTitle = UploadIdentifiers.sanitizeS3Key(metadata.title)
                    let ext = (metadata.format == "flac" || metadata.format == "wav") ? "m4a" : metadata.format
                    let s3Key = "\(safeArtist)/\(safeAlbum)/\(safeTitle).\(ext)"

                    // Debug logging for S3 key matching
                    let exists = existingKeys.contains(s3Key)
                    if !exists && (index < 10 || index % 100 == 0) {
                        print("[Debug] Local: \(fileURL.lastPathComponent)")
                        print("[Debug] Artist: '\(artistName)' -> '\(safeArtist)'")
                        print("[Debug] Album: '\(albumName)' -> corrected: '\(correctedAlbum)' -> '\(safeAlbum)'")
                        print("[Debug] Title: '\(metadata.title)' -> '\(safeTitle)'")
                        print("[Debug] S3 Key: \(s3Key)")
                        print("[Debug] Exists in S3: \(exists)")
                        // Show similar keys that DO exist
                        let prefix = "\(safeArtist)/\(safeAlbum)/"
                        let similarKeys = existingKeys.filter { $0.hasPrefix(prefix) }.prefix(5)
                        if !similarKeys.isEmpty {
                            print("[Debug] Similar keys in S3: \(Array(similarKeys))")
                        }
                        print("---")
                    }

                    // When forceReupload is true, mark all files for upload
                    if forceReupload || !exists {
                        filesToUpload.append(fileURL)
                    } else {
                        filesToSkip.append(fileURL)
                    }

                    // Update UI every 50 files or at completion
                    if (index + 1) % 50 == 0 || (index + 1) == total {
                        let progress = 0.20 + (Double(index + 1) / Double(total) * 0.75)
                        preparationProgress = progress
                        preparationStatus = "Processing... \(index + 1)/\(total) files"
                    }
                }

                preparationProgress = 0.95
                preparationStatus = "Finalizing..."

                preparationProgress = 1.0
                preparationStatus = "Complete: \(filesToUpload.count) to upload, \(filesToSkip.count) to skip"
                print("[UploadService] Preparation complete: \(filesToUpload.count) to upload, \(filesToSkip.count) to skip")

                preparationResult = UploadPreparation(
                    filesToUpload: filesToUpload,
                    filesToSkip: filesToSkip,
                    totalLocalFiles: limitedAudioFiles.count,
                    folderURL: folderURL,
                    cachedS3Keys: existingKeys
                )
            } else {
                // Fast mode: path-based estimation (no API calls)
                preparationStatus = "Comparing \(limitedAudioFiles.count.formatted()) local files..."
                print("[UploadService] Using fast path-based comparison...")

                let (filesToUpload, filesToSkip): ([URL], [URL]) = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async { [limitedAudioFiles, forceReupload] in
                        var toUpload: [URL] = []
                        var toSkip: [URL] = []
                        let total = limitedAudioFiles.count
                        var lastUpdate = 0

                        for (index, fileURL) in limitedAudioFiles.enumerated() {
                            // Build estimated S3 key from folder structure
                            let s3Key = self.buildEstimatedS3Key(for: fileURL, relativeTo: folderURL)

                            // When forceReupload is true, mark all files for upload
                            if forceReupload || !existingKeys.contains(s3Key) {
                                toUpload.append(fileURL)
                            } else {
                                toSkip.append(fileURL)
                            }

                            // Update UI every 200 files or 5% progress
                            if index - lastUpdate >= 200 || (index + 1) == total {
                                let progress = 0.20 + (Double(index + 1) / Double(total) * 0.75)
                                DispatchQueue.main.async {
                                    self.preparationProgress = progress
                                    self.preparationStatus = "Comparing... \(index + 1)/\(total) files"
                                }
                                lastUpdate = index
                            }
                        }

                        continuation.resume(returning: (toUpload, toSkip))
                    }
                }

                preparationProgress = 1.0
                preparationStatus = "Complete: \(filesToUpload.count) to upload, \(filesToSkip.count) to skip"
                print("[UploadService] Preparation complete: \(filesToUpload.count) to upload, \(filesToSkip.count) to skip")

                preparationResult = UploadPreparation(
                    filesToUpload: filesToUpload,
                    filesToSkip: filesToSkip,
                    totalLocalFiles: limitedAudioFiles.count,
                    folderURL: folderURL,
                    cachedS3Keys: existingKeys
                )
            }

        } catch {
            print("[UploadService] Preparation error: \(error.localizedDescription)")
            self.error = error
        }

        isPreparing = false
    }

    /// Build an estimated S3 key from local file path.
    /// Uses folder structure: music/Artist/Album/Track.ext
    private func buildEstimatedS3Key(for fileURL: URL, relativeTo folderURL: URL) -> String {
        let relativePath = fileURL.path.replacingOccurrences(of: folderURL.path + "/", with: "")
        let components = relativePath.components(separatedBy: "/")

        // Expect: Artist/Album/Track.ext
        guard components.count >= 3 else {
            // Fallback: just use sanitized filename
            let filename = fileURL.deletingPathExtension().lastPathComponent
            let ext = fileURL.pathExtension.lowercased()
            let finalExt = (ext == "flac" || ext == "wav") ? "m4a" : ext
            return "\(UploadIdentifiers.sanitizeS3Key(filename)).\(finalExt)"
        }

        let artist = UploadIdentifiers.sanitizeS3Key(components[0])
        let album = UploadIdentifiers.sanitizeS3Key(components[1])
        let filename = (components[2] as NSString).deletingPathExtension
        let title = UploadIdentifiers.sanitizeS3Key(filename)
        let ext = fileURL.pathExtension.lowercased()
        let finalExt = (ext == "flac" || ext == "wav") ? "m4a" : ext

        return "\(artist)/\(album)/\(title).\(finalExt)"
    }

    /// Clear the preparation result.
    func clearPreparation() {
        preparationResult = nil
    }

    // MARK: - Cancel

    func cancel() {
        isCancelled = true
    }
}

// MARK: - Errors

enum UploadError: LocalizedError {
    case notConfigured
    case noFilesFound
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Upload service not configured with model context"
        case .noFilesFound:
            return "No audio files found in the selected folder"
        case .cancelled:
            return "Upload cancelled"
        }
    }
}

#else

// iOS stub
@MainActor
@Observable
class UploadService {
    private(set) var progress = UploadProgress()
    private(set) var isUploading = false
    private(set) var isPreparing = false
    private(set) var preparationResult: UploadPreparation?
    private(set) var preparationProgress: Double = 0
    private(set) var preparationStatus: String = ""
    private(set) var lastResult: UploadResult?
    var error: Error?

    func configure(modelContext: ModelContext) {}
    func uploadFolder(_ folderURL: URL, credentials: S3Credentials, lastFMApiKey: String = "", forceReupload: Bool = false) async {}
    func prepareUpload(_ folderURL: URL, credentials: S3Credentials, useAPILookups: Bool = true, forceReupload: Bool = false) async {}
    func clearPreparation() {}
    func cancel() {}
}

struct UploadProgress {
    var totalFiles: Int = 0
    var completedFiles: Int = 0
    var currentFile: String = ""
    var currentPhase: UploadPhase = .idle

    var progress: Double { 0 }
}

enum UploadPhase: String {
    case idle, scanning, extractingMetadata, fetchingApiData, converting, uploading, savingDatabase, completed, cancelled, failed
}

struct UploadResult {
    var uploaded: Int = 0
    var skipped: Int = 0
    var failed: Int = 0
    var errors: [String] = []
}

struct UploadPreparation {
    var filesToUpload: [URL]
    var filesToSkip: [URL]
    var totalLocalFiles: Int
    var folderURL: URL
    var cachedS3Keys: Set<String>
}

#endif
