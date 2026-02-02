//
//  MusicUploader.swift
//  Music
//
//  Main orchestrator for uploading music to DigitalOcean Spaces.
//  Scans folders, extracts metadata, converts if needed, uploads, and builds catalog.
//

import Foundation
import SwiftData

#if os(macOS)

// MARK: - Preview Data Structures

/// A single item in the upload preview showing what will be uploaded
struct UploadPreviewItem: Identifiable {
    let id = UUID()
    let localPath: String           // Full local file path
    let artist: String              // Corrected from TheAudioDB
    let album: String               // Corrected from TheAudioDB
    let title: String
    let s3Key: String               // Final path: Artist/Album/Title.ext
    let format: String
    let needsConversion: Bool
    let fileURL: URL                // Original file URL for upload
}

/// Preview of what will be uploaded, split into new and existing files
struct UploadPreview {
    let newFiles: [UploadPreviewItem]           // Files to upload
    let skippedFiles: [UploadPreviewItem]       // Already exist on remote

    var totalNewFiles: Int { newFiles.count }
    var totalSkippedFiles: Int { skippedFiles.count }
}

/// Upload progress state
struct UploadProgress {
    var phase: UploadPhase
    var totalFiles: Int
    var processedFiles: Int
    var skippedFiles: Int
    var convertedFiles: Int
    var failedFiles: Int
    var currentFile: String?

    var progress: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(processedFiles + skippedFiles + failedFiles) / Double(totalFiles)
    }

    enum UploadPhase: String {
        case idle = "Ready"
        case scanning = "Scanning files..."
        case fetchingExisting = "Checking existing files..."
        case processing = "Processing..."
        case fetchingMetadata = "Fetching metadata..."
        case buildingCatalog = "Building catalog..."
        case savingCatalog = "Saving catalog..."
        case complete = "Complete"
        case cancelled = "Cancelled"
        case failed = "Failed"
    }
}

@MainActor
@Observable
class MusicUploader {
    private(set) var progress = UploadProgress(
        phase: .idle,
        totalFiles: 0,
        processedFiles: 0,
        skippedFiles: 0,
        convertedFiles: 0,
        failedFiles: 0,
        currentFile: nil
    )

    private(set) var isRunning = false
    private(set) var error: Error?

    private var uploadTask: Task<Void, Never>?
    private var config: UploadConfiguration?
    private var modelContext: ModelContext?

    private static let supportedExtensions = Set(["mp3", "m4a", "flac", "wav", "aac", "aiff"])
    private static let maxConcurrentWorkers = 8
    private static let maxConcurrentMetadataExtractors = 16  // Higher for local I/O

    func configure(config: UploadConfiguration, modelContext: ModelContext) {
        self.config = config
        self.modelContext = modelContext
    }

    // MARK: - Start Upload

    func start(from folderURL: URL) {
        guard !isRunning else { return }
        guard let config = config, config.isValid else {
            error = UploaderError.invalidConfiguration
            return
        }

        isRunning = true
        error = nil
        progress = UploadProgress(
            phase: .scanning,
            totalFiles: 0,
            processedFiles: 0,
            skippedFiles: 0,
            convertedFiles: 0,
            failedFiles: 0,
            currentFile: nil
        )

        uploadTask = Task {
            do {
                try await performUpload(from: folderURL, config: config)
                progress.phase = .complete
            } catch is CancellationError {
                progress.phase = .cancelled
            } catch {
                self.error = error
                progress.phase = .failed
            }
            isRunning = false
        }
    }

    // MARK: - Cancel

    func cancel() {
        uploadTask?.cancel()
    }

    // MARK: - Scan for Preview

