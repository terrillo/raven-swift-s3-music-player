"""Last.fm API service for fetching album metadata as a fallback."""

from __future__ import annotations

import logging
import re
import threading
import time
from typing import TYPE_CHECKING

import requests

from ..models.catalog import AlbumInfo
from ..utils.cache import ThreadSafeCache

if TYPE_CHECKING:
    from .storage import StorageService

logger = logging.getLogger(__name__)

# Last.fm API base URL
BASE_URL = "https://ws.audioscrobbler.com/2.0/"

# Rate limit: Last.fm allows 5 requests per second for authenticated requests
# Use 250ms between requests (4 req/sec) to be safe
MIN_REQUEST_INTERVAL = 0.25


class LastFMService:
    """Service for interacting with Last.fm API.

    Used as a fallback when TheAudioDB doesn't have album data.
    Requires LASTFM_API_KEY environment variable.
    """

    def __init__(
        self,
        api_key: str,
        storage: StorageService | None = None,
    ) -> None:
        self._api_key = api_key
        self._storage = storage
        self._album_cache: ThreadSafeCache[tuple[str, str], AlbumInfo] = ThreadSafeCache()
        self._last_request_time = 0.0
        self._rate_limit_lock = threading.Lock()

    @property
    def enabled(self) -> bool:
        """Check if Last.fm lookups are enabled (API key is set)."""
        return bool(self._api_key)

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
        self, method: str, params: dict, max_retries: int = 3
    ) -> dict | None:
        """Make an API request to Last.fm with retry logic.

        Args:
            method: Last.fm API method (e.g., 'album.getinfo')
            params: Additional query parameters
            max_retries: Maximum number of retry attempts

        Returns:
            JSON response as dict, or None if all retries failed
        """
        base_params = {
            "method": method,
            "api_key": self._api_key,
            "format": "json",
        }
        base_params.update(params)

        for attempt in range(max_retries):
            self._rate_limit()
            try:
                response = requests.get(BASE_URL, params=base_params, timeout=15)
                response.raise_for_status()
                data = response.json()

                # Check for API-level errors
                if "error" in data:
                    error_msg = data.get("message", "Unknown error")
                    logger.debug(f"Last.fm API error: {error_msg}")
                    return None

                return data
            except requests.RequestException as e:
                if attempt < max_retries - 1:
                    sleep_time = 2**attempt  # Exponential backoff: 1, 2, 4 seconds
                    logger.debug(
                        f"Last.fm request failed (attempt {attempt + 1}/{max_retries}), "
                        f"retrying in {sleep_time}s: {e}"
                    )
                    time.sleep(sleep_time)
                else:
                    logger.debug(f"Last.fm API request failed for {method}: {e}")
        return None

    def fetch_album_info(self, artist_name: str, album_name: str) -> AlbumInfo:
        """Fetch album metadata from Last.fm.

        Returns AlbumInfo with: image_url, wiki, genre (from tags), name.
        Results are cached for subsequent calls.
        """
        if not self.enabled:
            return AlbumInfo()

        cache_key = (artist_name, album_name)
        cached = self._album_cache.get(cache_key)
        if cached is not None:
            return cached

        result = AlbumInfo()

        try:
            data = self._make_request(
                "album.getinfo",
                {"artist": artist_name, "album": album_name, "autocorrect": "1"},
            )

            if data and data.get("album"):
                album_data = data["album"]

                # Get corrected album name from Last.fm
                result.name = album_data.get("name")

                # Extract wiki summary (prefer summary over full content)
                wiki = album_data.get("wiki", {})
                if wiki:
                    summary = wiki.get("summary", "")
                    if summary:
                        result.wiki = self._clean_wiki_text(summary)

                # Note: Last.fm uses tags instead of genre, but we don't map them
                # to avoid polluting genre with user-generated tags

                # Extract image URL (prefer extralarge or mega)
                images = album_data.get("image", [])
                image_url = self._get_best_image(images)

                if image_url and self._storage:
                    uploaded_url = self._storage.download_and_upload_image(
                        image_url, artist_name, album_name
                    )
                    if uploaded_url:
                        result.image_url = uploaded_url
                elif image_url:
                    # No storage service, use Last.fm URL directly
                    result.image_url = image_url

                logger.debug(f"Last.fm found album '{album_name}' by '{artist_name}'")

        except Exception as e:
            logger.warning(f"Could not fetch Last.fm album info for {album_name}: {e}")

        self._album_cache.set(cache_key, result)
        return result

    def _get_best_image(self, images: list[dict]) -> str | None:
        """Extract the best quality image URL from Last.fm image list.

        Last.fm provides images in sizes: small, medium, large, extralarge, mega
        """
        if not images:
            return None

        # Priority order for image sizes
        size_priority = ["mega", "extralarge", "large", "medium", "small"]

        # Build a map of size -> url
        size_map = {}
        for img in images:
            size = img.get("size", "")
            url = img.get("#text", "")
            if size and url:
                size_map[size] = url

        # Return the highest quality available
        for size in size_priority:
            if size in size_map and size_map[size]:
                return size_map[size]

        return None

    def _clean_wiki_text(self, text: str) -> str:
        """Clean up wiki text from Last.fm.

        Removes HTML tags and "Read more on Last.fm" links.
        """
        # Remove <a> tags (Read more links)
        text = re.sub(r"<a\s+[^>]*>.*?</a>", "", text)

        # Remove any remaining HTML tags
        text = re.sub(r"<[^>]+>", "", text)

        # Clean up whitespace
        text = " ".join(text.split())

        return text.strip()
