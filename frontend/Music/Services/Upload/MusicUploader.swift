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
    var discoveredFiles: Int

    /// Progress within the current phase (0.0 - 1.0)
    var progress: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(processedFiles + skippedFiles + failedFiles) / Double(totalFiles)
    }

    /// Global progress across all phases (0.0 - 1.0)
    /// Provides continuous progress instead of resetting between phases
    var globalProgress: Double {
        // Weights for each phase (total = 1.0)
        let phaseWeights: [UploadPhase: Double] = [
            .idle: 0.0,
            .scanning: 0.05,
            .fetchingExisting: 0.05,
            .fetchingMetadata: 0.30,
            .processing: 0.50,
            .buildingCatalog: 0.05,
            .savingCatalog: 0.05,
            .complete: 0.0,
            .cancelled: 0.0,
            .failed: 0.0
        ]

        // Calculate base progress from completed phases
        var baseProgress = 0.0
        for (p, weight) in phaseWeights {
            if p.rawOrder < phase.rawOrder {
                baseProgress += weight
            }
        }

        // Add progress within current phase
        let currentPhaseWeight = phaseWeights[phase] ?? 0
        return baseProgress + (progress * currentPhaseWeight)
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

        /// Numeric order for progress calculation
        var rawOrder: Int {
            switch self {
            case .idle: return 0
            case .scanning: return 1
            case .fetchingExisting: return 2
            case .fetchingMetadata: return 3
            case .processing: return 4
            case .buildingCatalog: return 5
            case .savingCatalog: return 6
            case .complete: return 7
            case .cancelled: return 8
            case .failed: return 9
            }
        }
    }
}