    /// Scan folder and generate preview of what will be uploaded.
    /// Fetches TheAudioDB corrections for artist/album names before upload.
    /// Optimized for large libraries (12k+ files):
    /// - Parallel metadata extraction
    /// - Batched unique artist/album API lookups
    func scanForPreview(from folderURL: URL) async throws -> UploadPreview {
        guard let config = config, config.isValid else {
            throw UploaderError.invalidConfiguration
        }

        // Initialize services
        let storageService = StorageService(config: config)
        let theAudioDB = TheAudioDBService(storageService: nil)  // No storage for preview
        let metadataExtractor = MetadataExtractor(musicDirectory: folderURL)

        // Phase 1: Scan for audio files
        progress.phase = .scanning
        let audioFiles = try scanForAudioFiles(in: folderURL)

        if audioFiles.isEmpty {
            throw UploaderError.noAudioFilesFound
        }

        // Phase 2: Fetch existing files from storage (parallel with phase 3)
        progress.phase = .fetchingExisting
        async let existingKeysTask = storageService.listAllFiles()

        // Phase 3: Extract metadata in parallel (much faster for 12k+ files)
        progress.phase = .fetchingMetadata
        progress.totalFiles = audioFiles.count
        progress.processedFiles = 0
        progress.currentFile = "Extracting metadata..."

        // Parallel metadata extraction with limited concurrency
        let extractedMetadata: [(URL, TrackMetadata)] = await withTaskGroup(of: (URL, TrackMetadata)?.self) { group in
            var results: [(URL, TrackMetadata)] = []
            results.reserveCapacity(audioFiles.count)
            var submitted = 0

            for fileURL in audioFiles {
                if submitted >= Self.maxConcurrentMetadataExtractors {
                    if let result = await group.next(), let r = result {
                        results.append(r)
                        await MainActor.run { progress.processedFiles += 1 }
                    }
                }

                group.addTask {
                    let metadata = await metadataExtractor.extract(from: fileURL)
                    return (fileURL, metadata)
                }
                submitted += 1
            }

            // Collect remaining
            for await result in group {
                if let r = result {
                    results.append(r)
                    await MainActor.run { progress.processedFiles += 1 }
                }
            }

            return results
        }

        try Task.checkCancellation()

        // Wait for existing keys
        let existingKeys = try await existingKeysTask

        // Phase 4: Collect unique artists and albums for batch API lookup
        progress.currentFile = "Looking up artist/album corrections..."
        var uniqueArtists: Set<String> = []
        var uniqueAlbums: Set<String> = []  // "artist|album" format

        for (_, metadata) in extractedMetadata {
            let rawArtist = metadata.albumArtist ?? metadata.artist ?? "Unknown Artist"
            let rawAlbum = metadata.album ?? "Unknown Album"
            uniqueArtists.insert(rawArtist)
            uniqueAlbums.insert("\(rawArtist)|\(rawAlbum)")
        }

        // Phase 5: Fetch corrections for unique artists (sequential due to rate limits)
        var artistCorrections: [String: String] = [:]
        progress.totalFiles = uniqueArtists.count
        progress.processedFiles = 0

        for rawArtist in uniqueArtists {
            try Task.checkCancellation()
            progress.currentFile = rawArtist
            let artistInfo = await theAudioDB.fetchArtistInfo(rawArtist)
            let corrected = artistInfo.name ?? Identifiers.normalizeArtistName(rawArtist) ?? rawArtist
            artistCorrections[rawArtist] = corrected
            progress.processedFiles += 1
        }

        // Phase 6: Fetch corrections for unique albums
        var albumCorrections: [String: String] = [:]
        progress.totalFiles = uniqueAlbums.count
        progress.processedFiles = 0

        for albumKey in uniqueAlbums {
            try Task.checkCancellation()
            let parts = albumKey.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let firstPart = parts.first else { continue }
            let rawArtist = String(firstPart)
            let rawAlbum = String(parts[1])

            let correctedArtist = artistCorrections[rawArtist] ?? rawArtist
            progress.currentFile = "\(correctedArtist) - \(rawAlbum)"

            let albumInfo = await theAudioDB.fetchAlbumInfo(artist: correctedArtist, album: rawAlbum)
            albumCorrections[albumKey] = albumInfo.name ?? rawAlbum
            progress.processedFiles += 1
        }

        // Phase 7: Build preview items (fast, in-memory)
        progress.currentFile = "Building preview..."
        var newFiles: [UploadPreviewItem] = []
        var skippedFiles: [UploadPreviewItem] = []
        newFiles.reserveCapacity(extractedMetadata.count)

        for (fileURL, metadata) in extractedMetadata {
            let rawArtist = metadata.albumArtist ?? metadata.artist ?? "Unknown Artist"
            let rawAlbum = metadata.album ?? "Unknown Album"

            let correctedArtist = artistCorrections[rawArtist] ?? rawArtist
            let albumKey = "\(rawArtist)|\(rawAlbum)"
            let correctedAlbum = albumCorrections[albumKey] ?? rawAlbum

            let needsConversion = AudioConverter.needsConversion(fileURL)
            let format = needsConversion ? "m4a" : fileURL.pathExtension.lowercased()

            let s3Key = Identifiers.generateS3Key(
                artist: correctedArtist,
                album: correctedAlbum,
                title: metadata.title,
                format: format
            )

            let previewItem = UploadPreviewItem(
                localPath: fileURL.path,
                artist: correctedArtist,
                album: correctedAlbum,
                title: metadata.title,
                s3Key: s3Key,
                format: format,
                needsConversion: needsConversion,
                fileURL: fileURL
            )

            if existingKeys.contains(s3Key) {
                skippedFiles.append(previewItem)
            } else {
                newFiles.append(previewItem)
            }
        }

        // Save metadata cache for future scans
        await metadataExtractor.saveCache()

        progress.phase = .idle
        return UploadPreview(newFiles: newFiles, skippedFiles: skippedFiles)
    }

