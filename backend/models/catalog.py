"""Catalog data models."""

from dataclasses import dataclass, field


@dataclass
class ArtistInfo:
    """Artist metadata from TheAudioDB."""

    bio: str | None = None
    image_url: str | None = None
    genre: str | None = None
    style: str | None = None
    mood: str | None = None


@dataclass
class AlbumInfo:
    """Album metadata from TheAudioDB."""

    image_url: str | None = None
    wiki: str | None = None
    release_date: int | None = None
    genre: str | None = None
    style: str | None = None
    mood: str | None = None
    theme: str | None = None
    name: str | None = None  # Corrected name from TheAudioDB


@dataclass
class TrackInfo:
    """Track metadata from TheAudioDB."""

    name: str | None = None  # Corrected track name
    album: str | None = None  # Album name from track search
    genre: str | None = None
    style: str | None = None
    mood: str | None = None
    theme: str | None = None


@dataclass
class Album:
    """Album with tracks."""

    name: str
    image_url: str | None = None
    wiki: str | None = None
    release_date: int | None = None
    genre: str | None = None
    style: str | None = None
    mood: str | None = None
    theme: str | None = None
    tracks: list[dict] = field(default_factory=list)
    # MusicBrainz fields
    release_type: str | None = None  # album, single, EP, compilation, etc.
    country: str | None = None
    label: str | None = None
    barcode: str | None = None
    media_format: str | None = None  # CD, vinyl, digital, etc.

    def to_dict(self) -> dict:
        """Convert to JSON-serializable dictionary."""
        return {
            "name": self.name,
            "image_url": self.image_url,
            "wiki": self.wiki,
            "release_date": self.release_date,
            "genre": self.genre,
            "style": self.style,
            "mood": self.mood,
            "theme": self.theme,
            "tracks": self.tracks,
            "release_type": self.release_type,
            "country": self.country,
            "label": self.label,
            "barcode": self.barcode,
            "media_format": self.media_format,
        }


@dataclass
class Artist:
    """Artist with albums."""

    name: str
    bio: str | None = None
    image_url: str | None = None
    genre: str | None = None
    style: str | None = None
    mood: str | None = None
    albums: list[Album] = field(default_factory=list)
    # MusicBrainz fields
    artist_type: str | None = None  # person, group, orchestra, choir, etc.
    area: str | None = None  # country/region
    begin_date: str | None = None  # formation or birth date
    end_date: str | None = None  # dissolution or death date
    disambiguation: str | None = None  # clarifying text

    def to_dict(self) -> dict:
        """Convert to JSON-serializable dictionary."""
        return {
            "name": self.name,
            "bio": self.bio,
            "image_url": self.image_url,
            "genre": self.genre,
            "style": self.style,
            "mood": self.mood,
            "albums": [album.to_dict() for album in self.albums],
            "artist_type": self.artist_type,
            "area": self.area,
            "begin_date": self.begin_date,
            "end_date": self.end_date,
            "disambiguation": self.disambiguation,
        }


@dataclass
class Catalog:
    """Music catalog containing all artists."""

    artists: list[Artist] = field(default_factory=list)
    total_tracks: int = 0
    generated_at: str = ""

    def to_dict(self) -> dict:
        """Convert to JSON-serializable dictionary."""
        return {
            "artists": [artist.to_dict() for artist in self.artists],
            "total_tracks": self.total_tracks,
            "generated_at": self.generated_at,
        }
