//
//  MusicCatalog.swift
//  Music
//

import Foundation

struct MusicCatalog: Codable {
    let artists: [Artist]
    let totalTracks: Int
    let generatedAt: String

    enum CodingKeys: String, CodingKey {
        case artists
        case totalTracks = "total_tracks"
        case generatedAt = "generated_at"
    }

    init(artists: [Artist], totalTracks: Int, generatedAt: String) {
        self.artists = artists
        self.totalTracks = totalTracks
        self.generatedAt = generatedAt
    }
}

struct Artist: Codable, Identifiable, Hashable {
    static func == (lhs: Artist, rhs: Artist) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // Use s3Key prefix from first track for unique ID (falls back to name)
    var id: String {
        albums.first?.tracks.first?.s3Key.components(separatedBy: "/").first ?? name
    }
    let name: String
    let imageUrl: String?
    let bio: String?
    let genre: String?
    let style: String?
    let mood: String?
    let albums: [Album]
    let artistType: String?
    let area: String?
    let beginDate: String?
    let endDate: String?
    let disambiguation: String?

    enum CodingKeys: String, CodingKey {
        case name, albums, bio, genre, style, mood, area, disambiguation
        case imageUrl = "image_url"
        case artistType = "artist_type"
        case beginDate = "begin_date"
        case endDate = "end_date"
    }

    init(
        name: String,
        imageUrl: String? = nil,
        bio: String? = nil,
        genre: String? = nil,
        style: String? = nil,
        mood: String? = nil,
        albums: [Album] = [],
        artistType: String? = nil,
        area: String? = nil,
        beginDate: String? = nil,
        endDate: String? = nil,
        disambiguation: String? = nil
    ) {
        self.name = name
        self.imageUrl = imageUrl
        self.bio = bio
        self.genre = genre
        self.style = style
        self.mood = mood
        self.albums = albums
        self.artistType = artistType
        self.area = area
        self.beginDate = beginDate
        self.endDate = endDate
        self.disambiguation = disambiguation
    }
}

struct Album: Codable, Identifiable, Hashable {
    static func == (lhs: Album, rhs: Album) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // Use first two path components from s3Key for unique ID (Artist/Album)
    var id: String {
        guard let s3Key = tracks.first?.s3Key else { return name }
        let components = s3Key.components(separatedBy: "/")
        return components.prefix(2).joined(separator: "/")
    }
    let name: String
    let imageUrl: String?
    let wiki: String?
    let releaseDate: Int?
    let genre: String?
    let style: String?
    let mood: String?
    let theme: String?
    let tracks: [Track]
    let releaseType: String?
    let country: String?
    let label: String?
    let barcode: String?
    let mediaFormat: String?

    enum CodingKeys: String, CodingKey {
        case name, tracks, wiki, genre, style, mood, theme, country, label, barcode
        case imageUrl = "image_url"
        case releaseDate = "release_date"
        case releaseType = "release_type"
        case mediaFormat = "media_format"
    }

    init(
        name: String,
        imageUrl: String? = nil,
        wiki: String? = nil,
        releaseDate: Int? = nil,
        genre: String? = nil,
        style: String? = nil,
        mood: String? = nil,
        theme: String? = nil,
        tracks: [Track] = [],
        releaseType: String? = nil,
        country: String? = nil,
        label: String? = nil,
        barcode: String? = nil,
        mediaFormat: String? = nil
    ) {
        self.name = name
        self.imageUrl = imageUrl
        self.wiki = wiki
        self.releaseDate = releaseDate
        self.genre = genre
        self.style = style
        self.mood = mood
        self.theme = theme
        self.tracks = tracks
        self.releaseType = releaseType
        self.country = country
        self.label = label
        self.barcode = barcode
        self.mediaFormat = mediaFormat
    }
}

struct Track: Codable, Identifiable {
    var id: String { s3Key }
    let title: String
    let artist: String?
    let album: String?
    let trackNumber: Int?
    let duration: Int?
    let format: String
    let s3Key: String
    let url: String?
    let embeddedArtworkUrl: String?
    let genre: String?
    let style: String?
    let mood: String?
    let theme: String?
    let albumArtist: String?
    let trackTotal: Int?
    let discNumber: Int?
    let discTotal: Int?
    let year: Int?
    let composer: String?
    let comment: String?
    let bitrate: Double?
    let samplerate: Int?
    let channels: Int?
    let filesize: Int?
    let originalFormat: String?

    enum CodingKeys: String, CodingKey {
        case title, artist, album, duration, format, url, genre, style, mood, theme
        case year, composer, comment, bitrate, samplerate, channels, filesize
        case trackNumber = "track_number"
        case s3Key = "s3_key"
        case embeddedArtworkUrl = "embedded_artwork_url"
        case albumArtist = "album_artist"
        case trackTotal = "track_total"
        case discNumber = "disc_number"
        case discTotal = "disc_total"
        case originalFormat = "original_format"
    }

    init(
        title: String,
        artist: String? = nil,
        album: String? = nil,
        trackNumber: Int? = nil,
        duration: Int? = nil,
        format: String,
        s3Key: String,
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
        self.title = title
        self.artist = artist
        self.album = album
        self.trackNumber = trackNumber
        self.duration = duration
        self.format = format
        self.s3Key = s3Key
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
    }