    // MARK: - Upload from Preview

    /// Start upload using pre-computed preview data.
    /// Uses the corrected S3 keys from the preview.
    func startFromPreview(_ preview: UploadPreview, folderURL: URL) {
        guard !isRunning else { return }
        guard let config = config, config.isValid else {
            error = UploaderError.invalidConfiguration
            return
        }

        isRunning = true
        error = nil
        progress = UploadProgress(
            phase: .processing,
            totalFiles: preview.newFiles.count,
            processedFiles: 0,
            skippedFiles: preview.skippedFiles.count,
            convertedFiles: 0,
            failedFiles: 0,
            currentFile: nil
        )

        uploadTask = Task {
            do {
                try await performUploadFromPreview(preview: preview, folderURL: folderURL, config: config)
                progress.phase = .complete
            } catch is CancellationError {
                progress.phase = .cancelled
            } catch {
                self.error = error
                progress.phase = .failed
            }
            isRunning = false
        }
    }

    private func performUploadFromPreview(preview: UploadPreview, folderURL: URL, config: UploadConfiguration) async throws {
        // Initialize services
        let storageService = StorageService(config: config)
        let theAudioDB = TheAudioDBService(storageService: storageService)
        let musicBrainz = config.musicBrainzContact.isEmpty ? nil : MusicBrainzService(contact: config.musicBrainzContact)
        let lastFM = config.lastFMApiKey.isEmpty ? nil : LastFMService(apiKey: config.lastFMApiKey, storageService: storageService)

        let metadataExtractor = MetadataExtractor(musicDirectory: folderURL)
        let artworkExtractor = ArtworkExtractor()
        let audioConverter = AudioConverter()
        let catalogBuilder = CatalogBuilder(
            theAudioDB: theAudioDB,
            musicBrainz: musicBrainz,
            lastFM: lastFM,
            storageService: storageService
        )

        // Build a lookup map from file path to preview item for quick access
        var previewItemMap: [String: UploadPreviewItem] = [:]
        for item in preview.newFiles {
            previewItemMap[item.localPath] = item
        }
        for item in preview.skippedFiles {
            previewItemMap[item.localPath] = item
        }

        // Set existing keys cache (skipped files are already on remote)
        let existingKeys = Set(preview.skippedFiles.map { $0.s3Key })
        await storageService.setExistingKeysCache(existingKeys)

        // Fetch existing catalog to preserve addedAt dates for existing tracks
        let existingAddedAtMap = await fetchExistingAddedAtMap(config: config)

        try Task.checkCancellation()

        // Phase: Process files
        progress.phase = .processing
        var processedTracks: [ProcessedTrack] = []

        // Process new files (upload)
        let results = try await withThrowingTaskGroup(of: ProcessedTrack?.self) { group in
            var submitted = 0
            var resultsArray: [ProcessedTrack] = []

            for item in preview.newFiles {
                // Limit concurrent workers
                if submitted >= Self.maxConcurrentWorkers {
                    if let result = try await group.next() {
                        if let track = result {
                            resultsArray.append(track)
                        }
                    }
                }

                try Task.checkCancellation()

                group.addTask {
                    return await self.processFileWithPreview(
                        previewItem: item,
                        config: config,
                        storageService: storageService,
                        metadataExtractor: metadataExtractor,
                        artworkExtractor: artworkExtractor,
                        audioConverter: audioConverter,
                        existingAddedAtMap: existingAddedAtMap
                    )
                }
                submitted += 1
            }

            // Collect remaining results
            for try await result in group {
                if let track = result {
                    resultsArray.append(track)
                }
            }

            return resultsArray
        }

        processedTracks = results

        // Also add skipped files to the catalog (they're still part of the collection)
        // Verify each skipped file still exists on remote before adding to catalog
        for item in preview.skippedFiles {
            // Verify file still exists on remote (may have been deleted between scan and upload)
            let exists = await storageService.fileExists(item.s3Key)
            if !exists {
                print("⚠️ Skipped file no longer exists on remote: \(item.s3Key)")
                continue
            }

            let metadata = await metadataExtractor.extract(from: item.fileURL)
            let url = await storageService.getPublicURL(for: item.s3Key)

            // Preserve existing addedAt or use current date as fallback
            let addedAt = existingAddedAtMap[item.s3Key] ?? Date()

            let track = ProcessedTrack(
                title: item.title,
                artist: metadata.artist ?? item.artist,
                album: item.album,
                albumArtist: metadata.albumArtist,
                trackNumber: metadata.trackNumber,
                trackTotal: metadata.trackTotal,
                discNumber: metadata.discNumber,
                discTotal: metadata.discTotal,
                duration: metadata.duration,
                year: metadata.year,
                genre: metadata.genre,
                format: item.format,
                s3Key: item.s3Key,
                url: url,
                originalFormat: item.needsConversion ? item.fileURL.pathExtension.lowercased() : nil,
                addedAt: addedAt
            )
            processedTracks.append(track)
        }

        try Task.checkCancellation()

        // Phase: Build catalog
        progress.phase = .buildingCatalog
        let (catalogArtists, totalTracks) = await catalogBuilder.build(from: processedTracks)

        try Task.checkCancellation()

        // Phase: Save to SwiftData and upload catalog.json to CDN
        progress.phase = .savingCatalog
        try await saveCatalog(artists: catalogArtists, totalTracks: totalTracks, storageService: storageService, config: config)
    }

