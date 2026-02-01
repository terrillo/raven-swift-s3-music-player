//
//  RemoteScannerService.swift
//  Music
//
//  Scans S3 bucket to discover existing music files for initial sync.
//

import Foundation
import SwiftData

#if os(macOS)

// MARK: - Remote Scanner Service

/// Service for scanning S3 bucket to discover existing music files.
/// Used for initial sync or recovery when iCloud records are lost.
@MainActor
@Observable
class RemoteScannerService {
    private(set) var isScanning = false
    private(set) var isImporting = false
    private(set) var progress: Double = 0
    private(set) var importProgress: Double = 0
    private(set) var currentImportFile: String = ""
    private(set) var importedCount: Int = 0
    private(set) var discoveredFiles: [String] = []
    var error: Error?

    private var modelContext: ModelContext?

    private(set) var connectionTestResult: String?

    init() {}

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        print("[RemoteScanner] Configured with modelContext")
    }

    /// Test S3 connection by attempting to list files.
    func testConnection(credentials: S3Credentials) async -> (success: Bool, message: String) {
        print("[RemoteScanner] testConnection() called")
        print("[RemoteScanner] Testing connection to bucket: \(credentials.bucket)")
        print("[RemoteScanner] Region: \(credentials.region), Prefix: \(credentials.prefix)")
        print("[RemoteScanner] Access key length: \(credentials.accessKey.count)")
        print("[RemoteScanner] Secret key length: \(credentials.secretKey.count)")

        connectionTestResult = nil

        let s3 = S3Service(credentials: credentials)

        do {
            let keys = try await s3.listAllFiles()
            let message = "Connected successfully. Found \(keys.count) files in bucket."
            print("[RemoteScanner] \(message)")
            connectionTestResult = message
            return (true, message)
        } catch {
            let message = "Connection failed: \(error.localizedDescription)"
            print("[RemoteScanner] \(message)")
            connectionTestResult = message
            return (false, message)
        }
    }

    /// Scan S3 bucket and discover existing music files.
    /// Returns list of S3 keys that don't have corresponding UploadedTrack records.
    func scanRemote(credentials: S3Credentials) async -> [String] {
        print("[RemoteScanner] scanRemote() called")
        print("[RemoteScanner] isScanning: \(isScanning)")
        print("[RemoteScanner] modelContext configured: \(modelContext != nil)")
        print("[RemoteScanner] credentials - bucket: \(credentials.bucket), region: \(credentials.region), prefix: \(credentials.prefix)")

        guard !isScanning else {
            print("[RemoteScanner] Already scanning, returning early")
            return []
        }
        guard let modelContext else {
            print("[RemoteScanner] ERROR: modelContext not configured")
            error = ScanError.notConfigured
            return []
        }

        isScanning = true
        progress = 0
        discoveredFiles = []
        error = nil

        let s3 = S3Service(credentials: credentials)
        print("[RemoteScanner] S3Service created, starting listAllFiles...")

        do {
            // List all files in S3
            let allKeys = try await s3.listAllFiles()
            print("[RemoteScanner] listAllFiles returned \(allKeys.count) keys")
            progress = 0.5

            // Filter to audio files only
            let audioExtensions = Set(["mp3", "m4a", "flac", "wav", "aac", "aiff"])
            let audioKeys = allKeys.filter { key in
                let ext = (key as NSString).pathExtension.lowercased()
                return audioExtensions.contains(ext)
            }
            print("[RemoteScanner] Filtered to \(audioKeys.count) audio files")

            // Check which ones are already in the database
            var missingKeys: [String] = []
            let total = audioKeys.count

            for (index, key) in audioKeys.enumerated() {
                let descriptor = FetchDescriptor<UploadedTrack>(
                    predicate: #Predicate { $0.s3Key == key }
                )
                let count = (try? modelContext.fetchCount(descriptor)) ?? 0

                if count == 0 {
                    missingKeys.append(key)
                }

                progress = 0.5 + (Double(index + 1) / Double(total) * 0.5)
            }

            print("[RemoteScanner] Found \(missingKeys.count) files not in database")
            discoveredFiles = missingKeys
            isScanning = false
            return missingKeys

        } catch {
            print("[RemoteScanner] ERROR: \(error.localizedDescription)")
            self.error = error
            isScanning = false
            return []
        }
    }

    /// Import discovered files into the database.
    /// Creates UploadedTrack records with basic metadata extracted from S3 keys.
    /// Fetches artist/album images from TheAudioDB with Last.fm fallback.
    func importDiscoveredFiles(credentials: S3Credentials, lastFMApiKey: String = "") async -> Int {
        guard let modelContext else { return 0 }

        isImporting = true
        importProgress = 0
        importedCount = 0
        currentImportFile = ""

        // Initialize API services for metadata fetching
        let s3 = S3Service(credentials: credentials)
        let theAudioDB = TheAudioDBService(s3Service: s3)
        let musicBrainz = MusicBrainzService()
        let lastFM = LastFMService(apiKey: lastFMApiKey, s3Service: s3)

        let total = discoveredFiles.count

        print("[RemoteScanner] Starting import of \(total) files")

        for (index, key) in discoveredFiles.enumerated() {
            currentImportFile = key
            importProgress = Double(index) / Double(total)

            // Parse s3_key: Artist/Album/Track.m4a
            let components = key.components(separatedBy: "/")
            guard components.count >= 3 else { continue }

            let artistName = components[0].replacingOccurrences(of: "-", with: " ")
            let albumName = components[1].replacingOccurrences(of: "-", with: " ")
            let filename = (components[2] as NSString).deletingPathExtension
            let title = filename.replacingOccurrences(of: "-", with: " ")
            let format = (components[2] as NSString).pathExtension.lowercased()

            let url = await s3.getPublicUrl(for: key)

            let track = UploadedTrack(
                s3Key: key,
                url: url,
                title: title,
                format: format,
                artist: artistName,
                album: albumName
            )

            // Set relationship IDs
            track.uploadedArtistId = UploadIdentifiers.artistId(artistName)
            track.uploadedAlbumId = UploadIdentifiers.albumId(artist: artistName, album: albumName)

            modelContext.insert(track)

            // Create artist if needed - fetch metadata from APIs
            let artistId = track.uploadedArtistId!
            let artistDescriptor = FetchDescriptor<UploadedArtist>(
                predicate: #Predicate { $0.id == artistId }
            )
            if (try? modelContext.fetch(artistDescriptor))?.first == nil {
                // Fetch artist info from TheAudioDB
                let artistInfo = await theAudioDB.fetchArtistInfo(artistName, modelContainer: modelContext.container)
                let mbDetails = await musicBrainz.getArtistDetails(artistName)

                let artist = UploadedArtist(id: artistId, name: artistName)
                artist.imageUrl = artistInfo.imageUrl
                artist.bio = artistInfo.bio
                artist.genre = artistInfo.genre
                artist.style = artistInfo.style
                artist.mood = artistInfo.mood
                artist.artistType = mbDetails.artistType ?? artistInfo.artistType
                artist.area = mbDetails.area ?? artistInfo.area
                artist.beginDate = mbDetails.beginDate ?? artistInfo.beginDate
                artist.endDate = mbDetails.endDate ?? artistInfo.endDate
                artist.disambiguation = mbDetails.disambiguation ?? artistInfo.disambiguation
                modelContext.insert(artist)

                print("[RemoteScanner] Created artist '\(artistName)' with image: \(artistInfo.imageUrl != nil)")
            }

            // Create album if needed - fetch metadata from APIs
            let albumId = track.uploadedAlbumId!
            let albumDescriptor = FetchDescriptor<UploadedAlbum>(
                predicate: #Predicate { $0.id == albumId }
            )
            if (try? modelContext.fetch(albumDescriptor))?.first == nil {
                // Fetch album info from TheAudioDB with Last.fm fallback
                var albumInfo = await theAudioDB.fetchAlbumInfo(artistName, albumName, modelContainer: modelContext.container)

                // Fallback to Last.fm if no image
                if albumInfo.imageUrl == nil && !lastFMApiKey.isEmpty {
                    let lastFmInfo = await lastFM.fetchAlbumInfo(artistName, albumName)
                    if albumInfo.name == nil { albumInfo.name = lastFmInfo.name }
                    if albumInfo.imageUrl == nil { albumInfo.imageUrl = lastFmInfo.imageUrl }
                    if albumInfo.wiki == nil { albumInfo.wiki = lastFmInfo.wiki }
                }

                // Get additional details from MusicBrainz
                let mbInfo = await musicBrainz.getReleaseDetails(artistName, albumName)

                let album = UploadedAlbum(
                    id: albumId,
                    name: albumInfo.name ?? albumName,
                    localName: albumName,
                    artistId: artistId
                )
                album.imageUrl = albumInfo.imageUrl
                album.wiki = albumInfo.wiki
                album.releaseDate = albumInfo.releaseDate ?? mbInfo.releaseDate
                album.genre = albumInfo.genre
                album.style = albumInfo.style
                album.mood = albumInfo.mood
                album.theme = albumInfo.theme
                album.releaseType = mbInfo.releaseType ?? albumInfo.releaseType
                album.country = mbInfo.country ?? albumInfo.country
                album.label = mbInfo.label ?? albumInfo.label
                album.barcode = mbInfo.barcode
                album.mediaFormat = mbInfo.mediaFormat
                modelContext.insert(album)

                print("[RemoteScanner] Created album '\(albumName)' with image: \(album.imageUrl != nil)")
            }

            importedCount = index + 1
        }

        try? modelContext.save()
        print("[RemoteScanner] Import complete: \(importedCount) files imported")

        let finalCount = importedCount
        discoveredFiles = []
        isImporting = false
        importProgress = 1.0
        currentImportFile = ""

        return finalCount
    }
}

// MARK: - Errors

enum ScanError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Scanner not configured with model context"
        }
    }
}

#else

// iOS stub
@MainActor
@Observable
class RemoteScannerService {
    private(set) var isScanning = false
    private(set) var isImporting = false
    private(set) var progress: Double = 0
    private(set) var importProgress: Double = 0
    private(set) var currentImportFile: String = ""
    private(set) var importedCount: Int = 0
    private(set) var discoveredFiles: [String] = []
    var error: Error?

    func configure(modelContext: ModelContext) {}
    func scanRemote(credentials: S3Credentials) async -> [String] { [] }
    func importDiscoveredFiles(credentials: S3Credentials, lastFMApiKey: String = "") async -> Int { 0 }
    func testConnection(credentials: S3Credentials) async -> (success: Bool, message: String) { (false, "Not available on iOS") }
}

#endif
