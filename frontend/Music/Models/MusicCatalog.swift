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
}

struct Artist: Codable, Identifiable {
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
}

struct Album: Codable, Identifiable {
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