    /// Process a single file using pre-computed preview data
    private func processFileWithPreview(
        previewItem: UploadPreviewItem,
        config: UploadConfiguration,
        storageService: StorageService,
        metadataExtractor: MetadataExtractor,
        artworkExtractor: ArtworkExtractor,
        audioConverter: AudioConverter,
        existingAddedAtMap: [String: Date]
    ) async -> ProcessedTrack? {
        let fileURL = previewItem.fileURL
        let s3Key = previewItem.s3Key

        // Update progress on main thread
        await MainActor.run {
            progress.currentFile = fileURL.lastPathComponent
        }

        // Extract full metadata for catalog
        let metadata = await metadataExtractor.extract(from: fileURL)

        // Convert if needed
        var uploadURL = fileURL
        var wasConverted = false
        if previewItem.needsConversion {
            do {
                uploadURL = try await audioConverter.convert(fileURL)
                wasConverted = true
                await MainActor.run {
                    progress.convertedFiles += 1
                }
            } catch {
                await MainActor.run {
                    progress.failedFiles += 1
                }
                return nil
            }
        }

        // Extract embedded artwork
        var embeddedArtworkUrl: String?
        if let artwork = await artworkExtractor.extract(from: fileURL) {
            do {
                embeddedArtworkUrl = try await storageService.uploadArtworkBytes(
                    artwork.data,
                    mimeType: artwork.mimeType,
                    artist: previewItem.artist,
                    album: previewItem.album
                )
            } catch {
                // Artwork upload failed, continue without it
            }
        }

        // Upload file with corrected S3 key
        do {
            let url = try await storageService.uploadFile(at: uploadURL, s3Key: s3Key)

            // Clean up converted file
            if wasConverted && uploadURL != fileURL {
                try? FileManager.default.removeItem(at: uploadURL)
            }

            await MainActor.run {
                progress.processedFiles += 1
            }

            // New uploads get current date, existing tracks preserve their addedAt
            let addedAt = existingAddedAtMap[s3Key] ?? Date()

            return ProcessedTrack(
                title: previewItem.title,
                artist: metadata.artist ?? previewItem.artist,
                album: previewItem.album,  // Use corrected album name
                albumArtist: metadata.albumArtist,
                trackNumber: metadata.trackNumber,
                trackTotal: metadata.trackTotal,
                discNumber: metadata.discNumber,
                discTotal: metadata.discTotal,
                duration: metadata.duration,
                year: metadata.year,
                genre: metadata.genre,
                format: previewItem.format,
                s3Key: s3Key,
                url: url,
                embeddedArtworkUrl: embeddedArtworkUrl,
                originalFormat: wasConverted ? fileURL.pathExtension.lowercased() : nil,
                addedAt: addedAt
            )
        } catch {
            // Clean up converted file on failure
            if wasConverted && uploadURL != fileURL {
                try? FileManager.default.removeItem(at: uploadURL)
            }

            await MainActor.run {
                progress.failedFiles += 1
            }
            return nil
        }
    }

