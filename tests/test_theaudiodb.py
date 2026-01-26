"""Unit tests for backend/services/theaudiodb.py helper methods."""

import sys
from pathlib import Path

import pytest

# Add parent dir to path so backend is importable as a package
sys.path.insert(0, str(Path(__file__).parent.parent))

from backend.services.theaudiodb import TheAudioDBService


class TestNormalizeAlbumName:
    """Tests for _normalize_album_name() method."""

    @pytest.fixture
    def service(self):
        """Create a TheAudioDBService instance (no storage needed for these tests)."""
        return TheAudioDBService(storage=None)

    def test_simple_album_unchanged(self, service):
        """Simple album name should pass through unchanged."""
        assert service._normalize_album_name("Hozier") == "Hozier"
        assert service._normalize_album_name("Abbey Road") == "Abbey Road"

    def test_deluxe_version_stripped(self, service):
        """(Deluxe Version) suffix should be stripped."""
        assert service._normalize_album_name("Hozier (Deluxe Version)") == "Hozier"
        assert service._normalize_album_name("Album (deluxe version)") == "Album"

    def test_deluxe_edition_stripped(self, service):
        """(Deluxe Edition) suffix should be stripped."""
        assert service._normalize_album_name("Album (Deluxe Edition)") == "Album"

    def test_deluxe_only_stripped(self, service):
        """(Deluxe) suffix should be stripped."""
        assert service._normalize_album_name("Album (Deluxe)") == "Album"

    def test_special_edition_stripped(self, service):
        """(Special Edition) suffix should be stripped."""
        assert service._normalize_album_name("Album (Special Edition)") == "Album"

    def test_expanded_edition_stripped(self, service):
        """(Expanded Edition) suffix should be stripped."""
        assert service._normalize_album_name("Album (Expanded Edition)") == "Album"

    def test_remastered_stripped(self, service):
        """(Remastered) suffix should be stripped."""
        assert service._normalize_album_name("Abbey Road (Remastered)") == "Abbey Road"
        assert service._normalize_album_name("Album (Remaster)") == "Album"

    def test_bonus_tracks_stripped(self, service):
        """(Bonus Tracks) suffix should be stripped."""
        assert service._normalize_album_name("Album (Bonus Tracks)") == "Album"
        assert service._normalize_album_name("Album (Bonus Track)") == "Album"

    def test_single_suffix_stripped(self, service):
        """- Single suffix should be stripped."""
        assert service._normalize_album_name("Reds - Single") == "Reds"
        assert service._normalize_album_name("Track - single") == "Track"

    def test_ep_suffix_stripped(self, service):
        """- EP suffix should be stripped."""
        assert service._normalize_album_name("Album - EP") == "Album"
        assert service._normalize_album_name("Mini Album - ep") == "Mini Album"

    def test_weird_formatting(self, service):
        """Handle weird formatting like extra dots/spaces."""
        assert service._normalize_album_name("Hozier .( DeLuxe Version )") == "Hozier"

    def test_empty_result_returns_original(self, service):
        """If normalization would result in empty string, return original."""
        # This shouldn't happen in practice, but test the edge case
        result = service._normalize_album_name("(Deluxe Version)")
        assert result == "(Deluxe Version)"  # Returns original since result would be empty


class TestNamesMatch:
    """Tests for _names_match() method."""

    @pytest.fixture
    def service(self):
        """Create a TheAudioDBService instance."""
        return TheAudioDBService(storage=None)

    def test_exact_match(self, service):
        """Exact match should return True."""
        assert service._names_match("Hozier", "Hozier") is True

    def test_case_insensitive(self, service):
        """Matching should be case-insensitive."""
        assert service._names_match("HOZIER", "hozier") is True
        assert service._names_match("Hozier", "HOZIER") is True

    def test_punctuation_ignored(self, service):
        """Punctuation should be ignored."""
        assert service._names_match("B.O.B", "BOB") is True
        assert service._names_match("AC/DC", "ACDC") is True

    def test_substring_match(self, service):
        """Substring match should return True."""
        assert service._names_match("Bob", "B.o.B") is True

    def test_completely_different(self, service):
        """Completely different names should return False."""
        assert service._names_match("Hozier", "Taylor Swift") is False
        assert service._names_match("ABC", "XYZ") is False

    def test_short_strings(self, service):
        """Short strings (< 3 chars) should only match if exactly equal."""
        assert service._names_match("AB", "AB") is True
        # Short strings don't do substring matching
