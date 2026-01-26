"""Tests for FLAC to M4A conversion using the Santana album.

These tests verify:
1. AudioProcessor correctly identifies files needing conversion
2. FLAC files are converted to valid M4A files with ffmpeg
3. Catalog shows correct format/original_format fields after conversion
"""

import json
import subprocess
from pathlib import Path

import pytest
from tinytag import TinyTag

from backend.config import PathConfig
from backend.processors.audio import AudioProcessor


TESTS_DIR = Path(__file__).parent
ROOT_DIR = TESTS_DIR.parent
MUSIC_DIR = ROOT_DIR / "music"
BACKEND_DIR = ROOT_DIR / "backend"
CONVERTED_DIR = BACKEND_DIR / "converted"
GENERATED_CATALOG = BACKEND_DIR / "music_catalog.json"

# Santana album folder name
SANTANA_ALBUM_FOLDER = "Santana - The Breathing Flame (Live) (2022) FLAC [PMEDIA] ⭐️"
SANTANA_ALBUM_PATH = MUSIC_DIR / SANTANA_ALBUM_FOLDER


class TestFlacToM4aConversion:
    """Test FLAC to M4A conversion using AudioProcessor."""

    @pytest.fixture
    def path_config(self):
        """Create PathConfig for tests."""
        return PathConfig(
            music_dir=MUSIC_DIR,
            catalog_file=GENERATED_CATALOG,
            converted_dir=CONVERTED_DIR,
        )

    @pytest.fixture
    def audio_processor(self, path_config):
        """Create AudioProcessor instance."""
        return AudioProcessor(path_config)

    @pytest.fixture
    def santana_flac_file(self):
        """Get the first Santana FLAC file for testing."""
        if not SANTANA_ALBUM_PATH.exists():
            pytest.skip(f"Santana album not found: {SANTANA_ALBUM_PATH}")

        flac_files = list(SANTANA_ALBUM_PATH.glob("*.flac"))
        if not flac_files:
            pytest.skip("No FLAC files found in Santana album")

        # Return the first track (01. Black Magic Woman)
        return sorted(flac_files)[0]

    def test_needs_conversion_for_flac_files(self, audio_processor, santana_flac_file):
        """FLAC files should be identified as needing conversion."""
        assert audio_processor.needs_conversion(santana_flac_file) is True

    def test_needs_conversion_false_for_mp3(self, audio_processor):
        """MP3 files should NOT need conversion."""
        mp3_path = Path("/fake/path/song.mp3")
        assert audio_processor.needs_conversion(mp3_path) is False

    def test_needs_conversion_false_for_m4a(self, audio_processor):
        """M4A files should NOT need conversion."""
        m4a_path = Path("/fake/path/song.m4a")
        assert audio_processor.needs_conversion(m4a_path) is False

    def test_convert_single_flac_to_m4a(self, audio_processor, santana_flac_file):
        """Converting a FLAC file should produce an M4A file."""
        converted_path = audio_processor.convert_to_m4a(santana_flac_file)

        assert converted_path is not None, "Conversion returned None (ffmpeg may have failed)"
        assert converted_path.exists(), f"Converted file not found: {converted_path}"
        assert converted_path.suffix == ".m4a", f"Expected .m4a extension, got {converted_path.suffix}"
        assert converted_path.stat().st_size > 0, "Converted file is empty"

        # Verify it's in the converted directory with correct structure
        assert CONVERTED_DIR in converted_path.parents, "Converted file should be in converted/ directory"

    def test_converted_file_is_valid_m4a(self, audio_processor, santana_flac_file):
        """Converted file should be a valid M4A/AAC audio file."""
        converted_path = audio_processor.convert_to_m4a(santana_flac_file)
        assert converted_path is not None

        # Use ffprobe to validate the file
        result = subprocess.run(
            [
                "ffprobe",
                "-v", "error",
                "-select_streams", "a:0",
                "-show_entries", "stream=codec_name",
                "-of", "default=noprint_wrappers=1:nokey=1",
                str(converted_path),
            ],
            capture_output=True,
            text=True,
        )

        assert result.returncode == 0, f"ffprobe failed: {result.stderr}"
        codec = result.stdout.strip()
        assert codec == "aac", f"Expected AAC codec, got: {codec}"

    def test_conversion_preserves_duration(self, audio_processor, santana_flac_file):
        """Converted file should have approximately the same duration as original."""
        # Get original duration using TinyTag
        original_tag = TinyTag.get(santana_flac_file)
        original_duration = original_tag.duration

        # Convert and get converted duration using ffprobe
        converted_path = audio_processor.convert_to_m4a(santana_flac_file)
        assert converted_path is not None

        result = subprocess.run(
            [
                "ffprobe",
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                str(converted_path),
            ],
            capture_output=True,
            text=True,
        )

        assert result.returncode == 0, f"ffprobe failed: {result.stderr}"
        converted_duration = float(result.stdout.strip())

        # Allow 1 second tolerance
        assert abs(original_duration - converted_duration) < 1.0, (
            f"Duration mismatch: original={original_duration:.2f}s, converted={converted_duration:.2f}s"
        )

    def test_skip_already_converted(self, audio_processor, santana_flac_file):
        """Converting an already-converted file should return existing path without re-converting."""
        # First conversion
        converted_path_1 = audio_processor.convert_to_m4a(santana_flac_file)
        assert converted_path_1 is not None

        # Get modification time
        mtime_before = converted_path_1.stat().st_mtime

        # Second conversion should skip
        converted_path_2 = audio_processor.convert_to_m4a(santana_flac_file)

        assert converted_path_2 == converted_path_1, "Should return same path"

        # File should not have been modified
        mtime_after = converted_path_2.stat().st_mtime
        assert mtime_before == mtime_after, "File should not have been re-converted"


