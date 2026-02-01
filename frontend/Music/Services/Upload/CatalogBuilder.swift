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
}

actor CatalogBuilder {
    private let theAudioDB: TheAudioDBService
    private let musicBrainz: MusicBrainzService?
    private let lastFM: LastFMService?
    private let storageService: StorageService

    init(
        theAudioDB: TheAudioDBService,
        musicBrainz: MusicBrainzService? = nil,
        lastFM: LastFMService? = nil,
        storageService: StorageService
    ) {
        self.theAudioDB = theAudioDB
        self.musicBrainz = musicBrainz
        self.lastFM = lastFM
        self.storageService = storageService
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
            if artistAlbums[artistKey]![track.album] == nil {
                artistAlbums[artistKey]![track.album] = []
            }
            artistAlbums[artistKey]![track.album]!.append(track)
        }

        // Build catalog structure
        var catalogArtists: [CatalogArtist] = []
        let sortedArtistKeys = artistAlbums.keys.sorted()

        for artistKey in sortedArtistKeys {
            let displayName = artistDisplayNames[artistKey] ?? artistKey
            let albums = artistAlbums[artistKey]!
            let artist = await buildArtist(name: displayName, albumsDict: albums)
            catalogArtists.append(artist)
        }

        return (catalogArtists, tracks.count)
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

        // Build albums
        var catalogAlbums: [CatalogAlbum] = []
        for albumName in albumsDict.keys.sorted() {
            let albumTracks = albumsDict[albumName]!
            let album = await buildAlbum(
                artistName: name,
                albumName: albumName,
                tracks: albumTracks,
                artistGenre: artistInfo.genre
            )
            catalogAlbums.append(album)
        }

        let artistId = Identifiers.sanitizeS3Key(name)
        let artist = CatalogArtist(
            id: artistId,
            name: name,
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
        for album in catalogAlbums {
            album.artist = artist
            if artist.albums == nil { artist.albums = [] }
            artist.albums?.append(album)
        }

        return artist
    }

    // MARK: - Build Album

    private func buildAlbum(
        artistName: String,
        albumName: String,
        tracks: [ProcessedTrack],
        artistGenre: String?
    ) async -> CatalogAlbum {
        // Sort tracks by track number
        let sortedTracks = tracks.sorted { ($0.trackNumber ?? 999) < ($1.trackNumber ?? 999) }

        // Fetch album info from TheAudioDB
        var albumInfo = await theAudioDB.fetchAlbumInfo(artist: artistName, album: albumName)
        var albumImage = albumInfo.imageUrl

        // Fallback to Last.fm if TheAudioDB doesn't have album data
        if let lastFM = lastFM, isAlbumInfoEmpty(albumInfo) {
            let lastFMInfo = await lastFM.fetchAlbumInfo(artist: artistName, album: albumName)
            albumInfo = mergeAlbumInfo(primary: albumInfo, fallback: lastFMInfo)
            if albumImage == nil && albumInfo.imageUrl != nil {
                albumImage = albumInfo.imageUrl
            }
        }

        // Fallback to embedded artwork if neither service has it
        if albumImage == nil {
            for track in sortedTracks {
                if let artworkUrl = track.embeddedArtworkUrl {
                    albumImage = artworkUrl
                    break
                }
            }
        }

        // Fetch release details from MusicBrainz
        var releaseDetails: ReleaseDetails?
        if let musicBrainz = musicBrainz {
            releaseDetails = await musicBrainz.getReleaseDetails(artist: artistName, album: albumName)
        }

        // Use corrected album name: prefer TheAudioDB, then track search, then MusicBrainz, then local
        var displayAlbumName = albumName
        if let correctedName = albumInfo.name {
            displayAlbumName = correctedName
        } else if let firstTrack = sortedTracks.first {
            // Fallback: search for album name via track lookup
            let trackInfo = await theAudioDB.fetchTrackInfo(artist: artistName, track: firstTrack.title)
            if let trackAlbum = trackInfo.album {
                displayAlbumName = trackAlbum
                // Re-fetch album info with corrected name
                let correctedAlbumInfo = await theAudioDB.fetchAlbumInfo(artist: artistName, album: trackAlbum)
                if correctedAlbumInfo.wiki != nil || correctedAlbumInfo.imageUrl != nil {
                    albumInfo = correctedAlbumInfo
                    if albumImage == nil && correctedAlbumInfo.imageUrl != nil {
                        albumImage = correctedAlbumInfo.imageUrl
                    }
                }
            }
        }

        // Final fallback: MusicBrainz title
        if displayAlbumName == albumName, let mbTitle = releaseDetails?.title {
            displayAlbumName = mbTitle
        }

        // Prefer MusicBrainz release date, fallback to TheAudioDB
        var releaseDate = albumInfo.releaseDate
        if let mbDate = releaseDetails?.releaseDate {
            releaseDate = mbDate
        }

        // Album genre: prefer album's own genre, fallback to artist genre
        let albumGenre = albumInfo.genre ?? artistGenre

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

            // Get URL for s3_key
            let url = await storageService.getPublicURL(for: s3Key)

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
                originalFormat: track.originalFormat
            )
            catalogTracks.append(catalogTrack)
        }

        let albumId = "\(Identifiers.sanitizeS3Key(artistName))/\(Identifiers.sanitizeS3Key(displayAlbumName))"
        let album = CatalogAlbum(
            id: albumId,
            name: displayAlbumName,
            imageUrl: albumImage,
            wiki: albumInfo.wiki,
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

        return album
    }

    // MARK: - Helper Methods

    private func isAlbumInfoEmpty(_ info: AlbumInfo) -> Bool {
        info.imageUrl == nil && info.wiki == nil && info.genre == nil
    }

    private func mergeAlbumInfo(primary: AlbumInfo, fallback: AlbumInfo) -> AlbumInfo {
        AlbumInfo(
            name: primary.name ?? fallback.name,
            imageUrl: primary.imageUrl ?? fallback.imageUrl,
            wiki: primary.wiki ?? fallback.wiki,
            releaseDate: primary.releaseDate ?? fallback.releaseDate,
            genre: primary.genre ?? fallback.genre,
            style: primary.style ?? fallback.style,
            mood: primary.mood ?? fallback.mood,
            theme: primary.theme ?? fallback.theme
        )
    }
}

#endif
