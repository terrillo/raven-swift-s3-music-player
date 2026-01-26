"""Embedded artwork extraction from audio files."""

import logging
from dataclasses import dataclass
from pathlib import Path

from mutagen import File as MutagenFile
from mutagen.flac import FLAC
from mutagen.mp3 import MP3
from mutagen.mp4 import MP4

logger = logging.getLogger(__name__)


@dataclass
class ExtractedArtwork:
    """Artwork data extracted from an audio file."""

    data: bytes
    mime_type: str


class ArtworkExtractor:
    """Extracts embedded artwork from audio files."""

    def extract(self, file_path: Path) -> ExtractedArtwork | None:
        """Extract embedded artwork from an audio file.

        Returns ExtractedArtwork on success, None if no artwork found.
        """
        try:
            audio = MutagenFile(file_path)
            if audio is None:
                return None

            # MP3 files - check APIC frames in ID3 tags
            if isinstance(audio, MP3):
                return self._extract_from_mp3(audio)

            # M4A/MP4 files - check 'covr' atom
            elif isinstance(audio, MP4):
                return self._extract_from_mp4(audio)

            # FLAC files - check pictures
            elif isinstance(audio, FLAC):
                return self._extract_from_flac(audio)

            # Generic fallback - try to find pictures attribute
            elif hasattr(audio, "pictures") and audio.pictures:
                pic = audio.pictures[0]
                return ExtractedArtwork(
                    data=pic.data,
                    mime_type=getattr(pic, "mime", "image/jpeg"),
                )

        except Exception as e:
            logger.warning(f"Could not extract artwork from {file_path}: {e}")

        return None

    def _extract_from_mp3(self, audio: MP3) -> ExtractedArtwork | None:
        """Extract APIC frames from ID3 tags."""
        if audio.tags:
            for key in audio.tags.keys():
                if key.startswith("APIC"):
                    apic = audio.tags[key]
                    return ExtractedArtwork(
                        data=apic.data,
                        mime_type=apic.mime or "image/jpeg",
                    )
        return None

    def _extract_from_mp4(self, audio: MP4) -> ExtractedArtwork | None:
        """Extract covr atom from MP4."""
        if audio.tags and "covr" in audio.tags:
            covers = audio.tags["covr"]
            if covers:
                cover = covers[0]
                # MP4Cover format: 13 = JPEG, 14 = PNG
                mime = (
                    "image/png"
                    if getattr(cover, "imageformat", None) == 14
                    else "image/jpeg"
                )
                return ExtractedArtwork(
                    data=bytes(cover),
                    mime_type=mime,
                )
        return None

    def _extract_from_flac(self, audio: FLAC) -> ExtractedArtwork | None:
        """Extract picture block from FLAC."""
        if audio.pictures:
            pic = audio.pictures[0]
            return ExtractedArtwork(
                data=pic.data,
                mime_type=pic.mime or "image/jpeg",
            )
        return None
