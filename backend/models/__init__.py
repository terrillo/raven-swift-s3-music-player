"""Data models for tracks and catalog."""

from .track import TrackMetadata
from .catalog import ArtistInfo, AlbumInfo, Album, Artist, Catalog

__all__ = [
    "TrackMetadata",
    "ArtistInfo",
    "AlbumInfo",
    "Album",
    "Artist",
    "Catalog",
]
