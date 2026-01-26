"""Track data models."""

from dataclasses import dataclass, field


@dataclass
class TrackMetadata:
    """Metadata extracted from an audio file using TinyTag."""

    title: str
    artist: str | None = None
    album: str | None = None
    album_artist: str | None = None
    track_number: int | None = None
    track_total: int | None = None
    disc_number: int | None = None
    disc_total: int | None = None
    duration: int | None = None  # seconds
    year: int | None = None
    genre: str | None = None
    composer: str | None = None
    comment: str | None = None
    bitrate: float | None = None  # kBits/s
    samplerate: int | None = None  # Hz
    channels: int | None = None
    filesize: int | None = None  # bytes
    format: str = ""
    original_format: str | None = None
