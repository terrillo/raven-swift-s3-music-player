"""Configuration management for the music upload backend."""

import logging
import os
from dataclasses import dataclass, field
from pathlib import Path

from boto3.s3.transfer import TransferConfig
from dotenv import load_dotenv


# Supported audio formats
SUPPORTED_FORMATS = {".mp3", ".m4a", ".flac", ".wav", ".aac"}
NATIVE_FORMATS = {".mp3", ".m4a"}  # Formats that don't need conversion


@dataclass
class SpacesConfig:
    """DigitalOcean Spaces configuration."""

    key: str
    secret: str
    bucket: str
    region: str = "nyc3"
    endpoint: str | None = None
    prefix: str = "music"  # S3 path prefix for all files

    def __post_init__(self) -> None:
        if self.endpoint is None:
            self.endpoint = f"https://{self.region}.digitaloceanspaces.com"


@dataclass
class TheAudioDBConfig:
    """TheAudioDB API configuration."""

    api_url: str = "https://www.theaudiodb.com/api/v1/json/123"
    enabled: bool = True  # Always enabled, no API key required


@dataclass
class MusicBrainzConfig:
    """MusicBrainz API configuration for MBID lookups."""

    app_name: str = "MusicUploader"
    app_version: str = "1.0"
    app_contact: str = ""
    api_url: str = "https://musicbrainz.org/ws/2"
    enabled: bool = True

    @property
    def user_agent(self) -> str:
        """User-Agent header required by MusicBrainz API."""
        contact = f" ({self.app_contact})" if self.app_contact else ""
        return f"{self.app_name}/{self.app_version}{contact}"


@dataclass
class LastFMConfig:
    """Last.fm API configuration for fallback album metadata."""

    api_key: str = ""
    enabled: bool = True

    @property
    def is_configured(self) -> bool:
        """Check if Last.fm is properly configured."""
        return bool(self.api_key) and self.enabled


@dataclass
class PathConfig:
    """File path configuration."""

    music_dir: Path
    catalog_file: Path
    converted_dir: Path

    def validate(self) -> None:
        """Validate that required paths exist."""
        if not self.music_dir.exists():
            raise ValueError(f"Music directory not found: {self.music_dir}")


@dataclass
class Config:
    """Main configuration container."""

    spaces: SpacesConfig
    theaudiodb: TheAudioDBConfig
    musicbrainz: MusicBrainzConfig
    lastfm: LastFMConfig
    paths: PathConfig
    max_upload_workers: int = 4
    transfer_config: TransferConfig = field(default_factory=lambda: TransferConfig(
        multipart_threshold=8 * 1024 * 1024,  # 8MB
        max_concurrency=4,
        multipart_chunksize=8 * 1024 * 1024,  # 8MB chunks
        use_threads=True,
    ))

    @classmethod
    def from_environment(cls, env_path: Path | None = None) -> "Config":
        """Load configuration from environment variables."""
        if env_path:
            load_dotenv(env_path)
        else:
            load_dotenv()

        # Validate required Spaces credentials
        spaces_key = os.getenv("DO_SPACES_KEY")
        spaces_secret = os.getenv("DO_SPACES_SECRET")
        spaces_bucket = os.getenv("DO_SPACES_BUCKET")

        if not all([spaces_key, spaces_secret, spaces_bucket]):
            raise ValueError(
                "Missing required environment variables. "
                "Please set DO_SPACES_KEY, DO_SPACES_SECRET, and DO_SPACES_BUCKET"
            )

        spaces_region = os.getenv("DO_SPACES_REGION", "nyc3")
        spaces_endpoint = os.getenv("DO_SPACES_ENDPOINT")
        spaces_prefix = os.getenv("DO_SPACES_PREFIX", "music")

        # Paths relative to this file's directory
        backend_dir = Path(__file__).parent
        music_dir = backend_dir.parent / "music"
        catalog_file = backend_dir / "music_catalog.json"
        converted_dir = backend_dir / "converted"

        return cls(
            spaces=SpacesConfig(
                key=spaces_key,
                secret=spaces_secret,
                bucket=spaces_bucket,
                region=spaces_region,
                endpoint=spaces_endpoint,
                prefix=spaces_prefix,
            ),
            theaudiodb=TheAudioDBConfig(),
            musicbrainz=MusicBrainzConfig(
                app_name=os.getenv("MUSICBRAINZ_APP_NAME", "MusicUploader"),
                app_version=os.getenv("MUSICBRAINZ_APP_VERSION", "1.0"),
                app_contact=os.getenv("MUSICBRAINZ_CONTACT", ""),
                enabled=os.getenv("MUSICBRAINZ_ENABLED", "true").lower() == "true",
            ),
            lastfm=LastFMConfig(
                api_key=os.getenv("LASTFM_API_KEY", ""),
                enabled=os.getenv("LASTFM_ENABLED", "true").lower() == "true",
            ),
            paths=PathConfig(
                music_dir=music_dir,
                catalog_file=catalog_file,
                converted_dir=converted_dir,
            ),
        )

    def validate(self) -> None:
        """Validate the configuration."""
        self.paths.validate()
        self._validate_spaces()

    def _validate_spaces(self) -> None:
        """Validate Spaces configuration."""
        logger = logging.getLogger(__name__)

        # Validate required fields
        if not self.spaces.bucket:
            raise ValueError("DO_SPACES_BUCKET is required")
        if not self.spaces.key:
            raise ValueError("DO_SPACES_KEY is required")
        if not self.spaces.secret:
            raise ValueError("DO_SPACES_SECRET is required")

        # Warn on unrecognized regions
        known_regions = {"nyc3", "sfo3", "ams3", "sgp1", "fra1", "syd1", "blr1"}
        if self.spaces.region not in known_regions:
            logger.warning(
                f"Unrecognized DO Spaces region '{self.spaces.region}'. "
                f"Known regions: {', '.join(sorted(known_regions))}"
            )


def configure_logging(verbose: bool = False) -> None:
    """Configure logging for the application."""
    level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    )