    // MARK: - Upload Workflow

    private func performUpload(from folderURL: URL, config: UploadConfiguration) async throws {
        // Initialize services
        let storageService = StorageService(config: config)
        let theAudioDB = TheAudioDBService(storageService: storageService)
        let musicBrainz = config.musicBrainzContact.isEmpty ? nil : MusicBrainzService(contact: config.musicBrainzContact)
        let lastFM = config.lastFMApiKey.isEmpty ? nil : LastFMService(apiKey: config.lastFMApiKey, storageService: storageService)

        let metadataExtractor = MetadataExtractor(musicDirectory: folderURL)
        let artworkExtractor = ArtworkExtractor()
        let audioConverter = AudioConverter()
        let catalogBuilder = CatalogBuilder(
            theAudioDB: theAudioDB,
            musicBrainz: musicBrainz,
            lastFM: lastFM,
            storageService: storageService
        )

        // Phase 1: Scan for audio files
        progress.phase = .scanning
        let audioFiles = try scanForAudioFiles(in: folderURL)
        progress.totalFiles = audioFiles.count

        if audioFiles.isEmpty {
            throw UploaderError.noAudioFilesFound
        }

        try Task.checkCancellation()

        // Phase 2: Fetch existing files from storage
        progress.phase = .fetchingExisting
        let existingKeys = try await storageService.listAllFiles()
        await storageService.setExistingKeysCache(existingKeys)

        try Task.checkCancellation()

        // Phase 3: Process files in parallel
        progress.phase = .processing
        var processedTracks: [ProcessedTrack] = []

        // Use TaskGroup with limited concurrency
        let results = try await withThrowingTaskGroup(of: ProcessedTrack?.self) { group in
            var submitted = 0
            var resultsArray: [ProcessedTrack] = []

            for fileURL in audioFiles {
                // Limit concurrent workers
                if submitted >= Self.maxConcurrentWorkers {
                    if let result = try await group.next() {
                        if let track = result {
                            resultsArray.append(track)
                        }
                    }
                }

                try Task.checkCancellation()

                group.addTask {
                    return await self.processFile(
                        fileURL: fileURL,
                        musicDirectory: folderURL,
                        existingKeys: existingKeys,
                        config: config,
                        storageService: storageService,
                        metadataExtractor: metadataExtractor,
                        artworkExtractor: artworkExtractor,
                        audioConverter: audioConverter
                    )
                }
                submitted += 1
            }

            // Collect remaining results
            for try await result in group {
                if let track = result {
                    resultsArray.append(track)
                }
            }

            return resultsArray
        }

        processedTracks = results

        try Task.checkCancellation()

        // Phase 4: Build catalog
        progress.phase = .buildingCatalog
        let (catalogArtists, totalTracks) = await catalogBuilder.build(from: processedTracks)

        try Task.checkCancellation()

        // Phase 5: Save to SwiftData and upload catalog.json to CDN
        progress.phase = .savingCatalog
        try await saveCatalog(artists: catalogArtists, totalTracks: totalTracks, storageService: storageService, config: config)
    }