/// Cache for local album art lookups to avoid re-scanning the same directory
actor LocalArtworkCache {
    private var cache: [String: String?] = [:]  // dir path -> uploaded URL or nil

    func getCachedURL(for dirPath: String) -> (isCached: Bool, url: String?) {
        if let result = cache[dirPath] {
            return (true, result)
        }
        return (false, nil)
    }

    func cacheURL(_ url: String?, for dirPath: String) {
        cache[dirPath] = url
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
        currentFile: nil,
        discoveredFiles: 0
    )

    private(set) var isRunning = false
    private(set) var error: Error?

    private var uploadTask: Task<Void, Never>?
    private var config: UploadConfiguration?
    private var modelContext: ModelContext?
    private var modelContainer: ModelContainer?

    private static let supportedExtensions = Set(["mp3", "m4a", "flac", "wav", "aac", "aiff"])
    private static let maxConcurrentWorkers = 16  // Network I/O bound, can handle more parallelism
    private static let maxConcurrentMetadataExtractors = 32  // Higher for modern Macs with SSDs and 8+ cores
    private static let maxConcurrentAPILookups = 8  // Services have internal rate limiters, higher concurrency enables better pipelining

    func configure(config: UploadConfiguration, modelContext: ModelContext) {
        self.config = config
        self.modelContext = modelContext
        self.modelContainer = modelContext.container
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

        // Log cache statistics for debugging
        print("📊 Cache status:")
        print("   \(await theAudioDB.cacheStats())")

        // Phase 1: Scan for audio files
        progress.phase = .scanning
        let audioFiles = try await scanForAudioFiles(in: folderURL)

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

        // Parallel metadata extraction with limited concurrency and batched progress updates
        let extractedMetadata: [(URL, TrackMetadata)] = await withTaskGroup(of: (URL, TrackMetadata)?.self) { group in
            var results: [(URL, TrackMetadata)] = []
            results.reserveCapacity(audioFiles.count)
            var submitted = 0
            var completedSinceLastUpdate = 0
            let progressUpdateInterval = 50  // Batch UI updates to reduce main thread contention

            for fileURL in audioFiles {
                if submitted >= Self.maxConcurrentMetadataExtractors {
                    if let result = await group.next(), let r = result {
                        results.append(r)
                        completedSinceLastUpdate += 1

                        // Batch progress updates
                        if completedSinceLastUpdate >= progressUpdateInterval {
                            let completed = results.count
                            await MainActor.run { progress.processedFiles = completed }
                            completedSinceLastUpdate = 0
                        }
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
                }
            }

            // Final progress update
            await MainActor.run { progress.processedFiles = results.count }

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

        // Phase 5: Fetch corrections for unique artists (parallel with rate limiting)
        // Optimization: Check cache first to skip API calls on rescan
        var artistCorrections: [String: String] = [:]
        let cachedArtists = await theAudioDB.getCachedArtistKeys()
        let uncachedArtists = uniqueArtists.subtracting(cachedArtists)

        progress.totalFiles = uniqueArtists.count
        progress.processedFiles = 0

        if uncachedArtists.isEmpty {
            // All artists are cached - fast path
            print("✅ All \(uniqueArtists.count) artists found in cache")
            for rawArtist in uniqueArtists {
                let artistInfo = await theAudioDB.fetchArtistInfo(rawArtist)  // Returns from cache instantly
                let corrected = artistInfo.name ?? Identifiers.normalizeArtistName(rawArtist) ?? rawArtist
                artistCorrections[rawArtist] = corrected
            }
            await MainActor.run { progress.processedFiles = artistCorrections.count }
        } else {
            // Some artists need API lookup
            print("📡 Fetching \(uncachedArtists.count) uncached artists (\(cachedArtists.count) cached)")

            await withTaskGroup(of: (String, String)?.self) { group in
                var submitted = 0
                let artistArray = Array(uniqueArtists)

                for rawArtist in artistArray {
                    if submitted >= Self.maxConcurrentAPILookups {
                        if let result = await group.next(), let (raw, corrected) = result {
                            artistCorrections[raw] = corrected
                            await MainActor.run { progress.processedFiles += 1 }
                        }
                    }

                    group.addTask {
                        if Task.isCancelled { return nil }
                        let artistInfo = await theAudioDB.fetchArtistInfo(rawArtist)
                        let corrected = artistInfo.name ?? Identifiers.normalizeArtistName(rawArtist) ?? rawArtist
                        return (rawArtist, corrected)
                    }
                    submitted += 1
                }

                // Collect remaining
                for await result in group {
                    if let (raw, corrected) = result {
                        artistCorrections[raw] = corrected
                    }
                }

                // Final progress update
                await MainActor.run { progress.processedFiles = artistCorrections.count }
            }
        }

        try Task.checkCancellation()

        // Phase 6: Fetch corrections for unique albums (parallel with rate limiting)
        // Optimization: Check cache first to skip API calls on rescan
        var albumCorrections: [String: String] = [:]
        let cachedAlbums = await theAudioDB.getCachedAlbumKeys()
        let uncachedAlbums = uniqueAlbums.subtracting(cachedAlbums)

        progress.totalFiles = uniqueAlbums.count
        progress.processedFiles = 0

        if uncachedAlbums.isEmpty {
            // All albums are cached - fast path
            print("✅ All \(uniqueAlbums.count) albums found in cache")
            for albumKey in uniqueAlbums {
                let parts = albumKey.split(separator: "|", maxSplits: 1)
                guard parts.count == 2, let firstPart = parts.first else { continue }
                let rawArtist = String(firstPart)
                let rawAlbum = String(parts[1])
                let correctedArtist = artistCorrections[rawArtist] ?? rawArtist

                let albumInfo = await theAudioDB.fetchAlbumInfo(artist: correctedArtist, album: rawAlbum)  // Returns from cache
                albumCorrections[albumKey] = albumInfo.name ?? rawAlbum
            }
            await MainActor.run { progress.processedFiles = albumCorrections.count }
        } else {
            // Some albums need API lookup
            print("📡 Fetching \(uncachedAlbums.count) uncached albums (\(cachedAlbums.count) cached)")

            await withTaskGroup(of: (String, String)?.self) { group in
                var submitted = 0
                let albumArray = Array(uniqueAlbums)

                for albumKey in albumArray {
                    let parts = albumKey.split(separator: "|", maxSplits: 1)
                    guard parts.count == 2, let firstPart = parts.first else { continue }
                    let rawArtist = String(firstPart)
                    let rawAlbum = String(parts[1])
                    let correctedArtist = artistCorrections[rawArtist] ?? rawArtist

                    if submitted >= Self.maxConcurrentAPILookups {
                        if let result = await group.next(), let (key, corrected) = result {
                            albumCorrections[key] = corrected
                            await MainActor.run { progress.processedFiles += 1 }
                        }
                    }

                    group.addTask {
                        if Task.isCancelled { return nil }
                        let albumInfo = await theAudioDB.fetchAlbumInfo(artist: correctedArtist, album: rawAlbum)
                        return (albumKey, albumInfo.name ?? rawAlbum)
                    }
                    submitted += 1
                }

                // Collect remaining
                for await result in group {
                    if let (key, corrected) = result {
                        albumCorrections[key] = corrected
                    }
                }

                // Final progress update
                await MainActor.run { progress.processedFiles = albumCorrections.count }
            }
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

        // Save caches for future scans
        await metadataExtractor.saveCache()
        await theAudioDB.saveCache()

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
            currentFile: nil,
            discoveredFiles: 0
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
        let localArtworkCache = LocalArtworkCache()
        let catalogBuilder = CatalogBuilder(
            theAudioDB: theAudioDB,
            musicBrainz: musicBrainz,
            lastFM: lastFM,
            storageService: storageService,
            cdnBaseURL: config.cdnBaseURL
        )

        // Set existing keys cache (skipped files are already on remote)
        let existingKeys = Set(preview.skippedFiles.map { $0.s3Key })
        await storageService.setExistingKeysCache(existingKeys)

        // Fetch existing catalog to preserve addedAt dates for existing tracks
        let existingAddedAtMap = await fetchExistingAddedAtMap(config: config)

        try Task.checkCancellation()

        // Phase: Process files
        progress.phase = .processing
        var processedTracks: [ProcessedTrack] = []

        // Process new files (upload) with batched progress updates
        let results = try await withThrowingTaskGroup(of: ProcessedTrack?.self) { group in
            var submitted = 0
            var resultsArray: [ProcessedTrack] = []
            resultsArray.reserveCapacity(preview.newFiles.count)
            var completedSinceLastUpdate = 0
            let progressUpdateInterval = 10  // Batch UI updates to reduce main thread contention

            for item in preview.newFiles {
                // Limit concurrent workers
                if submitted >= Self.maxConcurrentWorkers {
                    if let result = try await group.next() {
                        if let track = result {
                            resultsArray.append(track)
                        }
                        completedSinceLastUpdate += 1

                        // Batch progress updates
                        if completedSinceLastUpdate >= progressUpdateInterval {
                            let completed = resultsArray.count
                            await MainActor.run { progress.processedFiles = completed }
                            completedSinceLastUpdate = 0
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
                        localArtworkCache: localArtworkCache,
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

            // Final progress update
            await MainActor.run { progress.processedFiles = resultsArray.count }

            return resultsArray
        }

        processedTracks = results

        // Process skipped files in parallel (they're still part of the catalog)
        // These files already exist on remote, just need metadata extraction + local art check
        let skippedTracks = await withTaskGroup(of: ProcessedTrack?.self) { group in
            var submitted = 0
            var results: [ProcessedTrack] = []
            results.reserveCapacity(preview.skippedFiles.count)

            for item in preview.skippedFiles {
                // Limit concurrency (metadata extraction is I/O heavy)
                if submitted >= Self.maxConcurrentMetadataExtractors {
                    if let result = await group.next(), let track = result {
                        results.append(track)
                    }
                }

                group.addTask {
                    // Verify file still exists on remote (may have been deleted between scan and upload)
                    let exists = await storageService.fileExists(item.s3Key)
                    if !exists {
                        print("⚠️ Skipped file no longer exists on remote: \(item.s3Key)")
                        return nil
                    }

                    let metadata = await metadataExtractor.extract(from: item.fileURL)
                    let url = await storageService.getPublicURL(for: item.s3Key)

                    // Preserve existing addedAt or use current date as fallback
                    let addedAt = existingAddedAtMap[item.s3Key] ?? Date()

                    // Check for local album art (fast filesystem check, no embedded extraction)
                    var embeddedArtworkUrl: String?
                    let dirPath = item.fileURL.deletingLastPathComponent().path
                    let cached = await localArtworkCache.getCachedURL(for: dirPath)
                    if cached.isCached {
                        embeddedArtworkUrl = cached.url
                    } else if let localArt = artworkExtractor.extractFromDirectory(item.fileURL.deletingLastPathComponent()) {
                        do {
                            let uploadedUrl = try await storageService.uploadArtworkBytes(
                                localArt.data,
                                mimeType: localArt.mimeType,
                                artist: item.artist,
                                album: item.album
                            )
                            await localArtworkCache.cacheURL(uploadedUrl, for: dirPath)
                            embeddedArtworkUrl = uploadedUrl
                        } catch {
                            await localArtworkCache.cacheURL(nil, for: dirPath)
                        }
                    } else {
                        await localArtworkCache.cacheURL(nil, for: dirPath)
                    }

                    return ProcessedTrack(
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
                        composer: metadata.composer,
                        comment: metadata.comment,
                        bitrate: metadata.bitrate,
                        samplerate: metadata.samplerate,
                        channels: metadata.channels,
                        filesize: metadata.filesize,
                        format: item.format,
                        s3Key: item.s3Key,
                        url: url,
                        embeddedArtworkUrl: embeddedArtworkUrl,
                        originalFormat: item.needsConversion ? item.fileURL.pathExtension.lowercased() : nil,
                        addedAt: addedAt
                    )
                }
                submitted += 1
            }

            // Collect remaining
            for await result in group {
                if let track = result {
                    results.append(track)
                }
            }
            return results
        }

        processedTracks.append(contentsOf: skippedTracks)

        try Task.checkCancellation()

        // Phase: Build catalog
        progress.phase = .buildingCatalog
        let (catalogArtists, totalTracks) = await catalogBuilder.build(from: processedTracks)

        // Save external API caches for future scans
        await theAudioDB.saveCache()
        if let mb = musicBrainz {
            await mb.saveCache()
        }
        if let lfm = lastFM {
            await lfm.saveCache()
        }

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
        localArtworkCache: LocalArtworkCache,
        existingAddedAtMap: [String: Date]
    ) async -> ProcessedTrack? {
        let fileURL = previewItem.fileURL
        let s3Key = previewItem.s3Key

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
                print("❌ Conversion failed for \(previewItem.s3Key): \(error.localizedDescription)")
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
                print("⚠️ Artwork upload failed for \(previewItem.s3Key): \(error.localizedDescription)")
            }
        }

        // Fallback: local album art (cover.jpg, folder.png, etc.)
        if embeddedArtworkUrl == nil {
            let dirPath = fileURL.deletingLastPathComponent().path
            let cached = await localArtworkCache.getCachedURL(for: dirPath)
            if cached.isCached {
                embeddedArtworkUrl = cached.url
            } else if let localArt = artworkExtractor.extractFromDirectory(fileURL.deletingLastPathComponent()) {
                do {
                    let uploadedUrl = try await storageService.uploadArtworkBytes(
                        localArt.data,
                        mimeType: localArt.mimeType,
                        artist: previewItem.artist,
                        album: previewItem.album
                    )
                    await localArtworkCache.cacheURL(uploadedUrl, for: dirPath)
                    embeddedArtworkUrl = uploadedUrl
                } catch {
                    print("⚠️ Local artwork upload failed for \(previewItem.s3Key): \(error.localizedDescription)")
                    await localArtworkCache.cacheURL(nil, for: dirPath)
                }
            } else {
                await localArtworkCache.cacheURL(nil, for: dirPath)
            }
        }

        // Upload file with corrected S3 key
        do {
            let url = try await storageService.uploadFile(at: uploadURL, s3Key: s3Key)

            // Clean up converted file
            if wasConverted && uploadURL != fileURL {
                try? FileManager.default.removeItem(at: uploadURL)
            }

            // New uploads get current date, existing tracks preserve their addedAt
            let addedAt = existingAddedAtMap[s3Key] ?? Date()

            return ProcessedTrack(
                title: previewItem.title,
                artist: metadata.artist ?? previewItem.artist,
                album: previewItem.album,
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
                format: previewItem.format,
                s3Key: s3Key,
                url: url,
                embeddedArtworkUrl: embeddedArtworkUrl,
                originalFormat: wasConverted ? fileURL.pathExtension.lowercased() : nil,
                addedAt: addedAt
            )
        } catch {
            print("❌ Upload failed for \(previewItem.s3Key): \(error.localizedDescription)")

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

    // MARK: - Scan for Audio Files

    private func scanForAudioFiles(in directory: URL) async throws -> [URL] {
        progress.discoveredFiles = 0
        let supportedExts = Self.supportedExtensions

        // Run enumeration on background thread for speed
        let audioFiles = try await Task.detached {
            var files: [URL] = []
            files.reserveCapacity(10000)  // Pre-allocate for large libraries

            let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey]
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                throw UploaderError.cannotEnumerateDirectory
            }

            var count = 0
            let updateInterval = 500  // Update UI every 500 files

            for case let fileURL as URL in enumerator {
                try Task.checkCancellation()

                let ext = fileURL.pathExtension.lowercased()
                if supportedExts.contains(ext) {
                    files.append(fileURL)
                    count += 1

                    // Batch progress updates to reduce main thread hops
                    if count % updateInterval == 0 {
                        let currentCount = count
                        await MainActor.run {
                            self.progress.discoveredFiles = currentCount
                        }
                    }
                }
            }

            return files
        }.value

        // Final progress update
        progress.discoveredFiles = audioFiles.count
        return audioFiles
    }

    // MARK: - Fetch Existing AddedAt Map

    /// Fetches the existing catalog.json from CDN and builds a lookup map of s3Key -> addedAt
    /// Used to preserve addedAt dates for existing tracks during catalog rebuild
    private func fetchExistingAddedAtMap(config: UploadConfiguration) async -> [String: Date] {
        guard let url = URL(string: "\(config.cdnBaseURLWithoutPrefix)/\(config.spacesPrefix)/catalog.json") else {
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
        guard let modelContainer = modelContainer else {
            throw UploaderError.noModelContext
        }

        // Convert to codable DTOs first (SwiftData models can't cross context boundaries)
        let codableArtists = artists.map { $0.toArtist() }
        let catalog = MusicCatalog(
            artists: codableArtists,
            totalTracks: totalTracks,
            generatedAt: Date().ISO8601Format()
        )

        // Save to SwiftData on background context (matches MusicService.saveCatalogToSwiftData pattern)
        try await Task.detached {
            let bgContext = ModelContext(modelContainer)
            bgContext.autosaveEnabled = false

            try bgContext.delete(model: CatalogTrack.self)
            try bgContext.delete(model: CatalogAlbum.self)
            try bgContext.delete(model: CatalogArtist.self)
            try bgContext.delete(model: CatalogMetadata.self)

            // Re-create models inside the background context from codable DTOs
            for artist in catalog.artists {
                let catalogArtist = CatalogArtist(
                    id: artist.id,
                    name: artist.name,
                    bio: artist.bio,
                    imageUrl: artist.imageUrl,
                    genre: artist.genre,
                    style: artist.style,
                    mood: artist.mood,
                    artistType: artist.artistType,
                    area: artist.area,
                    beginDate: artist.beginDate,
                    endDate: artist.endDate,
                    disambiguation: artist.disambiguation
                )

                for album in artist.albums {
                    let catalogAlbum = CatalogAlbum(
                        id: album.id,
                        name: album.name,
                        imageUrl: album.imageUrl,
                        wiki: album.wiki,
                        releaseDate: album.releaseDate,
                        genre: album.genre,
                        style: album.style,
                        mood: album.mood,
                        theme: album.theme,
                        releaseType: album.releaseType,
                        country: album.country,
                        label: album.label,
                        barcode: album.barcode,
                        mediaFormat: album.mediaFormat
                    )
                    catalogAlbum.artist = catalogArtist
                    if catalogArtist.albums == nil { catalogArtist.albums = [] }
                    catalogArtist.albums?.append(catalogAlbum)

                    for track in album.tracks {
                        let catalogTrack = CatalogTrack(
                            s3Key: track.s3Key,
                            title: track.title,
                            artistName: track.artist,
                            albumName: track.album,
                            trackNumber: track.trackNumber,
                            duration: track.duration,
                            format: track.format,
                            url: track.url,
                            embeddedArtworkUrl: track.embeddedArtworkUrl,
                            genre: track.genre,
                            style: track.style,
                            mood: track.mood,
                            theme: track.theme,
                            albumArtist: track.albumArtist,
                            trackTotal: track.trackTotal,
                            discNumber: track.discNumber,
                            discTotal: track.discTotal,
                            year: track.year,
                            composer: track.composer,
                            comment: track.comment,
                            bitrate: track.bitrate,
                            samplerate: track.samplerate,
                            channels: track.channels,
                            filesize: track.filesize,
                            originalFormat: track.originalFormat,
                            addedAt: track.addedAt
                        )
                        catalogTrack.catalogAlbum = catalogAlbum
                        if catalogAlbum.tracks == nil { catalogAlbum.tracks = [] }
                        catalogAlbum.tracks?.append(catalogTrack)
                    }
                }

                bgContext.insert(catalogArtist)
            }

            let metadata = CatalogMetadata(totalTracks: catalog.totalTracks)
            bgContext.insert(metadata)

            try bgContext.save()
        }.value

        // Upload catalog.json to CDN for cross-device sync
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let catalogData = try encoder.encode(catalog)

        _ = try await storageService.forceUploadData(
            catalogData,
            s3Key: "catalog.json",
            contentType: "application/json"
        )
        print("✅ Uploaded catalog.json to CDN (\(catalogData.count) bytes)")

        // Save CDN settings to iCloud for iOS to discover
        let store = NSUbiquitousKeyValueStore.default
        store.set(config.cdnBaseURLWithoutPrefix, forKey: "cdnBaseURL")
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