class TestCatalogFlacConversion:
    """Test catalog integration for FLAC conversion.

    Verifies that the generated catalog correctly shows:
    - format: "m4a" (the converted format)
    - original_format: "flac" (the source format)
    """

    @pytest.fixture
    def generated_catalog(self):
        """Load the generated catalog from dry-run."""
        if not GENERATED_CATALOG.exists():
            pytest.skip(
                f"Generated catalog not found: {GENERATED_CATALOG}. "
                "Run 'cd backend && python upload_music.py --dry-run' first."
            )
        with open(GENERATED_CATALOG) as f:
            return json.load(f)

    def _find_santana_artist(self, catalog: dict) -> dict | None:
        """Find Santana artist in catalog."""
        for artist in catalog.get("artists", []):
            if "Santana" in artist["name"]:
                return artist
        return None

    def _find_breathing_flame_album(self, artist: dict) -> dict | None:
        """Find The Breathing Flame album."""
        for album in artist.get("albums", []):
            if "Breathing Flame" in album["name"]:
                return album
        return None

    @pytest.fixture
    def santana_artist(self, generated_catalog):
        """Get Santana artist or skip if not in catalog."""
        artist = self._find_santana_artist(generated_catalog)
        if artist is None:
            pytest.skip(
                "Santana not in catalog. Regenerate with: "
                "cd backend && python upload_music.py --dry-run"
            )
        return artist

    @pytest.fixture
    def breathing_flame_album(self, santana_artist):
        """Get The Breathing Flame album or skip if not found."""
        album = self._find_breathing_flame_album(santana_artist)
        if album is None:
            pytest.skip(
                f"Breathing Flame album not found. Available albums: "
                f"{[a['name'] for a in santana_artist.get('albums', [])]}"
            )
        return album

    def test_santana_artist_exists(self, santana_artist):
        """Santana should exist in the catalog."""
        assert santana_artist is not None

    def test_santana_tracks_show_correct_format_fields(self, breathing_flame_album):
        """Santana FLAC tracks should show format='m4a' and original_format='flac'."""
        tracks_with_wrong_format = []

        for track in breathing_flame_album.get("tracks", []):
            errors = []

            if track.get("format") != "m4a":
                errors.append(f"format='{track.get('format')}' (expected 'm4a')")

            if track.get("original_format") != "flac":
                errors.append(f"original_format='{track.get('original_format')}' (expected 'flac')")

            if errors:
                tracks_with_wrong_format.append(f"{track['title']}: {', '.join(errors)}")

        assert len(tracks_with_wrong_format) == 0, (
            f"Tracks with incorrect format fields:\n" + "\n".join(tracks_with_wrong_format)
        )

    def test_santana_s3_keys_use_m4a_extension(self, breathing_flame_album):
        """Santana track s3_keys should end with .m4a, not .flac."""
        tracks_with_wrong_extension = []

        for track in breathing_flame_album.get("tracks", []):
            s3_key = track.get("s3_key", "")
            if not s3_key.endswith(".m4a"):
                tracks_with_wrong_extension.append(f"{track['title']}: {s3_key}")

        assert len(tracks_with_wrong_extension) == 0, (
            f"Tracks with wrong s3_key extension (should be .m4a):\n"
            + "\n".join(tracks_with_wrong_extension)
        )

    def test_santana_track_count(self, breathing_flame_album):
        """Santana album should have 11 tracks (matching the FLAC files)."""
        track_count = len(breathing_flame_album.get("tracks", []))
        assert track_count == 11, f"Expected 11 tracks, got {track_count}"