    var formattedDuration: String {
        guard let duration = duration else { return "--:--" }
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Genre Normalization

struct Genre {
    /// Mapping of raw genre strings to canonical names
    private static let normalizationMap: [String: String] = [
        // Hip-Hop variants (keep separate from Rap)
        "hip hop": "Hip-Hop",
        "hip-hop": "Hip-Hop",
        "hip-hop / rap": "Hip-Hop",
        "hip-hop/rap": "Hip-Hop",
        "hip-hop/\nrap": "Hip-Hop",
        "[hip-hop/rap": "Hip-Hop",
        "hip hop/rap": "Hip-Hop",
        "hip hop rap": "Hip-Hop",
        "alternative hip-hop/rap": "Hip-Hop",
        "dancehall / hip-hop": "Hip-Hop",
        "grime": "Hip-Hop",
        "trap": "Hip-Hop",

        // Rap variants (kept separate from Hip-Hop)
        "rap": "Rap",
        "rap & hip hop": "Rap",
        "rap & hip-hop": "Rap",
        "rap - hip hop": "Rap",
        "rap/hip hop": "Rap",
        "rap/hip-hop": "Rap",

        // R&B variants (kept separate from Soul)
        "r&b": "R&B",
        "r&b/soul": "R&B",
        "contemporary r&b": "R&B",

        // Soul variants (kept separate from R&B)
        "soul": "Soul",
        "soul / funk / r&b": "Soul",
        "soul and r&b": "Soul",
        "soul | r&b": "Soul",
        "soul, funk, r&b": "Soul",
        "funk / soul": "Soul",
        "funk": "Funk",

        // Rock variants
        "rock": "Rock",
        "alternative rock": "Alternative Rock",
        "alternative-rock": "Alternative Rock",
        "pop rock": "Pop Rock",
        "pop-rock": "Pop Rock",
        "pop/rock": "Pop Rock",
        "pop, rock": "Pop Rock",
        "indie rock": "Indie Rock",
        "hard rock": "Hard Rock",
        "punk rock": "Punk Rock",
        "pop-punk": "Pop Punk",
        "progressive rock": "Progressive Rock",
        "psychedelic rock": "Psychedelic Rock",
        " psychedelic rock": "Psychedelic Rock",

        // Metal variants
        "metal": "Metal",
        "alternative-metal": "Metal",
        "nu metal": "Metal",

        // Electronic variants
        "electronic": "Electronic",
        "electronic, dance": "Electronic",
        "electronic, trance": "Electronic",
        "electro": "Electronic",
        "electro house": "Electronic",
        "électronique": "Electronic",
        "électronique, dance": "Electronic",
        "dance": "Dance",
        "dance & dj": "Dance",
        "house": "House",
        "techno": "Techno",
        "trance": "Trance",
        "drum & bass": "Drum & Bass",
        "synthpop": "Synthpop",
        "ambient": "Ambient",
        "downtempo": "Downtempo",

        // Pop variants
        "pop": "Pop",
        "french pop": "Pop",
        "indie pop": "Indie Pop",
        "k-pop": "K-Pop",
        "pop, rock, alternative & indie": "Alternative",
        "pop, rock, alternatif et indé": "Alternative",
        "musica alternativa e indie": "Alternative",

        // Other normalizations
        "singer & songwriter": "Singer-Songwriter",
        "singer songwriter": "Singer-Songwriter",
        "singer-songwriter": "Singer-Songwriter",
        "singer/songwriter": "Singer-Songwriter",
        "pop / singer & songwriter": "Singer-Songwriter",
        "soundtrack": "Soundtrack",
        "soundtracks": "Soundtrack",
        "film": "Soundtrack",
        "film, bandes originales de films": "Soundtrack",
        "films/games": "Soundtrack",
        "films/games; film scores": "Soundtrack",
        "jazz": "Jazz",
        "jazz, jazz contemporain": "Jazz",
        "jazz, jazz fusion & jazz rock": "Jazz",
        "jazz, jazz vocal": "Jazz",
        "acid jazz": "Jazz",
        "blues": "Blues",
        "blues, country, folk": "Blues",
        "country": "Country",
        "country pop": "Country",
        "alternative country": "Country",
        "folk": "Folk",
        "reggae": "Reggae",
        "reggae fusion": "Reggae",
        "latin": "Latin",
        "gospel": "Gospel",
        "contemporary christian": "Gospel",
        "christmas": "Holiday",
        "holiday": "Holiday",
        "ambiance, musiques de noël": "Holiday",
        "enfants": "Kids",
        "spoken word": "Spoken Word",
        "accapella": "A Cappella",
        "asian music": "World",
        "african music": "World",
        "musiques du monde": "World",
        "worldwide": "World",
        "mash-up": "Remix",
        "misc": "Other",
        "miscellaneous": "Other",
        "other": "Other",
    ]

    /// Normalize a genre string to its canonical form
    static func normalize(_ genre: String?) -> String? {
        guard let genre = genre, !genre.isEmpty else { return nil }
        let lowercased = genre.lowercased().trimmingCharacters(in: .whitespaces)
        return normalizationMap[lowercased] ?? genre
    }
}