    // MARK: - Scan for Audio Files

    private func scanForAudioFiles(in directory: URL) throws -> [URL] {
        var audioFiles: [URL] = []

        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .nameKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            throw UploaderError.cannotEnumerateDirectory
        }

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if Self.supportedExtensions.contains(ext) {
                audioFiles.append(fileURL)
            }
        }

        return audioFiles
    }

    // MARK: - Process Single File

    private func processFile(
        fileURL: URL,
        musicDirectory: URL,
        existingKeys: Set<String>,
        config: UploadConfiguration,
        storageService: StorageService,
        metadataExtractor: MetadataExtractor,
        artworkExtractor: ArtworkExtractor,
        audioConverter: AudioConverter
    ) async -> ProcessedTrack? {
        // Extract metadata
        let metadata = await metadataExtractor.extract(from: fileURL)

        let artist = metadata.albumArtist ?? metadata.artist ?? "Unknown Artist"
        let album = metadata.album ?? "Unknown Album"
        let title = metadata.title

        // Generate S3 key
        let format = AudioConverter.needsConversion(fileURL) ? "m4a" : fileURL.pathExtension.lowercased()
        let s3Key = Identifiers.generateS3Key(artist: artist, album: album, title: title, format: format)

        // Update progress on main thread
        await MainActor.run {
            progress.currentFile = fileURL.lastPathComponent
        }

        // Check if already uploaded
        if existingKeys.contains(s3Key) {
            await MainActor.run {
                progress.skippedFiles += 1
            }
            // Return track info even for skipped files (they're still part of catalog)
            let url = await storageService.getPublicURL(for: s3Key)
            return ProcessedTrack(
                title: title,
                artist: metadata.artist ?? artist,
                album: album,
                albumArtist: metadata.albumArtist,
                trackNumber: metadata.trackNumber,
                trackTotal: metadata.trackTotal,
                discNumber: metadata.discNumber,
                discTotal: metadata.discTotal,
                duration: metadata.duration,
                year: metadata.year,
                genre: metadata.genre,
                composer: metadata.composer,
                comment: metadata.comment,
                bitrate: metadata.bitrate,
                samplerate: metadata.samplerate,
                channels: metadata.channels,
                filesize: metadata.filesize,
                format: format,
                s3Key: s3Key,
                url: url,
                originalFormat: fileURL.pathExtension.lowercased() != format ? fileURL.pathExtension.lowercased() : nil
            )
        }

        // Convert if needed
        var uploadURL = fileURL
        var wasConverted = false
        if AudioConverter.needsConversion(fileURL) {
            do {
                uploadURL = try await audioConverter.convert(fileURL)
                wasConverted = true
                await MainActor.run {
                    progress.convertedFiles += 1
                }
            } catch {
                await MainActor.run {
                    progress.failedFiles += 1
                }
                return nil
            }
        }

        // Extract embedded artwork
        var embeddedArtworkUrl: String?
        if let artwork = await artworkExtractor.extract(from: fileURL) {
            do {
                embeddedArtworkUrl = try await storageService.uploadArtworkBytes(
                    artwork.data,
                    mimeType: artwork.mimeType,
                    artist: artist,
                    album: album
                )
            } catch {
                // Artwork upload failed, continue without it
            }
        }

        // Upload file
        do {
            let url = try await storageService.uploadFile(at: uploadURL, s3Key: s3Key)

            // Clean up converted file
            if wasConverted && uploadURL != fileURL {
                try? FileManager.default.removeItem(at: uploadURL)
            }

            await MainActor.run {
                progress.processedFiles += 1
            }

            return ProcessedTrack(
                title: title,
                artist: metadata.artist ?? artist,
                album: album,
                albumArtist: metadata.albumArtist,
                trackNumber: metadata.trackNumber,
                trackTotal: metadata.trackTotal,
                discNumber: metadata.discNumber,
                discTotal: metadata.discTotal,
                duration: metadata.duration,
                year: metadata.year,
                genre: metadata.genre,
                composer: metadata.composer,
                comment: metadata.comment,
                bitrate: metadata.bitrate,
                samplerate: metadata.samplerate,
                channels: metadata.channels,
                filesize: metadata.filesize,
                format: format,
                s3Key: s3Key,
                url: url,
                embeddedArtworkUrl: embeddedArtworkUrl,
                originalFormat: wasConverted ? fileURL.pathExtension.lowercased() : nil
            )
        } catch {
            // Clean up converted file on failure
            if wasConverted && uploadURL != fileURL {
                try? FileManager.default.removeItem(at: uploadURL)
            }

            await MainActor.run {
                progress.failedFiles += 1
            }
            return nil
        }
    }

    // MARK: - Fetch Existing AddedAt Map

    /// Fetches the existing catalog.json from CDN and builds a lookup map of s3Key -> addedAt
    /// Used to preserve addedAt dates for existing tracks during catalog rebuild
    private func fetchExistingAddedAtMap(config: UploadConfiguration) async -> [String: Date] {
        let base = config.cdnBaseURL.replacingOccurrences(of: "/\(config.spacesPrefix)", with: "")
        let prefix = config.spacesPrefix
        guard let url = URL(string: "\(base)/\(prefix)/catalog.json") else {
            return [:]
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("📋 No existing catalog found on CDN (new catalog will be created)")
                return [:]
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let catalog = try decoder.decode(MusicCatalog.self, from: data)

            // Build lookup map of s3Key -> addedAt
            var addedAtMap: [String: Date] = [:]
            for artist in catalog.artists {
                for album in artist.albums {
                    for track in album.tracks {
                        if let addedAt = track.addedAt {
                            addedAtMap[track.s3Key] = addedAt
                        }
                    }
                }
            }

            print("📋 Found \(addedAtMap.count) existing tracks with addedAt dates")
            return addedAtMap
        } catch {
            print("⚠️ Could not fetch existing catalog: \(error.localizedDescription)")
            return [:]
        }
    }

    // MARK: - Save Catalog to SwiftData and CDN

    private func saveCatalog(artists: [CatalogArtist], totalTracks: Int, storageService: StorageService, config: UploadConfiguration) async throws {
        guard let modelContext = modelContext else {
            throw UploaderError.noModelContext
        }

        // Delete existing catalog data
        try modelContext.delete(model: CatalogTrack.self)
        try modelContext.delete(model: CatalogAlbum.self)
        try modelContext.delete(model: CatalogArtist.self)
        try modelContext.delete(model: CatalogMetadata.self)

        // Insert new data
        for artist in artists {
            modelContext.insert(artist)
        }

        // Save metadata
        let metadata = CatalogMetadata(totalTracks: totalTracks)
        modelContext.insert(metadata)

        try modelContext.save()

        // Upload catalog.json to CDN for cross-device sync
        let codableArtists = artists.map { $0.toArtist() }
        let catalog = MusicCatalog(
            artists: codableArtists,
            totalTracks: totalTracks,
            generatedAt: Date().ISO8601Format()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let catalogData = try encoder.encode(catalog)

        _ = try await storageService.forceUploadData(
            catalogData,
            s3Key: "catalog.json",
            contentType: "application/json"
        )
        print("✅ Uploaded catalog.json to CDN")

        // Save CDN settings to iCloud for iOS to discover
        let store = NSUbiquitousKeyValueStore.default
        store.set(config.cdnBaseURL.replacingOccurrences(of: "/\(config.spacesPrefix)", with: ""), forKey: "cdnBaseURL")
        store.set(config.spacesPrefix, forKey: "cdnPrefix")
        store.synchronize()
        print("✅ Saved CDN settings to iCloud (prefix: \(config.spacesPrefix))")
    }
}

// MARK: - Errors

enum UploaderError: LocalizedError {
    case invalidConfiguration
    case noAudioFilesFound
    case cannotEnumerateDirectory
    case noModelContext

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Upload configuration is invalid or missing"
        case .noAudioFilesFound:
            return "No audio files found in the selected folder"
        case .cannotEnumerateDirectory:
            return "Cannot enumerate directory contents"
        case .noModelContext:
            return "Model context not configured"
        }
    }
}

#endif
