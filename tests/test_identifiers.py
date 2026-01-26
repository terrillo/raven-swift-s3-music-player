"""Unit tests for backend/utils/identifiers.py."""

import sys
from pathlib import Path

import pytest

# Add parent dir to path so backend is importable as a package
sys.path.insert(0, str(Path(__file__).parent.parent))

from backend.utils.identifiers import (
    extract_year,
    get_artist_grouping_key,
    normalize_artist_name,
    sanitize_s3_key,
)


class TestExtractYear:
    """Tests for extract_year() function."""

    def test_integer_year(self):
        """Integer year should be returned as-is."""
        assert extract_year(2024) == 2024
        assert extract_year(1990) == 1990

    def test_string_year(self):
        """String year should be converted to integer."""
        assert extract_year("2024") == 2024
        assert extract_year("1990") == 1990

    def test_iso_date(self):
        """ISO date should extract year."""
        assert extract_year("2024-01-15") == 2024
        assert extract_year("1990-03-17") == 1990

    def test_partial_date(self):
        """Partial date (YYYY-MM) should extract year."""
        assert extract_year("2024-01") == 2024
        assert extract_year("1990-12") == 1990

    def test_none_input(self):
        """None input should return None."""
        assert extract_year(None) is None

    def test_empty_string(self):
        """Empty string should return None."""
        assert extract_year("") is None
        assert extract_year("   ") is None

    def test_invalid_string(self):
        """Invalid string should return None."""
        assert extract_year("not-a-date") is None
        assert extract_year("abc") is None


class TestSanitizeS3Key:
    """Tests for sanitize_s3_key() function."""

    def test_simple_name(self):
        """Simple alphanumeric name should pass through."""
        assert sanitize_s3_key("Hozier") == "Hozier"
        assert sanitize_s3_key("Album123") == "Album123"

    def test_spaces_to_dashes(self):
        """Spaces should be converted to dashes."""
        assert sanitize_s3_key("Take Me To Church") == "Take-Me-To-Church"
        assert sanitize_s3_key("Artist Name") == "Artist-Name"

    def test_underscores_to_dashes(self):
        """Underscores should be converted to dashes."""
        assert sanitize_s3_key("Track_Name") == "Track-Name"

    def test_special_characters_removed(self):
        """Special characters should be removed."""
        assert sanitize_s3_key("AC/DC") == "ACDC"
        assert sanitize_s3_key("Guns N' Roses") == "Guns-N-Roses"
        assert sanitize_s3_key("P!nk") == "Pnk"

    def test_parentheses_removed(self):
        """Parentheses and content should be handled."""
        assert sanitize_s3_key("Hozier (Deluxe)") == "Hozier-Deluxe"

    def test_multiple_dashes_collapsed(self):
        """Multiple dashes should collapse to single dash."""
        assert sanitize_s3_key("Artist - Album") == "Artist-Album"
        assert sanitize_s3_key("A--B---C") == "A-B-C"

    def test_leading_trailing_dashes_trimmed(self):
        """Leading and trailing dashes should be trimmed."""
        assert sanitize_s3_key("-Artist-") == "Artist"
        assert sanitize_s3_key("  Artist  ") == "Artist"

    def test_empty_returns_fallback(self):
        """Empty input should return fallback."""
        assert sanitize_s3_key("") == "Unknown"
        assert sanitize_s3_key("", fallback="Default") == "Default"

    def test_only_special_chars_returns_fallback(self):
        """String with only special characters should return fallback."""
        assert sanitize_s3_key("!!!") == "Unknown"
        assert sanitize_s3_key("@#$%") == "Unknown"

    def test_unicode_characters_removed(self):
        """Unicode characters should be removed."""
        assert sanitize_s3_key("Björk") == "Bjrk"
        assert sanitize_s3_key("Café") == "Caf"

    def test_real_world_examples(self):
        """Test real-world album/artist names."""
        assert sanitize_s3_key("Hozier .( DeLuxe Version )") == "Hozier-DeLuxe-Version"
        assert sanitize_s3_key("Reds - Single") == "Reds-Single"
        assert sanitize_s3_key("Mikky Ekko") == "Mikky-Ekko"
        assert sanitize_s3_key("In A Week (Feat. Karen Cowley)") == "In-A-Week-Feat-Karen-Cowley"


class TestNormalizeArtistName:
    """Tests for normalize_artist_name() function."""

    def test_single_artist(self):
        """Single artist name should pass through unchanged."""
        assert normalize_artist_name("Afrojack") == "Afrojack"
        assert normalize_artist_name("Justin Timberlake") == "Justin Timberlake"

    def test_multi_artist_slash(self):
        """Multi-artist names with slash should extract first artist."""
        assert normalize_artist_name("Justin Timberlake/50 Cent") == "Justin Timberlake"
        assert normalize_artist_name("Artist1/Artist2/Artist3") == "Artist1"

    def test_whitespace_handling(self):
        """Whitespace around artists should be stripped."""
        assert normalize_artist_name("  Afrojack  ") == "Afrojack"
        assert normalize_artist_name(" Justin Timberlake / 50 Cent ") == "Justin Timberlake"

    def test_empty_string(self):
        """Empty string should return empty string."""
        assert normalize_artist_name("") == ""

    def test_none_input(self):
        """None input should return None."""
        assert normalize_artist_name(None) is None


class TestGetArtistGroupingKey:
    """Tests for get_artist_grouping_key() function."""

    def test_lowercase_conversion(self):
        """Artist names should be lowercased for grouping."""
        assert get_artist_grouping_key("Afrojack") == "afrojack"
        assert get_artist_grouping_key("AFROJACK") == "afrojack"
        assert get_artist_grouping_key("AfRoJaCk") == "afrojack"

    def test_multi_artist_normalized_and_lowercased(self):
        """Multi-artist names should be normalized then lowercased."""
        assert get_artist_grouping_key("Justin Timberlake/50 Cent") == "justin timberlake"
        assert get_artist_grouping_key("JUSTIN TIMBERLAKE/50 CENT") == "justin timberlake"

    def test_empty_string(self):
        """Empty string should return empty string."""
        assert get_artist_grouping_key("") == ""

    def test_case_insensitive_grouping(self):
        """Different casings of same artist should produce same key."""
        assert get_artist_grouping_key("Afrojack") == get_artist_grouping_key("afrojack")
        assert get_artist_grouping_key("The Beatles") == get_artist_grouping_key("THE BEATLES")
