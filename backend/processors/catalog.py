"""Catalog building logic."""

from __future__ import annotations

import logging
from collections import defaultdict
from datetime import datetime, timezone
from typing import TYPE_CHECKING

from tqdm import tqdm

from ..models.catalog import Album, AlbumInfo, Artist, Catalog
from ..services.theaudiodb import TheAudioDBService
from ..utils.identifiers import sanitize_s3_key

if TYPE_CHECKING:
    from ..services.lastfm import LastFMService
    from ..services.musicbrainz import MusicBrainzService
    from ..services.storage import StorageService

logger = logging.getLogger(__name__)


class CatalogBuilder:
    """Builds the hierarchical music catalog."""

    def __init__(
        self,
        theaudiodb_service: TheAudioDBService,
        musicbrainz_service: MusicBrainzService | None = None,
        storage_service: StorageService | None = None,
        lastfm_service: LastFMService | None = None,
    ) -> None:
        self._theaudiodb = theaudiodb_service
        self._musicbrainz = musicbrainz_service
        self._storage = storage_service
        self._lastfm = lastfm_service

    def build(self, tracks: list[dict]) -> Catalog:
        """Organize tracks into a structured catalog by album_artist and album."""
        # Group tracks by album_artist -> album (album_artist is used for organization)
        artist_albums = defaultdict(lambda: defaultdict(list))

        for track in tracks:
            # Use album_artist for grouping (fallback to artist)
            album_artist = track.get("album_artist") or track.get("artist") or "Unknown Artist"
            album = track.get("album") or "Unknown Album"
            artist_albums[album_artist][album].append(track)

        # Build the catalog structure with images and metadata from TheAudioDB
        artists = []
        artist_names = sorted(artist_albums.keys())

        logger.info("Fetching metadata from TheAudioDB and uploading to Spaces...")

        for artist_name in tqdm(artist_names, desc="Fetching metadata", unit="artist"):
            artist = self._build_artist(artist_name, artist_albums[artist_name])
            artists.append(artist)

        return Catalog(
            artists=artists,
            total_tracks=len(tracks),
            generated_at=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        )

    def _build_artist(self, name: str, albums_dict: dict) -> Artist:
        """Build an artist entry with metadata from MusicBrainz and TheAudioDB."""
        # Fetch artist bio, image, and metadata from TheAudioDB
        artist_info = self._theaudiodb.fetch_artist_info(name)

        # Fetch detailed artist info from MusicBrainz
        artist_details = None
        if self._musicbrainz:
            artist_details = self._musicbrainz.get_artist_details(name)

        albums = []
        for album_name in sorted(albums_dict.keys()):
            album_tracks = albums_dict[album_name]
            album = self._build_album(name, album_name, album_tracks, artist_info.genre)
            albums.append(album)

        return Artist(
            name=name,
            bio=artist_info.bio,
            image_url=artist_info.image_url,
            genre=artist_info.genre,
            style=artist_info.style,
            mood=artist_info.mood,
            albums=albums,
            artist_type=artist_details.artist_type if artist_details else None,
            area=artist_details.area if artist_details else None,
            begin_date=artist_details.begin_date if artist_details else None,
            end_date=artist_details.end_date if artist_details else None,
            disambiguation=artist_details.disambiguation if artist_details else None,
        )

    def _build_album(
        self,
        artist_name: str,
        album_name: str,
        tracks: list[dict],
        artist_genre: str | None = None,
    ) -> Album:
        """Build an album entry with metadata from MusicBrainz and TheAudioDB."""
        # Sort tracks by track number
        tracks.sort(key=lambda t: (t.get("track_number") or 999, t.get("title", "")))

        # Fetch album info from TheAudioDB (image, wiki, metadata, corrected name)
        album_info = self._theaudiodb.fetch_album_info(artist_name, album_name)
        album_image = album_info.image_url

        # Fallback to Last.fm if TheAudioDB doesn't have album data
        if self._lastfm and self._is_album_info_empty(album_info):
            lastfm_info = self._lastfm.fetch_album_info(artist_name, album_name)
            album_info = self._merge_album_info(album_info, lastfm_info)
            if not album_image and album_info.image_url:
                album_image = album_info.image_url
                logger.debug(f"Using Last.fm fallback for album '{album_name}' by '{artist_name}'")

        # Fallback to embedded artwork if neither service has it
        if not album_image:
            for track in tracks:
                if track.get("embedded_artwork_url"):
                    album_image = track["embedded_artwork_url"]
                    break

        # Fetch release details from MusicBrainz
        release_details = None
        if self._musicbrainz:
            release_details = self._musicbrainz.get_release_details(artist_name, album_name)

        # Use corrected album name: prefer TheAudioDB album, then track search, then MusicBrainz, then local
        display_album_name = album_name
        if album_info.name:
            display_album_name = album_info.name
        else:
            # Fallback: search for album name via track lookup
            if tracks:
                first_track_title = tracks[0].get("title", "")
                if first_track_title:
                    track_info = self._theaudiodb.fetch_track_info(artist_name, first_track_title)
                    if track_info.album:
                        display_album_name = track_info.album
                        logger.debug(
                            f"Found album name '{track_info.album}' via track search for '{first_track_title}'"
                        )
                        # Re-fetch album info with corrected name to get wiki/description
                        corrected_album_info = self._theaudiodb.fetch_album_info(
                            artist_name, track_info.album
                        )
                        if corrected_album_info.wiki or corrected_album_info.image_url:
                            album_info = corrected_album_info
                            if not album_image and corrected_album_info.image_url:
                                album_image = corrected_album_info.image_url
            # Final fallback: MusicBrainz
            if display_album_name == album_name and release_details and release_details.title:
                display_album_name = release_details.title

        # Prefer MusicBrainz release date, fallback to TheAudioDB
        release_date = album_info.release_date
        if release_details and release_details.release_date:
            release_date = release_details.release_date

        # Album genre: prefer album's own genre, fallback to artist genre
        album_genre = album_info.genre or artist_genre

        # Enrich tracks with album-level metadata
        # Note: We intentionally skip per-track API calls to TheAudioDB to avoid N+1 performance issues.
        # Track-level metadata (genre, style, mood, theme) is typically identical to album-level metadata.
        enriched_tracks = []
        for track in tracks:
            enriched = dict(track)
            # Use corrected album name
            enriched["album"] = display_album_name
            # Update s3_key to use corrected album name (not local folder name)
            if display_album_name != album_name and enriched.get("s3_key"):
                old_s3_key = enriched["s3_key"]
                # Replace the album portion of the s3_key with the corrected name
                album_artist_key = sanitize_s3_key(artist_name)
                corrected_album_key = sanitize_s3_key(display_album_name)
                # Extract filename from old s3_key
                parts = old_s3_key.split("/")
                if len(parts) >= 3:
                    filename = parts[-1]
                    new_s3_key = f"{album_artist_key}/{corrected_album_key}/{filename}"
                    enriched["s3_key"] = new_s3_key
                    # Update URL if storage service is available
                    if self._storage:
                        enriched["url"] = self._storage.get_public_url(new_s3_key)
            # Add album-level metadata to tracks (avoids N+1 API calls)
            enriched["genre"] = enriched.get("genre") or album_genre
            enriched["style"] = enriched.get("style") or album_info.style
            enriched["mood"] = enriched.get("mood") or album_info.mood
            enriched["theme"] = enriched.get("theme") or album_info.theme
            # Add album image URL for tracks without embedded artwork
            enriched["album_image_url"] = album_image
            # Fallback: use album image for tracks without embedded artwork
            if not enriched.get("embedded_artwork_url") and album_image:
                enriched["embedded_artwork_url"] = album_image
            enriched_tracks.append(enriched)

        # Deduplicate tracks by s3_key (keep first occurrence)
        # This handles cases where duplicate folders exist (e.g., "Album" and "Album copy")
        # that get merged after TheAudioDB name correction
        seen_keys = set()
        unique_tracks = []
        for track in enriched_tracks:
            s3_key = track.get("s3_key")
            if s3_key and s3_key not in seen_keys:
                seen_keys.add(s3_key)
                unique_tracks.append(track)
            elif not s3_key:
                unique_tracks.append(track)  # Keep tracks without s3_key
        enriched_tracks = unique_tracks

        return Album(
            name=display_album_name,
            image_url=album_image,
            wiki=album_info.wiki,
            release_date=release_date,
            genre=album_genre,
            style=album_info.style,
            mood=album_info.mood,
            theme=album_info.theme,
            tracks=enriched_tracks,
            release_type=release_details.release_type if release_details else None,
            country=release_details.country if release_details else None,
            label=release_details.label if release_details else None,
            barcode=release_details.barcode if release_details else None,
            media_format=release_details.media_format if release_details else None,
        )

    def _is_album_info_empty(self, info: AlbumInfo) -> bool:
        """Check if album info is essentially empty (no useful data from TheAudioDB)."""
        return not any([
            info.image_url,
            info.wiki,
            info.genre,
        ])

    def _merge_album_info(self, primary: AlbumInfo, fallback: AlbumInfo) -> AlbumInfo:
        """Merge fallback album info into primary, filling in gaps only."""
        return AlbumInfo(
            image_url=primary.image_url or fallback.image_url,
            wiki=primary.wiki or fallback.wiki,
            release_date=primary.release_date or fallback.release_date,
            genre=primary.genre or fallback.genre,
            style=primary.style or fallback.style,
            mood=primary.mood or fallback.mood,
            theme=primary.theme or fallback.theme,
            name=primary.name or fallback.name,
        )
