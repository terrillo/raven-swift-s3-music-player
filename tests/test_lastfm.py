"""Unit tests for backend/services/lastfm.py helper methods."""

import sys
from pathlib import Path

import pytest

# Add parent dir to path so backend is importable as a package
sys.path.insert(0, str(Path(__file__).parent.parent))

from backend.services.lastfm import LastFMService


class TestGetBestImage:
    """Tests for _get_best_image() method."""

    @pytest.fixture
    def service(self):
        """Create a LastFMService instance (no API key needed for helper tests)."""
        return LastFMService(api_key="")

    def test_empty_list(self, service):
        """Empty list should return None."""
        assert service._get_best_image([]) is None

    def test_mega_preferred(self, service):
        """Mega size should be preferred."""
        images = [
            {"size": "small", "#text": "https://small.jpg"},
            {"size": "mega", "#text": "https://mega.jpg"},
            {"size": "large", "#text": "https://large.jpg"},
        ]
        assert service._get_best_image(images) == "https://mega.jpg"

    def test_extralarge_second_choice(self, service):
        """Extralarge should be second choice if mega not available."""
        images = [
            {"size": "small", "#text": "https://small.jpg"},
            {"size": "extralarge", "#text": "https://extralarge.jpg"},
            {"size": "large", "#text": "https://large.jpg"},
        ]
        assert service._get_best_image(images) == "https://extralarge.jpg"

    def test_large_fallback(self, service):
        """Large should be used if mega/extralarge not available."""
        images = [
            {"size": "small", "#text": "https://small.jpg"},
            {"size": "medium", "#text": "https://medium.jpg"},
            {"size": "large", "#text": "https://large.jpg"},
        ]
        assert service._get_best_image(images) == "https://large.jpg"

    def test_small_last_resort(self, service):
        """Small should be used as last resort."""
        images = [
            {"size": "small", "#text": "https://small.jpg"},
        ]
        assert service._get_best_image(images) == "https://small.jpg"

    def test_empty_url_skipped(self, service):
        """Empty URL should be skipped."""
        images = [
            {"size": "mega", "#text": ""},
            {"size": "large", "#text": "https://large.jpg"},
        ]
        assert service._get_best_image(images) == "https://large.jpg"

    def test_missing_text_key(self, service):
        """Missing #text key should be handled."""
        images = [
            {"size": "mega"},
            {"size": "large", "#text": "https://large.jpg"},
        ]
        assert service._get_best_image(images) == "https://large.jpg"

    def test_all_empty_urls(self, service):
        """If all URLs are empty, return None."""
        images = [
            {"size": "mega", "#text": ""},
            {"size": "large", "#text": ""},
        ]
        assert service._get_best_image(images) is None


class TestCleanWikiText:
    """Tests for _clean_wiki_text() method."""

    @pytest.fixture
    def service(self):
        """Create a LastFMService instance."""
        return LastFMService(api_key="")

    def test_plain_text_unchanged(self, service):
        """Plain text should pass through unchanged."""
        text = "This is a simple description."
        assert service._clean_wiki_text(text) == "This is a simple description."

    def test_removes_anchor_tags(self, service):
        """Anchor tags should be removed."""
        text = 'Some text <a href="http://example.com">Read more</a> more text'
        assert service._clean_wiki_text(text) == "Some text more text"

    def test_removes_read_more_link(self, service):
        """Read more on Last.fm link should be removed."""
        text = 'Album description. <a href="https://www.last.fm/music/Artist">Read more on Last.fm</a>'
        assert service._clean_wiki_text(text) == "Album description."

    def test_removes_html_tags(self, service):
        """HTML tags should be removed."""
        text = "This is <b>bold</b> and <i>italic</i> text."
        assert service._clean_wiki_text(text) == "This is bold and italic text."

    def test_collapses_whitespace(self, service):
        """Multiple whitespace should collapse to single space."""
        text = "Text   with    multiple     spaces"
        assert service._clean_wiki_text(text) == "Text with multiple spaces"

    def test_handles_newlines(self, service):
        """Newlines should be converted to spaces."""
        text = "Line 1\nLine 2\nLine 3"
        assert service._clean_wiki_text(text) == "Line 1 Line 2 Line 3"

    def test_complex_html(self, service):
        """Complex HTML should be fully cleaned."""
        text = '<p>Paragraph 1</p> <p>Paragraph 2</p> <a href="link">Click</a>'
        assert service._clean_wiki_text(text) == "Paragraph 1 Paragraph 2"

    def test_strips_leading_trailing_whitespace(self, service):
        """Leading/trailing whitespace should be stripped."""
        text = "  Some text  "
        assert service._clean_wiki_text(text) == "Some text"
