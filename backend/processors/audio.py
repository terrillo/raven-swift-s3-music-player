"""Audio file processing (scanning and conversion)."""

import logging
import subprocess
from pathlib import Path

from ..config import NATIVE_FORMATS, SUPPORTED_FORMATS, PathConfig

logger = logging.getLogger(__name__)


class AudioProcessor:
    """Handles audio file scanning and conversion."""

    def __init__(self, config: PathConfig) -> None:
        self._music_dir = config.music_dir
        self._converted_dir = config.converted_dir

    def scan_directory(self) -> list[Path]:
        """Scan the music directory and return all audio files."""
        audio_files = []
        for ext in SUPPORTED_FORMATS:
            audio_files.extend(self._music_dir.rglob(f"*{ext}"))
        return sorted(audio_files)

    def needs_conversion(self, file_path: Path) -> bool:
        """Check if a file needs conversion to m4a."""
        return file_path.suffix.lower() not in NATIVE_FORMATS

    def convert_to_m4a(self, file_path: Path) -> Path | None:
        """Convert an audio file to m4a format using ffmpeg.

        Returns the path to the converted file, or None if conversion fails.
        Converted files are stored in the 'converted/' directory with the same
        relative structure as the source.
        """
        # Determine output path maintaining directory structure
        relative_path = file_path.relative_to(self._music_dir)
        output_path = self._converted_dir / relative_path.with_suffix(".m4a")

        # Skip if already converted
        if output_path.exists():
            return output_path

        # Create output directory
        output_path.parent.mkdir(parents=True, exist_ok=True)

        try:
            cmd = [
                "ffmpeg",
                "-i",
                str(file_path),
                "-vn",  # Ignore video/image streams (embedded artwork)
                "-c:a",
                "aac",  # AAC codec
                "-b:a",
                "256k",  # 256kbps bitrate
                "-movflags",
                "+faststart",  # Optimize for streaming
                "-map_metadata",
                "0",  # Preserve metadata
                "-y",  # Overwrite output
                str(output_path),
            ]

            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=300,  # 5 minute timeout
            )

            if result.returncode != 0:
                logger.warning(
                    f"ffmpeg failed for {file_path.name}: {result.stderr[:200]}"
                )
                return None

            return output_path

        except subprocess.TimeoutExpired:
            logger.warning(f"Conversion timed out for {file_path.name}")
            return None
        except FileNotFoundError:
            logger.error("ffmpeg not found. Please install ffmpeg.")
            return None
        except Exception as e:
            logger.warning(f"Could not convert {file_path.name}: {e}")
            return None
