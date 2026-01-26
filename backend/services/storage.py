"""DigitalOcean Spaces storage service."""

import logging
import time
from pathlib import Path
from threading import Lock

import boto3
import requests
from boto3.s3.transfer import TransferConfig
from botocore.config import Config as BotoConfig
from botocore.exceptions import ClientError

from ..config import SpacesConfig
from ..utils.identifiers import sanitize_s3_key

logger = logging.getLogger(__name__)

# Content type mapping for audio files
AUDIO_CONTENT_TYPES = {
    ".mp3": "audio/mpeg",
    ".m4a": "audio/x-m4a",
    ".flac": "audio/flac",
    ".wav": "audio/wav",
    ".aac": "audio/aac",
}

# Image validation constants
MAX_IMAGE_SIZE = 10 * 1024 * 1024  # 10MB
ALLOWED_IMAGE_TYPES = {"image/jpeg", "image/png", "image/webp", "image/gif"}


class StorageService:
    """Service for interacting with DigitalOcean Spaces."""

    def __init__(self, config: SpacesConfig, transfer_config: TransferConfig | None = None) -> None:
        self._config = config
        self._transfer_config = transfer_config or TransferConfig(
            multipart_threshold=8 * 1024 * 1024,
            max_concurrency=4,
            multipart_chunksize=8 * 1024 * 1024,
            use_threads=True,
        )
        self._client = None
        self._existing_keys_cache: set[str] | None = None
        self._cache_lock = Lock()

    @property
    def client(self):
        """Lazy-initialize the S3 client."""
        if self._client is None:
            boto_config = BotoConfig(
                connect_timeout=60,
                read_timeout=300,
                retries={"max_attempts": 3, "mode": "adaptive"},
            )
            self._client = boto3.client(
                "s3",
                region_name=self._config.region,
                endpoint_url=self._config.endpoint,
                aws_access_key_id=self._config.key,
                aws_secret_access_key=self._config.secret,
                config=boto_config,
            )
        return self._client

    def _prefixed_key(self, s3_key: str) -> str:
        """Add configured prefix to S3 key."""
        return f"{self._config.prefix}/{s3_key}"

    def list_all_files(self) -> set[str]:
        """List all files in the bucket under the configured prefix.

        Returns:
            Set of s3_keys (without prefix) for O(1) lookups.
        """
        existing_keys: set[str] = set()
        continuation_token = None
        prefix = f"{self._config.prefix}/"

        try:
            while True:
                kwargs = {
                    "Bucket": self._config.bucket,
                    "Prefix": prefix,
                    "MaxKeys": 1000,
                }
                if continuation_token:
                    kwargs["ContinuationToken"] = continuation_token

                response = self.client.list_objects_v2(**kwargs)

                for obj in response.get("Contents", []):
                    key = obj["Key"]
                    if key.startswith(prefix):
                        s3_key = key[len(prefix):]
                        existing_keys.add(s3_key)

                if response.get("IsTruncated"):
                    continuation_token = response.get("NextContinuationToken")
                else:
                    break
        except ClientError as e:
            logger.warning(f"Could not list remote files: {e}")
            # Return empty set - will fall back to per-file checks

        return existing_keys

    def set_existing_keys_cache(self, keys: set[str]) -> None:
        """Set the cache of existing keys for efficient lookups."""
        self._existing_keys_cache = keys

    def _add_to_cache(self, s3_key: str) -> None:
        """Thread-safe add to cache after successful upload."""
        if self._existing_keys_cache is not None:
            with self._cache_lock:
                self._existing_keys_cache.add(s3_key)

    def get_public_url(self, s3_key: str) -> str:
        """Generate the public CDN URL for a file in Spaces."""
        return (
            f"https://{self._config.bucket}.{self._config.region}.cdn.digitaloceanspaces.com/"
            f"{self._config.prefix}/{s3_key}"
        )

    def file_exists(self, s3_key: str) -> bool:
        """Check if a file already exists in Spaces.

        Uses cached key list if available, otherwise falls back to HEAD request.
        """
        # Check cache first (O(1) lookup)
        if self._existing_keys_cache is not None:
            return s3_key in self._existing_keys_cache

        # Fallback to HEAD request
        try:
            self.client.head_object(Bucket=self._config.bucket, Key=self._prefixed_key(s3_key))
            return True
        except ClientError:
            return False

    def upload_file(self, file_path: Path, s3_key: str, content_type: str | None = None) -> bool:
        """Upload a file to Spaces with retry logic.

        Returns True on success, False on failure.
        """
        if content_type is None:
            content_type = AUDIO_CONTENT_TYPES.get(
                file_path.suffix.lower(), "application/octet-stream"
            )

        prefixed_key = self._prefixed_key(s3_key)
        max_retries = 3
        for attempt in range(max_retries):
            try:
                self.client.upload_file(
                    str(file_path),
                    self._config.bucket,
                    prefixed_key,
                    ExtraArgs={
                        "ACL": "public-read",
                        "ContentType": content_type,
                    },
                    Config=self._transfer_config,
                )
                self._add_to_cache(s3_key)
                return True
            except (ClientError, Exception) as e:
                if attempt < max_retries - 1:
                    wait_time = 2 ** (attempt + 1)
                    logger.warning(
                        f"Upload failed (attempt {attempt + 1}/{max_retries}), "
                        f"retrying in {wait_time}s: {e}"
                    )
                    time.sleep(wait_time)
                else:
                    logger.error(
                        f"Error uploading {file_path} after {max_retries} attempts: {e}"
                    )
                    return False
        return False

    def upload_bytes(self, data: bytes, s3_key: str, content_type: str) -> str | None:
        """Upload raw bytes to Spaces.

        Returns the public URL on success, None on failure.
        """
        # Check if already uploaded
        if self.file_exists(s3_key):
            return self.get_public_url(s3_key)

        try:
            self.client.put_object(
                Bucket=self._config.bucket,
                Key=self._prefixed_key(s3_key),
                Body=data,
                ACL="public-read",
                ContentType=content_type,
            )
            self._add_to_cache(s3_key)
            return self.get_public_url(s3_key)
        except ClientError as e:
            logger.exception(f"S3 error uploading {s3_key}")
            return None
        except Exception as e:
            logger.exception(f"Unexpected error uploading {s3_key}")
            return None

    def upload_catalog(self, catalog_path: Path) -> str | None:
        """Upload the catalog JSON to Spaces, clearing any cached version.

        Returns the public URL on success, None on failure.
        """
        s3_key = "music_catalog.json"
        prefixed_key = self._prefixed_key(s3_key)

        # Delete old catalog first to clear CDN cache
        try:
            self.client.delete_object(Bucket=self._config.bucket, Key=prefixed_key)
            logger.info("Cleared old catalog from Spaces")
        except ClientError:
            pass  # File might not exist

        try:
            self.client.upload_file(
                str(catalog_path),
                self._config.bucket,
                prefixed_key,
                ExtraArgs={
                    "ACL": "public-read",
                    "ContentType": "application/json",
                    "CacheControl": "no-cache, no-store, must-revalidate",
                },
            )
            return self.get_public_url(s3_key)
        except ClientError as e:
            logger.error(f"Error uploading catalog: {e}")
            return None

    def download_and_upload_image(
        self, image_url: str, artist: str, album: str
    ) -> str | None:
        """Download an album cover image from URL and upload to Spaces.

        Args:
            image_url: URL to download image from
            artist: Artist name for folder structure
            album: Album name for folder structure

        Returns the Spaces URL on success, None on failure.
        """
        if not image_url:
            return None

        # Generate organized S3 key: Artist/Album/cover.jpg
        safe_artist = sanitize_s3_key(artist, "Unknown Artist")
        safe_album = sanitize_s3_key(album, "Unknown Album")
        s3_key = f"{safe_artist}/{safe_album}/cover.jpg"

        # Check if already uploaded
        if self.file_exists(s3_key):
            return self.get_public_url(s3_key)

        try:
            # Validate image before downloading (HEAD request)
            head_response = requests.head(image_url, timeout=5, allow_redirects=True)
            content_length = int(head_response.headers.get("Content-Length", 0))
            content_type = head_response.headers.get("Content-Type", "").split(";")[0]

            if content_length > MAX_IMAGE_SIZE:
                logger.warning(f"Image too large ({content_length} bytes): {image_url}")
                return None

            if content_type and content_type not in ALLOWED_IMAGE_TYPES:
                logger.warning(f"Invalid image type ({content_type}): {image_url}")
                return None

            # Download the image
            response = requests.get(image_url, timeout=15)
            response.raise_for_status()

            # Double-check size after download
            if len(response.content) > MAX_IMAGE_SIZE:
                logger.warning(f"Downloaded image too large: {len(response.content)} bytes")
                return None

            actual_content_type = response.headers.get("Content-Type", "image/jpeg")

            self.client.put_object(
                Bucket=self._config.bucket,
                Key=self._prefixed_key(s3_key),
                Body=response.content,
                ACL="public-read",
                ContentType=actual_content_type,
            )
            self._add_to_cache(s3_key)
            return self.get_public_url(s3_key)

        except ClientError as e:
            logger.exception(f"S3 error uploading image {s3_key}")
            return None
        except requests.RequestException as e:
            logger.warning(f"Could not download image {image_url}: {e}")
            return None
        except Exception as e:
            logger.exception(f"Unexpected error uploading image {s3_key}")
            return None

    def download_and_upload_artist_image(
        self, image_url: str, artist: str
    ) -> str | None:
        """Download an artist image from URL and upload to Spaces.

        Args:
            image_url: URL to download image from
            artist: Artist name for folder structure

        Returns the Spaces URL on success, None on failure.
        """
        if not image_url:
            return None

        # Generate organized S3 key: Artist/artist.jpg
        safe_artist = sanitize_s3_key(artist, "Unknown Artist")
        s3_key = f"{safe_artist}/artist.jpg"

        # Check if already uploaded
        if self.file_exists(s3_key):
            return self.get_public_url(s3_key)

        try:
            # Validate image before downloading (HEAD request)
            head_response = requests.head(image_url, timeout=5, allow_redirects=True)
            content_length = int(head_response.headers.get("Content-Length", 0))
            content_type = head_response.headers.get("Content-Type", "").split(";")[0]

            if content_length > MAX_IMAGE_SIZE:
                logger.warning(f"Artist image too large ({content_length} bytes): {image_url}")
                return None

            if content_type and content_type not in ALLOWED_IMAGE_TYPES:
                logger.warning(f"Invalid artist image type ({content_type}): {image_url}")
                return None

            # Download the image
            response = requests.get(image_url, timeout=15)
            response.raise_for_status()

            # Double-check size after download
            if len(response.content) > MAX_IMAGE_SIZE:
                logger.warning(f"Downloaded artist image too large: {len(response.content)} bytes")
                return None

            actual_content_type = response.headers.get("Content-Type", "image/jpeg")

            self.client.put_object(
                Bucket=self._config.bucket,
                Key=self._prefixed_key(s3_key),
                Body=response.content,
                ACL="public-read",
                ContentType=actual_content_type,
            )
            self._add_to_cache(s3_key)
            return self.get_public_url(s3_key)

        except ClientError as e:
            logger.exception(f"S3 error uploading artist image {s3_key}")
            return None
        except requests.RequestException as e:
            logger.warning(f"Could not download artist image {image_url}: {e}")
            return None
        except Exception as e:
            logger.exception(f"Unexpected error uploading artist image {s3_key}")
            return None

    def upload_artwork_bytes(
        self, image_bytes: bytes, mime_type: str, artist: str, album: str
    ) -> str | None:
        """Upload embedded artwork bytes to Spaces.

        Args:
            image_bytes: Raw image data
            mime_type: MIME type of the image
            artist: Artist name for folder structure
            album: Album name for folder structure

        Returns the Spaces URL on success, None on failure.
        """
        if not image_bytes:
            return None

        safe_artist = sanitize_s3_key(artist, "Unknown Artist")
        safe_album = sanitize_s3_key(album, "Unknown Album")
        ext = "png" if "png" in mime_type else "jpg"
        s3_key = f"{safe_artist}/{safe_album}/embedded.{ext}"

        return self.upload_bytes(image_bytes, s3_key, mime_type)
