"""MusicBrainz service for fetching artist and release metadata."""

import logging
import threading
import time
from dataclasses import dataclass, field

import requests

from ..config import MusicBrainzConfig
from ..utils.cache import ThreadSafeCache
from ..utils.identifiers import extract_year

logger = logging.getLogger(__name__)


@dataclass
class ArtistDetails:
    """Detailed artist information from MusicBrainz."""

    mbid: str | None = None
    name: str | None = None
    artist_type: str | None = None  # person, group, orchestra, choir, etc.
    area: str | None = None  # country/region
    begin_date: str | None = None  # formation or birth date
    end_date: str | None = None  # dissolution or death date
    disambiguation: str | None = None  # clarifying text
    tags: list[str] = field(default_factory=list)


@dataclass
class ReleaseDetails:
    """Detailed release information from MusicBrainz."""

    mbid: str | None = None
    title: str | None = None
    release_date: int | None = None
    release_type: str | None = None  # album, single, EP, compilation, etc.
    country: str | None = None
    label: str | None = None
    barcode: str | None = None
    media_format: str | None = None  # CD, vinyl, digital, etc.
    tags: list[str] = field(default_factory=list)


class MusicBrainzService:
    """Service for fetching MusicBrainz IDs (MBIDs) for artists and releases.

    MBIDs can be used with the Last.fm API for more accurate lookups.
    """

    def __init__(self, config: MusicBrainzConfig) -> None:
        self._config = config
        self._last_request_time = 0.0
        self._rate_limit_lock = threading.Lock()
        self._artist_cache: ThreadSafeCache[str, str | None] = ThreadSafeCache()
        self._artist_details_cache: ThreadSafeCache[str, ArtistDetails] = ThreadSafeCache()
        self._release_cache: ThreadSafeCache[tuple[str, str], ReleaseDetails] = ThreadSafeCache()

    @property
    def enabled(self) -> bool:
        """Check if MusicBrainz lookups are enabled."""
        return self._config.enabled

    def get_artist_mbid(self, artist_name: str) -> str | None:
        """Get the MusicBrainz ID for an artist.

        Args:
            artist_name: The name of the artist to look up.

        Returns:
            The MBID string if found, None otherwise.
        """
        if not self.enabled:
            return None

        # Check cache first (empty string means "looked up but not found")
        cached = self._artist_cache.get(artist_name)
        if cached is not None:
            return cached if cached != "" else None

        mbid = self._search_artist(artist_name)
        self._artist_cache.set(artist_name, mbid or "")

        if mbid:
            logger.debug(f"Found MBID for artist '{artist_name}': {mbid}")
        else:
            logger.debug(f"No MBID found for artist '{artist_name}'")

        return mbid

    def get_artist_details(self, artist_name: str) -> ArtistDetails:
        """Get detailed MusicBrainz info for an artist.

        Args:
            artist_name: The name of the artist to look up.

        Returns:
            ArtistDetails with metadata (may have None fields if not found).
        """
        if not self.enabled:
            return ArtistDetails()

        # Check cache first
        cached = self._artist_details_cache.get(artist_name)
        if cached is not None:
            return cached

        # Get MBID first
        mbid = self.get_artist_mbid(artist_name)
        if not mbid:
            details = ArtistDetails()
            self._artist_details_cache.set(artist_name, details)
            return details

        # Fetch detailed artist info
        details = self._fetch_artist_details(mbid)
        self._artist_details_cache.set(artist_name, details)

        if details.artist_type:
            logger.debug(
                f"Got artist details for '{artist_name}': "
                f"type={details.artist_type}, area={details.area}"
            )

        return details

    def _fetch_artist_details(self, mbid: str) -> ArtistDetails:
        """Fetch detailed artist info from MusicBrainz."""
        params = {
            "inc": "tags",
            "fmt": "json",
        }

        data = self._make_request(f"artist/{mbid}", params)
        if not data:
            return ArtistDetails(mbid=mbid)

        # Extract life-span dates
        life_span = data.get("life-span", {})
        begin_date = life_span.get("begin")
        end_date = life_span.get("end")

        # Extract area
        area = None
        area_data = data.get("area", {})
        if area_data:
            area = area_data.get("name")

        # Extract tags
        tags = [tag["name"] for tag in data.get("tags", [])[:5] if tag.get("name")]

        return ArtistDetails(
            mbid=mbid,
            name=data.get("name"),
            artist_type=data.get("type"),
            area=area,
            begin_date=begin_date,
            end_date=end_date,
            disambiguation=data.get("disambiguation"),
            tags=tags,
        )

    def get_release_mbid(self, artist_name: str, album_name: str) -> str | None:
        """Get the MusicBrainz ID for a release (album).

        Args:
            artist_name: The name of the artist.
            album_name: The name of the album/release.

        Returns:
            The MBID string if found, None otherwise.
        """
        info = self.get_release_details(artist_name, album_name)
        return info.mbid if info else None

    def get_release_details(self, artist_name: str, album_name: str) -> ReleaseDetails:
        """Get detailed MusicBrainz info for a release.

        Args:
            artist_name: The name of the artist.
            album_name: The name of the album/release.

        Returns:
            ReleaseDetails with metadata (may have None fields if not found).
        """
        if not self.enabled:
            return ReleaseDetails()

        cache_key = (artist_name, album_name)

        # Check cache first
        cached = self._release_cache.get(cache_key)
        if cached is not None:
            return cached

        details = self._search_release(artist_name, album_name)
        self._release_cache.set(cache_key, details)

        if details.mbid:
            logger.debug(
                f"Found release '{album_name}' by '{artist_name}': "
                f"MBID={details.mbid}, title='{details.title}'"
            )
        else:
            logger.debug(f"No MusicBrainz match for release '{album_name}' by '{artist_name}'")

        return details

    def _search_artist(self, artist_name: str) -> str | None:
        """Search MusicBrainz for an artist and return its MBID.

        Uses multiple search strategies for robustness:
        1. Exact quoted search with escaped special characters
        2. If no results, try without escaping (for names like B.O.B)
        """
        # Strategy 1: Exact search with proper escaping
        mbid = self._do_artist_search(artist_name, escape=True)
        if mbid:
            return mbid

        # Strategy 2: Try without escaping for names with periods/special chars
        # (e.g., "B.O.B" needs to be searched as-is, not escaped)
        if any(c in artist_name for c in '.&!'):
            self._rate_limit()
            mbid = self._do_artist_search(artist_name, escape=False)
            if mbid:
                return mbid

        return None

    def _do_artist_search(self, artist_name: str, escape: bool = True) -> str | None:
        """Execute an artist search query."""
        # Escape special Lucene characters if requested
        if escape:
            safe_name = self._escape_lucene(artist_name)
        else:
            safe_name = artist_name

        query = f'artist:"{safe_name}"'
        params = {
            "query": query,
            "fmt": "json",
            "limit": "5",  # Get top 5 to find best match
        }

        data = self._make_request("artist", params)
        if not data:
            return None

        artists = data.get("artists", [])
        if artists:
            # Find best match - prefer exact name match
            for artist in artists:
                if artist.get("name", "").lower() == artist_name.lower():
                    logger.debug(f"Found exact match for '{artist_name}': {artist.get('id')}")
                    return artist.get("id")

            # If no exact match, return highest scored result
            return artists[0].get("id")

        return None

    def _search_release(self, artist_name: str, album_name: str) -> ReleaseDetails:
        """Search MusicBrainz for a release and return its details."""
        # Try exact search first
        mbid, title = self._search_release_exact(artist_name, album_name)
        if not mbid:
            # If exact search fails, try fuzzy search with cleaned album name
            cleaned_album = self._clean_album_name(album_name)
            if cleaned_album != album_name:
                self._rate_limit()
                mbid, title = self._search_release_fuzzy(artist_name, cleaned_album)

        if not mbid:
            return ReleaseDetails()

        # Fetch detailed release info
        return self._fetch_release_details(mbid, title)

    def _search_release_exact(self, artist_name: str, album_name: str) -> tuple[str | None, str | None]:
        """Search MusicBrainz for a release using exact matching."""
        self._rate_limit()

        safe_artist = self._escape_lucene(artist_name)
        safe_album = self._escape_lucene(album_name)
        query = f'release:"{safe_album}" AND artist:"{safe_artist}"'

        return self._do_release_search(query)

    def _search_release_fuzzy(self, artist_name: str, album_name: str) -> tuple[str | None, str | None]:
        """Search MusicBrainz for a release using fuzzy matching."""
        safe_artist = self._escape_lucene(artist_name)
        safe_album = self._escape_lucene(album_name)
        query = f"release:{safe_album} AND artist:{safe_artist}"

        return self._do_release_search(query)

    def _do_release_search(self, query: str) -> tuple[str | None, str | None]:
        """Execute a release search query. Returns (mbid, title)."""
        params = {
            "query": query,
            "fmt": "json",
            "limit": "1",
        }

        data = self._make_request("release", params)
        if not data:
            return None, None

        releases = data.get("releases", [])
        if releases:
            release = releases[0]
            return release.get("id"), release.get("title")

        return None, None

    def _fetch_release_details(self, mbid: str, title: str | None) -> ReleaseDetails:
        """Fetch detailed release info from MusicBrainz."""
        params = {
            "inc": "labels+media+release-groups+tags",
            "fmt": "json",
        }

        data = self._make_request(f"release/{mbid}", params)
        if not data:
            return ReleaseDetails(mbid=mbid, title=title)

        # Extract release type from release-group
        release_group = data.get("release-group", {})
        release_type = release_group.get("primary-type")

        # Extract label from label-info
        label = None
        label_info = data.get("label-info", [])
        if label_info and label_info[0].get("label"):
            label = label_info[0]["label"].get("name")

        # Extract media format
        media_format = None
        media = data.get("media", [])
        if media:
            media_format = media[0].get("format")

        # Extract tags
        tags = [tag["name"] for tag in data.get("tags", [])[:5] if tag.get("name")]

        return ReleaseDetails(
            mbid=mbid,
            title=title or data.get("title"),
            release_date=extract_year(data.get("date")),
            release_type=release_type,
            country=data.get("country"),
            label=label,
            barcode=data.get("barcode"),
            media_format=media_format,
            tags=tags,
        )

    def _clean_album_name(self, album_name: str) -> str:
        """Clean album name by removing common suffixes and extra formatting.

        Handles cases like:
        - "Album .( DeLuxe Version )" -> "Album"
        - "Album (Deluxe Edition)" -> "Album"
        - "Album [Remastered]" -> "Album"
        """
        import re

        cleaned = album_name

        # Remove content in parentheses/brackets with common keywords
        patterns = [
            r"\s*[\.\s]*\([^)]*(?:deluxe|edition|version|remaster|bonus|expanded)[^)]*\)",
            r"\s*\[[^\]]*(?:deluxe|edition|version|remaster|bonus|expanded)[^\]]*\]",
            r"\s*[\.\s]*\([^)]*\)\s*$",  # Any trailing parentheses
            r"\s*\[[^\]]*\]\s*$",  # Any trailing brackets
        ]

        for pattern in patterns:
            cleaned = re.sub(pattern, "", cleaned, flags=re.IGNORECASE)

        return cleaned.strip()

    def _rate_limit(self) -> None:
        """Enforce MusicBrainz rate limit of 1 request per second.

        Thread-safe: uses a lock to prevent multiple threads from
        bypassing the rate limit simultaneously.
        """
        with self._rate_limit_lock:
            elapsed = time.time() - self._last_request_time
            if elapsed < 1.0:
                sleep_time = 1.0 - elapsed
                logger.debug(f"Rate limiting: sleeping {sleep_time:.2f}s")
                time.sleep(sleep_time)
            self._last_request_time = time.time()

    def _make_request(
        self, endpoint: str, params: dict | None = None, max_retries: int = 3
    ) -> dict | None:
        """Make an API request to MusicBrainz with retry logic.

        Args:
            endpoint: API endpoint path (e.g., "artist/mbid" or "artist")
            params: Query parameters
            max_retries: Maximum number of retry attempts

        Returns:
            JSON response as dict, or None if all retries failed
        """
        for attempt in range(max_retries):
            self._rate_limit()
            try:
                url = f"{self._config.api_url}/{endpoint}"
                response = requests.get(
                    url,
                    params=params,
                    headers={"User-Agent": self._config.user_agent},
                    timeout=10,
                )
                response.raise_for_status()
                return response.json()
            except requests.RequestException as e:
                if attempt < max_retries - 1:
                    sleep_time = 2 ** attempt  # Exponential backoff: 1, 2, 4 seconds
                    logger.debug(
                        f"MusicBrainz request failed (attempt {attempt + 1}/{max_retries}), "
                        f"retrying in {sleep_time}s: {e}"
                    )
                    time.sleep(sleep_time)
                else:
                    logger.debug(f"MusicBrainz API request failed for {endpoint}: {e}")
        return None

    def _escape_lucene(self, text: str) -> str:
        """Escape special Lucene query characters."""
        # Characters that need escaping in Lucene queries (including < and >)
        special_chars = r'+-&|!(){}[]^"~*?:\/<>'
        escaped = []
        for char in text:
            if char in special_chars:
                escaped.append(f"\\{char}")
            else:
                escaped.append(char)
        return "".join(escaped)
