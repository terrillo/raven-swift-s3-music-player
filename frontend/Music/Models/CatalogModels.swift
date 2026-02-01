//
//  CatalogModels.swift
//  Music
//
//  SwiftData models for music catalog with CloudKit sync.
//  These models replace the remote JSON catalog.
//

import Foundation
import SwiftData

// MARK: - CatalogArtist

@Model
final class CatalogArtist {
    @Attribute(.unique) var id: String  // sanitized artist name
    var name: String
    var bio: String?
    var imageUrl: String?
    var genre: String?
    var style: String?
    var mood: String?
    var artistType: String?
    var area: String?
    var beginDate: String?
    var endDate: String?
    var disambiguation: String?
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \CatalogAlbum.artist)
    var albums: [CatalogAlbum]

    init(
        id: String,
        name: String,
        bio: String? = nil,
        imageUrl: String? = nil,
        genre: String? = nil,
        style: String? = nil,
        mood: String? = nil,
        artistType: String? = nil,
        area: String? = nil,
        beginDate: String? = nil,
        endDate: String? = nil,
        disambiguation: String? = nil
    ) {
        self.id = id
        self.name = name
        self.bio = bio
        self.imageUrl = imageUrl
        self.genre = genre
        self.style = style
        self.mood = mood
        self.artistType = artistType
        self.area = area
        self.beginDate = beginDate
        self.endDate = endDate
        self.disambiguation = disambiguation
        self.updatedAt = Date()
        self.albums = []
    }

    /// Convert to Codable Artist model for compatibility
    func toArtist() -> Artist {
        Artist(
            name: name,
            imageUrl: imageUrl,
            bio: bio,
            genre: genre,
            style: style,
            mood: mood,
            albums: albums.sorted { ($0.name) < ($1.name) }.map { $0.toAlbum() },
            artistType: artistType,
            area: area,
            beginDate: beginDate,
            endDate: endDate,
            disambiguation: disambiguation
        )
    }
}

// MARK: - CatalogAlbum

@Model
final class CatalogAlbum {
    @Attribute(.unique) var id: String  // "Artist/Album" pattern
    var name: String
    var imageUrl: String?
    var wiki: String?
    var releaseDate: Int?
    var genre: String?
    var style: String?
    var mood: String?
    var theme: String?
    var releaseType: String?
    var country: String?
    var label: String?
    var barcode: String?
    var mediaFormat: String?
    var updatedAt: Date

    var artist: CatalogArtist?

    @Relationship(deleteRule: .cascade, inverse: \CatalogTrack.catalogAlbum)
    var tracks: [CatalogTrack]

    init(
        id: String,
        name: String,
        imageUrl: String? = nil,
        wiki: String? = nil,
        releaseDate: Int? = nil,
        genre: String? = nil,
        style: String? = nil,
        mood: String? = nil,
        theme: String? = nil,
        releaseType: String? = nil,
        country: String? = nil,
        label: String? = nil,
        barcode: String? = nil,
        mediaFormat: String? = nil
    ) {
        self.id = id
        self.name = name
        self.imageUrl = imageUrl
        self.wiki = wiki
        self.releaseDate = releaseDate
        self.genre = genre
        self.style = style
        self.mood = mood
        self.theme = theme
        self.releaseType = releaseType
        self.country = country
        self.label = label
        self.barcode = barcode
        self.mediaFormat = mediaFormat
        self.updatedAt = Date()
        self.tracks = []
    }

    /// Convert to Codable Album model for compatibility
    func toAlbum() -> Album {
        Album(
            name: name,
            imageUrl: imageUrl,
            wiki: wiki,
            releaseDate: releaseDate,
            genre: genre,
            style: style,
            mood: mood,
            theme: theme,
            tracks: tracks.sorted { ($0.trackNumber ?? 999) < ($1.trackNumber ?? 999) }.map { $0.toTrack() },
            releaseType: releaseType,
            country: country,
            label: label,
            barcode: barcode,
            mediaFormat: mediaFormat
        )
    }
}

// MARK: - CatalogTrack

@Model
final class CatalogTrack {
    @Attribute(.unique) var s3Key: String  // Primary key
    var title: String
    var artistName: String?
    var albumName: String?
    var trackNumber: Int?
    var duration: Int?
    var format: String
    var url: String?
    var embeddedArtworkUrl: String?
    var genre: String?
    var style: String?
    var mood: String?
    var theme: String?
    var albumArtist: String?
    var trackTotal: Int?
    var discNumber: Int?
    var discTotal: Int?
    var year: Int?
    var composer: String?
    var comment: String?
    var bitrate: Double?
    var samplerate: Int?
    var channels: Int?
    var filesize: Int?
    var originalFormat: String?
    var updatedAt: Date

    var catalogAlbum: CatalogAlbum?

    init(
        s3Key: String,
        title: String,
        artistName: String? = nil,
        albumName: String? = nil,
        trackNumber: Int? = nil,
        duration: Int? = nil,
        format: String,
        url: String? = nil,
        embeddedArtworkUrl: String? = nil,
        genre: String? = nil,
        style: String? = nil,
        mood: String? = nil,
        theme: String? = nil,
        albumArtist: String? = nil,
        trackTotal: Int? = nil,
        discNumber: Int? = nil,
        discTotal: Int? = nil,
        year: Int? = nil,
        composer: String? = nil,
        comment: String? = nil,
        bitrate: Double? = nil,
        samplerate: Int? = nil,
        channels: Int? = nil,
        filesize: Int? = nil,
        originalFormat: String? = nil
    ) {
        self.s3Key = s3Key
        self.title = title
        self.artistName = artistName
        self.albumName = albumName
        self.trackNumber = trackNumber
        self.duration = duration
        self.format = format
        self.url = url
        self.embeddedArtworkUrl = embeddedArtworkUrl
        self.genre = genre
        self.style = style
        self.mood = mood
        self.theme = theme
        self.albumArtist = albumArtist
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.year = year
        self.composer = composer
        self.comment = comment
        self.bitrate = bitrate
        self.samplerate = samplerate
        self.channels = channels
        self.filesize = filesize
        self.originalFormat = originalFormat
        self.updatedAt = Date()
    }

    /// Convert to Codable Track model for compatibility
    func toTrack() -> Track {
        Track(
            title: title,
            artist: artistName,
            album: albumName,
            trackNumber: trackNumber,
            duration: duration,
            format: format,
            s3Key: s3Key,
            url: url,
            embeddedArtworkUrl: embeddedArtworkUrl,
            genre: genre,
            style: style,
            mood: mood,
            theme: theme,
            albumArtist: albumArtist,
            trackTotal: trackTotal,
            discNumber: discNumber,
            discTotal: discTotal,
            year: year,
            composer: composer,
            comment: comment,
            bitrate: bitrate,
            samplerate: samplerate,
            channels: channels,
            filesize: filesize,
            originalFormat: originalFormat
        )
    }
}

// MARK: - CatalogMetadata

/// Metadata about the catalog itself (total tracks, generation time)
@Model
final class CatalogMetadata {
    @Attribute(.unique) var id: String
    var totalTracks: Int
    var generatedAt: Date
    var updatedAt: Date

    init(id: String = "main", totalTracks: Int = 0) {
        self.id = id
        self.totalTracks = totalTracks
        self.generatedAt = Date()
        self.updatedAt = Date()
    }
}
