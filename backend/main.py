#!/usr/bin/env python3
"""
Music Upload Script for DigitalOcean Spaces

Scans the music directory, extracts metadata, uploads files to Spaces,
and generates a JSON catalog with streaming URLs.
"""

import argparse
import json
import logging
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from tqdm import tqdm

from .config import NATIVE_FORMATS, Config, configure_logging
from .extractors.artwork import ArtworkExtractor
from .extractors.metadata import MetadataExtractor
from .processors.audio import AudioProcessor
from .processors.catalog import CatalogBuilder
from .services.lastfm import LastFMService
from .services.musicbrainz import MusicBrainzService
from .services.storage import StorageService
from .services.theaudiodb import TheAudioDBService
from .utils.cache import ThreadSafeCache
from .utils.identifiers import normalize_artist_name, sanitize_s3_key

logger = logging.getLogger(__name__)


class MusicUploader:
    """Orchestrates the music upload process."""

    def __init__(self, config: Config) -> None:
        self._config = config
        self._storage = StorageService(config.spaces, config.transfer_config)

        # Create MusicBrainz service for MBID lookups (optional, improves TheAudioDB accuracy)
        self._musicbrainz = (
            MusicBrainzService(config.musicbrainz)
            if config.musicbrainz.enabled
            else None
        )

        # TheAudioDB service with optional MusicBrainz integration
        self._theaudiodb = TheAudioDBService(self._storage, self._musicbrainz)

        # Last.fm service as fallback for album metadata
        self._lastfm = (
            LastFMService(config.lastfm.api_key, self._storage)
            if config.lastfm.is_configured
            else None
        )

        self._audio = AudioProcessor(config.paths)
        self._metadata = MetadataExtractor(config.paths.music_dir)
        self._artwork = ArtworkExtractor()
        self._catalog_builder = CatalogBuilder(
            self._theaudiodb,
            self._musicbrainz,
            self._storage,
            self._lastfm,
        )
        self._embedded_artwork_cache: ThreadSafeCache[tuple[str, str], str | None] = (
            ThreadSafeCache()
        )

    def run(self, dry_run: bool = False) -> None:
        """Run the main upload workflow."""
        music_dir = self._config.paths.music_dir

        # Scan for audio files
        logger.info(f"Scanning {music_dir} for audio files...")
        print(f"Scanning {music_dir} for audio files...")
        audio_files = self._audio.scan_directory()

        # In dry-run mode, exclude the playnow folder
        if dry_run:
            audio_files = [f for f in audio_files if "playnow" not in f.parts]

        print(f"Found {len(audio_files)} audio files")

        if not audio_files:
            print("No audio files found.")
            return

        # Fetch existing remote files for efficient existence checking
        if not dry_run:
            print("Fetching list of existing remote files...")
            existing_keys = self._storage.list_all_files()
            self._storage.set_existing_keys_cache(existing_keys)
            print(f"Found {len(existing_keys)} files on remote storage")

        # Count files needing conversion
        files_to_convert = [f for f in audio_files if self._audio.needs_conversion(f)]
        if files_to_convert:
            print(f"  {len(files_to_convert)} files will be converted to m4a")

        if dry_run:
            print("\nDry run mode - generating catalog without uploads...")

        # Process files in parallel
        tracks = []
        uploaded_count = 0
        skipped_count = 0
        converted_count = 0

        print(f"Processing files with {self._config.max_upload_workers} parallel workers...")

        with ThreadPoolExecutor(max_workers=self._config.max_upload_workers) as executor:
            if dry_run:
                # Dry run: extract metadata only, no uploads
                futures = {
                    executor.submit(self.process_file_metadata_only, f): f for f in audio_files
                }
            else:
                # Normal mode: full processing with uploads
                futures = {
                    executor.submit(self.process_file, f): f for f in audio_files
                }

            for future in tqdm(
                as_completed(futures),
                total=len(audio_files),
                desc="Processing",
                unit="file",
            ):
                file_path = futures[future]
                try:
                    result = future.result()
                    if result:
                        if not dry_run:
                            # Track conversion stats
                            if result.get("original_format") != result.get("format"):
                                converted_count += 1

                            # Track upload stats
                            if result.pop("_already_exists", False):
                                skipped_count += 1
                            else:
                                uploaded_count += 1

                        tracks.append(result)
                except Exception as e:
                    logger.error(f"Error processing {file_path.name}: {e}")

        # Build and save catalog
        catalog = self._catalog_builder.build(tracks)

        catalog_file = self._config.paths.catalog_file
        try:
            catalog_dict = catalog.to_dict()
            json_str = json.dumps(catalog_dict, indent=2, ensure_ascii=False)
            with open(catalog_file, "w", encoding="utf-8") as f:
                f.write(json_str)
        except (TypeError, ValueError) as e:
            logger.error(f"Failed to serialize catalog to JSON: {e}")
            raise

        if dry_run:
            print(f"\nDry run complete!")
            print(f"  Total tracks: {len(tracks)}")
            print(f"  Catalog saved to: {catalog_file}")
            return

        # Upload catalog to Spaces
        print("Uploading catalog to Spaces...")
        catalog_url = self._storage.upload_catalog(catalog_file)

        print(f"\nComplete!")
        print(f"  Uploaded: {uploaded_count} files")
        print(f"  Skipped (already exists): {skipped_count} files")
        if converted_count:
            print(f"  Converted to m4a: {converted_count} files")
        print(f"  Total tracks: {len(tracks)}")
        print(f"  Catalog saved to: {catalog_file}")
        if catalog_url:
            print(f"  Catalog URL: {catalog_url}")

    def process_file(self, file_path: Path) -> dict | None:
        """Process a single audio file.

        This is the parallel worker function that handles conversion,
        metadata extraction, and upload for a single file.
        """
        original_path = file_path
        file_ext = file_path.suffix.lower()
        original_format = file_ext.lstrip(".")

        # Convert to m4a if not a native format
        if file_ext not in NATIVE_FORMATS:
            converted_path = self._audio.convert_to_m4a(file_path)
            if converted_path is None:
                logger.warning(f"Skipping {file_path.name} - conversion failed")
                return None
            file_path = converted_path
            file_ext = ".m4a"

        # Extract metadata from original file (before conversion)
        metadata = self._metadata.extract(original_path)

        # Use album_artist for organization (fallback to artist)
        album_artist_name = metadata.album_artist or metadata.artist or "Unknown Artist"
        album_artist_name = normalize_artist_name(album_artist_name)  # Normalize multi-artist names
        album_name = metadata.album or "Unknown Album"

        # Get corrected album name from TheAudioDB (for consistent S3 paths)
        album_info = self._theaudiodb.fetch_album_info(album_artist_name, album_name)
        corrected_album = album_info.name if album_info.name else album_name

        # Generate S3 key based on album_artist/album/title structure (using corrected names)
        album_artist = sanitize_s3_key(album_artist_name)
        album = sanitize_s3_key(corrected_album)
        title = sanitize_s3_key(metadata.title or original_path.stem, "Unknown Track")
        s3_key = f"{album_artist}/{album}/{title}{file_ext}"
        metadata.original_format = original_format
        metadata.format = file_ext.lstrip(".")

        # Check if file already exists
        already_exists = self._storage.file_exists(s3_key)

        if not already_exists:
            if not self._storage.upload_file(file_path, s3_key):
                return None

        # Extract and upload embedded artwork if available (use corrected names)
        embedded_artwork_url = self._get_embedded_artwork(
            original_path, album_artist_name, corrected_album
        )

        # Build track info dict
        track_info = {
            "title": metadata.title,
            "artist": metadata.artist,
            "album": metadata.album,
            "album_artist": metadata.album_artist,
            "track_number": metadata.track_number,
            "track_total": metadata.track_total,
            "disc_number": metadata.disc_number,
            "disc_total": metadata.disc_total,
            "duration": metadata.duration,
            "year": metadata.year,
            "genre": metadata.genre,
            "composer": metadata.composer,
            "comment": metadata.comment,
            "bitrate": metadata.bitrate,
            "samplerate": metadata.samplerate,
            "channels": metadata.channels,
            "filesize": metadata.filesize,
            "format": metadata.format,
            "original_format": metadata.original_format,
            "s3_key": s3_key,
            "url": self._storage.get_public_url(s3_key),
            "embedded_artwork_url": embedded_artwork_url,
            "_already_exists": already_exists,
        }
        return track_info

    def process_file_metadata_only(self, file_path: Path) -> dict | None:
        """Extract metadata without uploads for dry-run mode.

        This method extracts all metadata using TinyTag but skips:
        - S3 existence checks
        - File uploads
        - Artwork extraction
        """
        original_path = file_path
        file_ext = file_path.suffix.lower()
        original_format = file_ext.lstrip(".")

        # For dry-run, we don't convert files - just note what format they would be
        # Native formats stay as-is, others would be converted to m4a
        if file_ext not in NATIVE_FORMATS:
            file_ext = ".m4a"

        # Extract metadata from original file
        metadata = self._metadata.extract(original_path)
        metadata.original_format = original_format
        metadata.format = file_ext.lstrip(".")

        # Use album_artist for organization (fallback to artist)
        album_artist_name = metadata.album_artist or metadata.artist or "Unknown Artist"
        album_artist_name = normalize_artist_name(album_artist_name)  # Normalize multi-artist names
        album_name = metadata.album or "Unknown Album"

        # Use original names for S3 key (catalog builder handles name correction and metadata)
        corrected_album = album_name

        # Generate S3 key based on album_artist/album/title structure
        album_artist = sanitize_s3_key(album_artist_name)
        album = sanitize_s3_key(corrected_album)
        title = sanitize_s3_key(metadata.title or original_path.stem, "Unknown Track")
        s3_key = f"{album_artist}/{album}/{title}{file_ext}"

        # Build track info dict with placeholder URLs
        track_info = {
            "title": metadata.title,
            "artist": metadata.artist,
            "album": metadata.album,
            "album_artist": metadata.album_artist,
            "track_number": metadata.track_number,
            "track_total": metadata.track_total,
            "disc_number": metadata.disc_number,
            "disc_total": metadata.disc_total,
            "duration": metadata.duration,
            "year": metadata.year,
            "genre": metadata.genre,
            "composer": metadata.composer,
            "comment": metadata.comment,
            "bitrate": metadata.bitrate,
            "samplerate": metadata.samplerate,
            "channels": metadata.channels,
            "filesize": metadata.filesize,
            "format": metadata.format,
            "original_format": metadata.original_format,
            "s3_key": s3_key,
            "url": None,  # Not uploaded in dry-run
            "embedded_artwork_url": None,  # Skipped in dry-run
        }
        return track_info

    def _get_embedded_artwork(
        self, file_path: Path, album_artist: str, album: str
    ) -> str | None:
        """Extract and upload embedded artwork, with caching.

        Args:
            file_path: Path to the audio file
            album_artist: The album artist name (for S3 organization)
            album: The corrected album name from TheAudioDB
        """
        cache_key = (album_artist, album)

        # Check cache first
        cached = self._embedded_artwork_cache.get(cache_key)
        if cached is not None:
            return cached

        # Mark as processing to avoid duplicate work
        self._embedded_artwork_cache.set(cache_key, None)

        # Extract artwork
        artwork = self._artwork.extract(file_path)
        if artwork:
            url = self._storage.upload_artwork_bytes(
                artwork.data, artwork.mime_type, album_artist, album
            )
            self._embedded_artwork_cache.set(cache_key, url)
            return url

        return None


def parse_args() -> argparse.Namespace:
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(
        description="Upload music to DigitalOcean Spaces"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Scan only, no uploads",
    )
    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Verbose output",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=4,
        help="Number of parallel workers (default: 4)",
    )
    return parser.parse_args()


def main() -> None:
    """Main entry point."""
    args = parse_args()

    configure_logging(verbose=args.verbose)

    try:
        config = Config.from_environment()
        config.max_upload_workers = args.workers
        config.validate()
    except ValueError as e:
        print(f"Error: {e}")
        return

    uploader = MusicUploader(config)
    uploader.run(dry_run=args.dry_run)


if __name__ == "__main__":
    main()
