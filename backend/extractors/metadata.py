"""Audio metadata extraction using TinyTag."""

import logging
import re
from pathlib import Path

from tinytag import TinyTag

from ..models.track import TrackMetadata
from ..utils.identifiers import extract_year

logger = logging.getLogger(__name__)


class MetadataExtractor:
    """Extracts metadata from audio files using TinyTag."""

    def __init__(self, music_dir: Path) -> None:
        self._music_dir = music_dir

    def extract(self, file_path: Path) -> TrackMetadata:
        """Extract metadata from an audio file using TinyTag."""
        try:
            tag = TinyTag.get(str(file_path))

            # Parse track number (may be "1/10" format or just "1")
            track_num = None
            track_total = None
            if tag.track:
                track_str = str(tag.track)
                if "/" in track_str:
                    parts = track_str.split("/")
                    track_num = int(parts[0]) if parts[0].isdigit() else None
                    track_total = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else None
                else:
                    track_num = int(track_str) if track_str.isdigit() else None

            # Use track_total from tag if available
            if tag.track_total:
                track_total = int(tag.track_total) if isinstance(tag.track_total, (int, float)) else None

            # Parse disc number
            disc_num = None
            disc_total = None
            if tag.disc:
                disc_str = str(tag.disc)
                if "/" in disc_str:
                    parts = disc_str.split("/")
                    disc_num = int(parts[0]) if parts[0].isdigit() else None
                    disc_total = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else None
                else:
                    disc_num = int(disc_str) if disc_str.isdigit() else None

            # Use disc_total from tag if available
            if tag.disc_total:
                disc_total = int(tag.disc_total) if isinstance(tag.disc_total, (int, float)) else None

            metadata = TrackMetadata(
                title=tag.title or file_path.stem,
                artist=tag.artist,
                album=tag.album,
                album_artist=tag.albumartist,
                track_number=track_num,
                track_total=track_total,
                disc_number=disc_num,
                disc_total=disc_total,
                duration=int(tag.duration) if tag.duration else None,
                year=extract_year(tag.year),
                genre=tag.genre,
                composer=tag.composer,
                comment=tag.comment,
                bitrate=tag.bitrate,
                samplerate=tag.samplerate,
                channels=tag.channels,
                filesize=tag.filesize,
                format=file_path.suffix.lstrip(".").lower(),
            )

            return self._apply_fallbacks(metadata, file_path)

        except Exception as e:
            logger.warning(f"Could not read metadata from {file_path}: {e}")
            # Return basic metadata with fallbacks
            metadata = TrackMetadata(
                title=file_path.stem,
                format=file_path.suffix.lstrip(".").lower(),
            )
            return self._apply_fallbacks(metadata, file_path)

    def _apply_fallbacks(self, metadata: TrackMetadata, file_path: Path) -> TrackMetadata:
        """Apply fallback extraction from filename and directory structure."""
        # Fallback: extract track number from filename (e.g., "01 Song Name.mp3")
        if metadata.track_number is None:
            match = re.match(r"^(\d+)\s+", file_path.name)
            if match:
                metadata.track_number = int(match.group(1))

        # Fallback: extract artist/album from directory structure
        # Expected structure: music/Artist/Album/Track.mp3
        try:
            parts = file_path.relative_to(self._music_dir).parts
            if len(parts) >= 3:
                if metadata.artist is None:
                    metadata.artist = parts[0]
                if metadata.album is None:
                    metadata.album = parts[1]
        except ValueError:
            pass  # file_path is not relative to music_dir

        return metadata
