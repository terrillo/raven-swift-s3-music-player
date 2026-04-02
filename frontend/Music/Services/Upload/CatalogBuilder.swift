//
//  CatalogBuilder.swift
//  Music
//
//  Builds the hierarchical music catalog from processed tracks.
//  Enriches with TheAudioDB/MusicBrainz/Last.fm metadata.
//

import Foundation

#if os(macOS)

/// Processed track data ready for catalog building
struct ProcessedTrack {
    var title: String
    var artist: String
    var album: String
    var albumArtist: String?
    var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var discTotal: Int?
    var duration: Int?
    var year: Int?
    var genre: String?
    var style: String?
    var mood: String?
    var theme: String?
    var composer: String?
    var comment: String?
    var bitrate: Double?
    var samplerate: Int?
    var channels: Int?
    var filesize: Int?
    var format: String
    var s3Key: String
    var url: String?
    var embeddedArtworkUrl: String?
    var originalFormat: String?
    var addedAt: Date?
}

actor CatalogBuilder {
    private let theAudioDB: TheAudioDBService
    private let musicBrainz: MusicBrainzService?
    private let lastFM: LastFMService?
    private let storageService: StorageService
    private let cdnBaseURL: String  // Store CDN URL for sync access (avoids actor hops)

    init(
        theAudioDB: TheAudioDBService,
        musicBrainz: MusicBrainzService? = nil,
        lastFM: LastFMService? = nil,
        storageService: StorageService,
        cdnBaseURL: String
    ) {
        self.theAudioDB = theAudioDB
        self.musicBrainz = musicBrainz
        self.lastFM = lastFM
        self.storageService = storageService
        self.cdnBaseURL = cdnBaseURL
    }

    /// Sync URL generation (no actor hop needed)
    private func getPublicURL(for s3Key: String) -> String {
        "\(cdnBaseURL)/\(s3Key)"
    }

    /// Build catalog from processed tracks
    func build(from tracks: [ProcessedTrack]) async -> (artists: [CatalogArtist], totalTracks: Int) {
        // Group tracks by normalized artist key
        var artistAlbums: [String: [String: [ProcessedTrack]]] = [:]
        var artistDisplayNames: [String: String] = [:]

        for track in tracks {
            // Use album_artist for grouping (fallback to artist)
            let albumArtist = Identifiers.normalizeArtistName(track.albumArtist ?? track.artist) ?? track.artist
            let artistKey = Identifiers.getArtistGroupingKey(albumArtist)

            // Track canonical display name (first occurrence)
            if artistDisplayNames[artistKey] == nil {
                artistDisplayNames[artistKey] = albumArtist
            }

            if artistAlbums[artistKey] == nil {
                artistAlbums[artistKey] = [:]
            }
            let albumKey = Identifiers.getAlbumGroupingKey(track.album)
            if artistAlbums[artistKey]?[albumKey] == nil {
                artistAlbums[artistKey]?[albumKey] = []
            }
            artistAlbums[artistKey]?[albumKey]?.append(track)
        }

        // Build catalog structure - process artists in parallel
        let sortedArtistKeys = artistAlbums.keys.sorted()
        let maxConcurrentArtists = 8

        let catalogArtists: [CatalogArtist] = await withTaskGroup(of: (Int, CatalogArtist)?.self) { group in
            var submitted = 0
            var results: [(Int, CatalogArtist)] = []
            results.reserveCapacity(sortedArtistKeys.count)

            for (index, artistKey) in sortedArtistKeys.enumerated() {
                let displayName = artistDisplayNames[artistKey] ?? artistKey
                guard let albums = artistAlbums[artistKey] else { continue }

                // Limit concurrent artist processing
                if submitted >= maxConcurrentArtists {
                    if let result = await group.next(), let r = result {
                        results.append(r)
                    }
                }

                group.addTask {
                    let artist = await self.buildArtist(name: displayName, albumsDict: albums)
                    return (index, artist)
                }
                submitted += 1
            }

            // Collect remaining results
            for await result in group {
                if let r = result {
                    results.append(r)
                }
            }

            // Sort by original index to maintain alphabetical order
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        let actualTrackCount = catalogArtists.flatMap { $0.albums ?? [] }.reduce(0) { $0 + ($1.tracks?.count ?? 0) }
        return (catalogArtists, actualTrackCount)
    }

    // MARK: - Build Artist

    private func buildArtist(name: String, albumsDict: [String: [ProcessedTrack]]) async -> CatalogArtist {
        // Fetch artist metadata from TheAudioDB
        let artistInfo = await theAudioDB.fetchArtistInfo(name)

        // Fetch detailed artist info from MusicBrainz
        var artistDetails: ArtistDetails?
        if let musicBrainz = musicBrainz {
            artistDetails = await musicBrainz.getArtistDetails(name)
        }

        // Build albums in parallel, collecting MusicBrainz primary artist names
        let sortedAlbumNames = albumsDict.keys.sorted()

        let albumResults: [(CatalogAlbum, String?)] = await withTaskGroup(of: (Int, CatalogAlbum, String?)?.self) { group in
            var results: [(Int, CatalogAlbum, String?)] = []
            results.reserveCapacity(sortedAlbumNames.count)

            for (index, albumName) in sortedAlbumNames.enumerated() {
                guard let albumTracks = albumsDict[albumName] else { continue }

                group.addTask {
                    let (album, mbPrimaryArtist) = await self.buildAlbum(
                        artistName: name,
                        albumName: albumName,
                        tracks: albumTracks,
                        artistGenre: artistInfo.genre
                    )
                    return (index, album, mbPrimaryArtist)
                }
            }

            for await result in group {
                if let r = result {
                    results.append(r)
                }
            }

            // Sort by original index to maintain album order
            return results.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }

        let catalogAlbums = albumResults.map(\.0)

        // Merge albums that ended up with the same ID after API name corrections
        let mergedAlbums = mergeAlbumsByID(catalogAlbums)

        // Use MusicBrainz primary artist name if available (majority vote, non-empty only)
        let mbArtistNames = albumResults.compactMap(\.1).filter { !$0.isEmpty }
        let correctedName: String
        if let mostCommon = Dictionary(grouping: mbArtistNames, by: { $0 })
            .max(by: { $0.value.count < $1.value.count })?.key {
            correctedName = mostCommon
        } else {
            correctedName = name
        }

        let artistId = Identifiers.sanitizeS3Key(correctedName)
        let artist = CatalogArtist(
            id: artistId,
            name: correctedName,
            bio: artistInfo.bio,
            imageUrl: artistInfo.imageUrl,
            genre: artistInfo.genre,
            style: artistInfo.style,
            mood: artistInfo.mood,
            artistType: artistDetails?.artistType,
            area: artistDetails?.area,
            beginDate: artistDetails?.beginDate,
            endDate: artistDetails?.endDate,
            disambiguation: artistDetails?.disambiguation
        )

        // Link albums to artist
        for album in mergedAlbums {
            album.artist = artist
            if artist.albums == nil { artist.albums = [] }
            artist.albums?.append(album)
        }

        return artist
    }

    // MARK: - Merge Duplicate Albums

    /// Merge albums that share the same ID (e.g., after TheAudioDB corrects different
    /// raw album names to the same canonical name).
    private func mergeAlbumsByID(_ albums: [CatalogAlbum]) -> [CatalogAlbum] {
        var merged: [String: CatalogAlbum] = [:]
        var insertionOrder: [String] = []
        for album in albums {
            if let existing = merged[album.id] {
                let existingKeys = Set((existing.tracks ?? []).map(\.s3Key))
                let newTracks = (album.tracks ?? []).filter { !existingKeys.contains($0.s3Key) }
                existing.tracks = (existing.tracks ?? []) + newTracks
                existing.imageUrl = existing.imageUrl ?? album.imageUrl
                existing.wiki = existing.wiki ?? album.wiki
                existing.releaseDate = existing.releaseDate ?? album.releaseDate
                existing.genre = existing.genre ?? album.genre
                existing.style = existing.style ?? album.style
                existing.mood = existing.mood ?? album.mood
                existing.theme = existing.theme ?? album.theme
                existing.releaseType = existing.releaseType ?? album.releaseType
                existing.country = existing.country ?? album.country
                existing.label = existing.label ?? album.label
                existing.barcode = existing.barcode ?? album.barcode
                existing.mediaFormat = existing.mediaFormat ?? album.mediaFormat
            } else {
                merged[album.id] = album
                insertionOrder.append(album.id)
            }
        }
        // Re-sort tracks by disc/track number within each merged album
        for album in merged.values {
            album.tracks?.sort {
                let disc0 = $0.discNumber ?? 1
                let disc1 = $1.discNumber ?? 1
                if disc0 != disc1 { return disc0 < disc1 }
                return ($0.trackNumber ?? 999) < ($1.trackNumber ?? 999)
            }
        }
        return insertionOrder.compactMap { merged[$0] }
    }

    // MARK: - Build Album

    private func buildAlbum(
        artistName: String,
        albumName: String,
        tracks: [ProcessedTrack],
        artistGenre: String?
    ) async -> (CatalogAlbum, String?) {
        // Sort tracks by track number
        let sortedTracks = tracks.sorted { ($0.trackNumber ?? 999) < ($1.trackNumber ?? 999) }

        // Get local metadata from first track
        let localYear = sortedTracks.first?.year
        let localGenre = sortedTracks.first?.genre

        // === Fetch metadata from all sources IN PARALLEL ===

        let originalAlbumName = sortedTracks.first?.album ?? albumName

        // Start all API lookups concurrently
        async let albumInfoTask = theAudioDB.fetchAlbumInfo(artist: artistName, album: originalAlbumName)
        async let releaseDetailsTask: ReleaseDetails? = {
            if let musicBrainz = musicBrainz {
                return await musicBrainz.getReleaseDetails(artist: artistName, album: originalAlbumName)
            }
            return nil
        }()
        async let lastFMInfoTask: AlbumInfo? = {
            if let lastFM = lastFM {
                return await lastFM.fetchAlbumInfo(artist: artistName, album: originalAlbumName)
            }
            return nil
        }()

        // Await all results concurrently
        var albumInfo = await albumInfoTask
        let releaseDetails = await releaseDetailsTask
        let lastFMInfo = await lastFMInfoTask

        // If TheAudioDB doesn't have album by name, try track lookup (sequential fallback)
        if albumInfo.name == nil, let firstTrack = sortedTracks.first {
            let trackInfo = await theAudioDB.fetchTrackInfo(artist: artistName, track: firstTrack.title)
            if let trackAlbum = trackInfo.album {
                let correctedAlbumInfo = await theAudioDB.fetchAlbumInfo(artist: artistName, album: trackAlbum)
                if correctedAlbumInfo.name != nil || correctedAlbumInfo.wiki != nil || correctedAlbumInfo.imageUrl != nil {
                    albumInfo = correctedAlbumInfo
                }
            }
        }

        // === Apply cascade for each field ===
        // Priority: TheAudioDB → MusicBrainz → LastFM → Local file metadata

        let displayAlbumName = firstNonEmpty(
            albumInfo.name,
            releaseDetails?.title,
            lastFMInfo?.name,
            originalAlbumName
        ) ?? albumName

        // Wiki cascade: TheAudioDB → LastFM
        let wiki = albumInfo.wiki ?? lastFMInfo?.wiki

        // Image cascade: TheAudioDB → LastFM → embedded artwork
        let albumImage = firstNonEmpty(
            albumInfo.imageUrl,
            lastFMInfo?.imageUrl,
            sortedTracks.first(where: { $0.embeddedArtworkUrl != nil })?.embeddedArtworkUrl
        )

        // Release date cascade: TheAudioDB → MusicBrainz → local year tag
        let releaseDate = albumInfo.releaseDate ?? releaseDetails?.releaseDate ?? localYear

        // Genre cascade: TheAudioDB → MusicBrainz tags → local file → artist genre
        let albumGenre = firstNonEmpty(
            albumInfo.genre,
            releaseDetails?.tags.first,
            localGenre,
            artistGenre
        )

        // Build catalog tracks
        // Note: s3Key is already correct from the preview/upload phase (uses TheAudioDB-corrected names)
        var catalogTracks: [CatalogTrack] = []
        var seenS3Keys = Set<String>()

        for track in sortedTracks {
            let s3Key = track.s3Key

            // Deduplicate by s3_key
            if seenS3Keys.contains(s3Key) {
                continue
            }
            seenS3Keys.insert(s3Key)

            // Get URL for s3_key (sync, no actor hop needed)
            let url = getPublicURL(for: s3Key)

            let catalogTrack = CatalogTrack(
                s3Key: s3Key,
                title: track.title,
                artistName: track.artist,
                albumName: displayAlbumName,
                trackNumber: track.trackNumber,
                duration: track.duration,
                format: track.format,
                url: url,
                embeddedArtworkUrl: track.embeddedArtworkUrl ?? albumImage,
                genre: track.genre ?? albumGenre,
                style: track.style ?? albumInfo.style,
                mood: track.mood ?? albumInfo.mood,
                theme: track.theme ?? albumInfo.theme,
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
            catalogTracks.append(catalogTrack)
        }

        let albumId = "\(Identifiers.sanitizeS3Key(artistName))/\(Identifiers.sanitizeS3Key(displayAlbumName))"
        let album = CatalogAlbum(
            id: albumId,
            name: displayAlbumName,
            imageUrl: albumImage,
            wiki: wiki,
            releaseDate: releaseDate,
            genre: albumGenre,
            style: albumInfo.style,
            mood: albumInfo.mood,
            theme: albumInfo.theme,
            releaseType: releaseDetails?.releaseType,
            country: releaseDetails?.country,
            label: releaseDetails?.label,
            barcode: releaseDetails?.barcode,
            mediaFormat: releaseDetails?.mediaFormat
        )

        // Link tracks to album
        for track in catalogTracks {
            track.catalogAlbum = album
            if album.tracks == nil { album.tracks = [] }
            album.tracks?.append(track)
        }

        return (album, releaseDetails?.primaryArtist)
    }

    // MARK: - Helper Methods

    /// Returns the first non-nil, non-empty string from the provided values
    private func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let v = value, !v.isEmpty {
                return v
            }
        }
        return nil
    }
}

#endif
