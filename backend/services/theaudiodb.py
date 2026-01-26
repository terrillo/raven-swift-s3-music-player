"""TheAudioDB API service for fetching artist and album metadata."""

from __future__ import annotations

import logging
import threading
import time
from typing import TYPE_CHECKING

import requests

from ..models.catalog import AlbumInfo, ArtistInfo, TrackInfo
from ..utils.cache import ThreadSafeCache
from ..utils.identifiers import extract_year
from .storage import StorageService

if TYPE_CHECKING:
    from .musicbrainz import MusicBrainzService

logger = logging.getLogger(__name__)

# TheAudioDB free tier API
BASE_URL = "https://www.theaudiodb.com/api/v1/json/123"

# Rate limit: 30 requests per minute (2 seconds between requests to be safe)
MIN_REQUEST_INTERVAL = 0.5  # seconds between requests


class TheAudioDBService:
    """Service for interacting with TheAudioDB API.

    Optionally uses MusicBrainz to get MBIDs for more accurate lookups.
    """

    def __init__(
        self,
        storage: StorageService,
        musicbrainz: MusicBrainzService | None = None,
    ) -> None:
        self._storage = storage
        self._musicbrainz = musicbrainz
        self._artist_cache: ThreadSafeCache[str, ArtistInfo] = ThreadSafeCache()
        self._album_cache: ThreadSafeCache[tuple[str, str], AlbumInfo] = ThreadSafeCache()
        self._track_cache: ThreadSafeCache[tuple[str, str], TrackInfo] = ThreadSafeCache()
        # Cache artist canonical name and ID for more reliable album lookups
        self._artist_id_cache: ThreadSafeCache[str, tuple[str, str]] = ThreadSafeCache()
        self._last_request_time = 0.0
        self._rate_limit_lock = threading.Lock()

    @property
    def enabled(self) -> bool:
        """TheAudioDB is always enabled (no API key required for free tier)."""
        return True

    def _rate_limit(self) -> None:
        """Enforce rate limiting between API requests.

        Thread-safe: uses a lock to prevent multiple threads from
        bypassing the rate limit simultaneously.
        """
        with self._rate_limit_lock:
            elapsed = time.time() - self._last_request_time
            if elapsed < MIN_REQUEST_INTERVAL:
                time.sleep(MIN_REQUEST_INTERVAL - elapsed)
            self._last_request_time = time.time()

    def _make_request(
        self, endpoint: str, params: dict | None = None, max_retries: int = 3
    ) -> dict | None:
        """Make an API request to TheAudioDB with retry logic.

        Args:
            endpoint: API endpoint to call
            params: Query parameters
            max_retries: Maximum number of retry attempts

        Returns:
            JSON response as dict, or None if all retries failed
        """
        for attempt in range(max_retries):
            self._rate_limit()
            try:
                url = f"{BASE_URL}/{endpoint}"
                response = requests.get(url, params=params, timeout=15)
                response.raise_for_status()
                return response.json()
            except requests.RequestException as e:
                if attempt < max_retries - 1:
                    sleep_time = 2**attempt  # Exponential backoff: 1, 2, 4 seconds
                    logger.debug(
                        f"TheAudioDB request failed (attempt {attempt + 1}/{max_retries}), "
                        f"retrying in {sleep_time}s: {e}"
                    )
                    time.sleep(sleep_time)
                else:
                    logger.debug(f"TheAudioDB API request failed for {endpoint}: {e}")
        return None

    def _get_name_variations(self, name: str) -> list[str]:
        """Generate search variations for a name to improve matching.

        Examples:
            "B.O.B" -> ["B.O.B", "BOB", "B. O. B"]
            "AC/DC" -> ["AC/DC", "ACDC", "AC DC"]
        """
        variations = [name]

        # Remove periods: "B.O.B" -> "BOB"
        no_periods = name.replace(".", "")
        if no_periods != name and no_periods.strip():
            variations.append(no_periods)

        # Replace periods with period+space: "B.O.B" -> "B. O. B"
        spaced = name.replace(".", ". ").strip()
        if spaced != name:
            variations.append(spaced)

        # Remove slashes: "AC/DC" -> "ACDC"
        no_slashes = name.replace("/", "")
        if no_slashes != name and no_slashes.strip():
            variations.append(no_slashes)

        # Replace slashes with spaces: "AC/DC" -> "AC DC"
        slash_to_space = name.replace("/", " ")
        if slash_to_space != name:
            variations.append(slash_to_space)

        return list(dict.fromkeys(variations))  # dedupe while preserving order

    def _names_match(self, search_name: str, result_name: str) -> bool:
        """Check if the result name reasonably matches the search query.

        Handles variations like:
        - "B.O.B" vs "B.o.B" (case/punctuation differences)
        - "B.O.B" vs "Bob Dylan" (completely different - should NOT match)
        """
        # Normalize both names: lowercase, remove punctuation
        def normalize(name: str) -> str:
            return "".join(c.lower() for c in name if c.isalnum())

        norm_search = normalize(search_name)
        norm_result = normalize(result_name)

        # Exact match after normalization
        if norm_search == norm_result:
            return True

        # Check if one is a substring of the other (for cases like "B.o.B" in results)
        if len(norm_search) >= 3 and len(norm_result) >= 3:
            if norm_search in norm_result or norm_result in norm_search:
                return True

        return False

    def _normalize_album_name(self, album_name: str) -> str:
        """Normalize album name by stripping edition suffixes.

        Removes common suffixes like:
        - "(Deluxe Version)", "(Deluxe Edition)", "(Deluxe)"
        - "(Special Edition)", "(Expanded Edition)"
        - "(Remastered)", "(Remaster)"
        - "- Single", "- EP"

        This helps find the canonical album name in TheAudioDB.

        Examples:
            "Hozier .( DeLuxe Version )" -> "Hozier"
            "Abbey Road (Remastered)" -> "Abbey Road"
            "Reds - Single" -> "Reds"
        """
        import re

        normalized = album_name

        # Patterns to remove (case-insensitive)
        patterns = [
            r"\s*[\.\-]?\s*\(\s*deluxe\s*(version|edition)?\s*\)",  # (Deluxe Version), (Deluxe Edition), (Deluxe)
            r"\s*[\.\-]?\s*\(\s*special\s+edition\s*\)",  # (Special Edition)
            r"\s*[\.\-]?\s*\(\s*expanded\s+edition\s*\)",  # (Expanded Edition)
            r"\s*[\.\-]?\s*\(\s*remaster(ed)?\s*\)",  # (Remastered), (Remaster)
            r"\s*[\.\-]?\s*\(\s*bonus\s+track(s)?\s*\)",  # (Bonus Tracks)
            r"\s*-\s*single\s*$",  # - Single
            r"\s*-\s*ep\s*$",  # - EP
        ]

        for pattern in patterns:
            normalized = re.sub(pattern, "", normalized, flags=re.IGNORECASE)

        # Clean up any leftover whitespace
        normalized = normalized.strip()

        return normalized if normalized else album_name

    def fetch_artist_info(self, artist_name: str) -> ArtistInfo:
        """Fetch artist bio, image, and metadata from TheAudioDB.

        Uses direct name search (not MBID) as MusicBrainz often returns wrong artists.
        Results are cached for subsequent calls.
        """
        cached = self._artist_cache.get(artist_name)
        if cached is not None:
            return cached

        result = ArtistInfo()

        try:
            artist_data = None

            # Use name search with variations for better matching
            # (Skip MBID lookup - MusicBrainz often returns wrong artist for names like "B.O.B")
            for variation in self._get_name_variations(artist_name):
                data = self._make_request("search.php", {"s": variation})
                if data and data.get("artists"):
                    artist_data = data["artists"][0]
                    logger.debug(f"Found artist '{artist_name}' using variation '{variation}'")
                    break

            if artist_data:
                # Cache canonical name and ID for album lookups
                canonical_name = artist_data.get("strArtist", artist_name)
                artist_id = artist_data.get("idArtist")
                if artist_id:
                    self._artist_id_cache.set(artist_name, (canonical_name, artist_id))
                # Extract bio (prefer English)
                bio = artist_data.get("strBiographyEN")
                if bio:
                    result.bio = bio.strip()

                # Extract metadata fields
                result.genre = artist_data.get("strGenre")
                result.style = artist_data.get("strStyle")
                result.mood = artist_data.get("strMood")

                # Upload artist image to Spaces
                image_url = (
                    artist_data.get("strArtistThumb")
                    or artist_data.get("strArtistFanart")
                    or artist_data.get("strArtistFanart2")
                )
                if image_url:
                    uploaded_url = self._storage.download_and_upload_artist_image(
                        image_url, artist_name
                    )
                    if uploaded_url:
                        result.image_url = uploaded_url

        except Exception as e:
            logger.warning(f"Could not fetch artist info for {artist_name}: {e}")

        self._artist_cache.set(artist_name, result)
        return result

    def fetch_album_info(self, artist_name: str, album_name: str) -> AlbumInfo:
        """Fetch album image, description, and metadata from TheAudioDB.

        If MusicBrainz service is available, uses MBID for more accurate lookup.
        Uses cached canonical artist name for more reliable searches.
        Results are cached for subsequent calls.
        """
        cache_key = (artist_name, album_name)
        cached = self._album_cache.get(cache_key)
        if cached is not None:
            return cached

        result = AlbumInfo()

        # Get canonical artist info from cache (set by fetch_artist_info)
        cached_artist = self._artist_id_cache.get(artist_name)
        canonical_name = cached_artist[0] if cached_artist else artist_name
        artist_id = cached_artist[1] if cached_artist else None

        try:
            album_data = None

            # Try MBID lookup first if MusicBrainz is available
            # Store MusicBrainz title to use only if we find album data
            musicbrainz_title = None
            if self._musicbrainz:
                release_details = self._musicbrainz.get_release_details(artist_name, album_name)
                if release_details and release_details.mbid:
                    logger.debug(
                        f"Using MBID {release_details.mbid} for album '{album_name}' by '{artist_name}'"
                    )
                    data = self._make_request("album-mb.php", {"i": release_details.mbid})
                    if data and data.get("album"):
                        album_data = data["album"][0] if isinstance(data["album"], list) else data["album"]
                    # Store MusicBrainz canonical title for later use
                    if release_details.title:
                        musicbrainz_title = release_details.title

            # Try name search with normalized album name first (strips Deluxe/Special Edition suffixes)
            # This ensures we get TheAudioDB's canonical album name, not local variations
            normalized_album = self._normalize_album_name(album_name)
            if not album_data and normalized_album != album_name:
                data = self._make_request("searchalbum.php", {"s": canonical_name, "a": normalized_album})
                if data and data.get("album"):
                    album_data = data["album"][0]
                    logger.debug(f"Found album '{normalized_album}' (normalized from '{album_name}') using canonical artist '{canonical_name}'")

            # Try name search with original album name
            if not album_data:
                data = self._make_request("searchalbum.php", {"s": canonical_name, "a": album_name})
                if data and data.get("album"):
                    album_data = data["album"][0]
                    logger.debug(f"Found album '{album_name}' using canonical name '{canonical_name}'")

            # Fallback: get all artist albums by ID and match by name
            if not album_data and artist_id:
                data = self._make_request("album.php", {"i": artist_id})
                if data and data.get("album"):
                    album_name_lower = album_name.lower()
                    for album in data["album"]:
                        if album.get("strAlbum", "").lower() == album_name_lower:
                            album_data = album
                            logger.debug(f"Found album '{album_name}' via artist ID lookup")
                            break

            if album_data:
                # Get corrected album name: prefer TheAudioDB, then MusicBrainz
                result.name = album_data.get("strAlbum") or musicbrainz_title

                # Extract description/wiki (prefer English, fallback to base description)
                # TheAudioDB API uses strDescriptionEN for some albums, strDescription for others
                wiki = album_data.get("strDescriptionEN") or album_data.get("strDescription")
                if wiki:
                    result.wiki = wiki.strip()

                # Extract release year as integer
                year = album_data.get("intYearReleased")
                if year:
                    result.release_date = extract_year(year)

                # Extract metadata fields
                result.genre = album_data.get("strGenre")
                result.style = album_data.get("strStyle")
                result.mood = album_data.get("strMood")
                result.theme = album_data.get("strTheme")

                # Upload album artwork to Spaces (use corrected album name for S3 key)
                image_url = (
                    album_data.get("strAlbumThumb")
                    or album_data.get("strAlbumThumbHQ")
                )
                if image_url:
                    # Use corrected album name from TheAudioDB, fallback to original
                    s3_album_name = result.name or album_name
                    uploaded_url = self._storage.download_and_upload_image(
                        image_url, artist_name, s3_album_name
                    )
                    if uploaded_url:
                        result.image_url = uploaded_url

        except Exception as e:
            logger.warning(f"Could not fetch album info for {album_name}: {e}")

        self._album_cache.set(cache_key, result)
        return result

    def fetch_track_info(self, artist_name: str, track_title: str) -> TrackInfo:
        """Fetch track metadata from TheAudioDB.

        Returns TrackInfo with corrected name and metadata fields.
        Results are cached by (artist, track) tuple.
        """
        cache_key = (artist_name, track_title)
        cached = self._track_cache.get(cache_key)
        if cached is not None:
            return cached

        result = TrackInfo()

        try:
            data = self._make_request("searchtrack.php", {"s": artist_name, "t": track_title})
            if data and data.get("track"):
                track_data = data["track"][0]

                # Get corrected track name
                result.name = track_data.get("strTrack")

                # Get album name from track data
                result.album = track_data.get("strAlbum")

                # Extract metadata fields
                result.genre = track_data.get("strGenre")
                result.style = track_data.get("strStyle")
                result.mood = track_data.get("strMood")
                result.theme = track_data.get("strTheme")

        except Exception as e:
            logger.warning(
                f"Could not fetch track info for {track_title} by {artist_name}: {e}"
            )

        self._track_cache.set(cache_key, result)
        return result
