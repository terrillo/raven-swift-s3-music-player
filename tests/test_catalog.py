"""Tests for catalog generation with album name correction and Last.fm fallback.

These tests compare the generated backend/music_catalog.json (from dry-run)
against expected fixtures to verify:
1. Album names use TheAudioDB corrected names (not local folder names)
2. s3_keys use corrected album names
3. Last.fm fallback provides album artwork when TheAudioDB doesn't have it
"""

import json
from pathlib import Path

import pytest


TESTS_DIR = Path(__file__).parent
ROOT_DIR = TESTS_DIR.parent
GENERATED_CATALOG = ROOT_DIR / "backend" / "music_catalog.json"


def find_artist(catalog: dict, artist_name: str) -> dict | None:
    """Find an artist by name in the catalog."""
    for artist in catalog.get("artists", []):
        if artist["name"] == artist_name:
            return artist
    return None


def find_album(artist: dict, album_name: str) -> dict | None:
    """Find an album by name in an artist's albums."""
    for album in artist.get("albums", []):
        if album["name"] == album_name:
            return album
    return None


class TestGeneratedCatalogHozier:
    """Test the generated catalog for Hozier album name correction.

    Local folder: "Hozier - Hozier ( DeLuxe Version 2014) NLToppers"
    Expected album name: "Hozier" (from TheAudioDB)
    Expected s3_key: "Hozier/Hozier/Track.mp3"
    """

    @pytest.fixture
    def generated_catalog(self):
        """Load the generated catalog from dry-run."""
        if not GENERATED_CATALOG.exists():
            pytest.skip(f"Generated catalog not found: {GENERATED_CATALOG}. Run 'cd backend && python upload_music.py --dry-run' first.")
        with open(GENERATED_CATALOG) as f:
            return json.load(f)

    @pytest.fixture
    def expected_catalog(self):
        """Load the expected Hozier fixture."""
        with open(TESTS_DIR / "1-hozier-test.json") as f:
            return json.load(f)

    def test_hozier_artist_exists(self, generated_catalog):
        """Hozier artist should exist in generated catalog."""
        artist = find_artist(generated_catalog, "Hozier")
        assert artist is not None, "Hozier artist not found in generated catalog"

    def test_hozier_album_name_corrected(self, generated_catalog, expected_catalog):
        """Album name should be 'Hozier', not local folder name."""
        artist = find_artist(generated_catalog, "Hozier")
        assert artist is not None

        expected_artist = expected_catalog["artists"][0]
        expected_album_name = expected_artist["albums"][0]["name"]

        album = find_album(artist, expected_album_name)
        assert album is not None, f"Album '{expected_album_name}' not found. Available albums: {[a['name'] for a in artist['albums']]}"

        # Verify no local folder artifacts in album name
        assert "DeLuxe" not in album["name"]
        assert "NLToppers" not in album["name"]

    def test_hozier_s3_keys_use_corrected_name(self, generated_catalog, expected_catalog):
        """s3_keys should use corrected album name, not local folder name."""
        artist = find_artist(generated_catalog, "Hozier")
        expected_album_name = expected_catalog["artists"][0]["albums"][0]["name"]
        album = find_album(artist, expected_album_name)

        assert album is not None

        for track in album["tracks"]:
            s3_key = track["s3_key"]

            # Should use corrected path
            assert s3_key.startswith("Hozier/Hozier/"), f"s3_key should start with 'Hozier/Hozier/', got: {s3_key}"

            # Should NOT contain local folder artifacts
            assert "DeLuxe" not in s3_key, f"s3_key contains 'DeLuxe': {s3_key}"
            assert "NLToppers" not in s3_key, f"s3_key contains 'NLToppers': {s3_key}"

    def test_hozier_track_album_field_corrected(self, generated_catalog, expected_catalog):
        """Track album field should be corrected."""
        artist = find_artist(generated_catalog, "Hozier")
        expected_album_name = expected_catalog["artists"][0]["albums"][0]["name"]
        album = find_album(artist, expected_album_name)

        assert album is not None

        for track in album["tracks"]:
            assert track["album"] == expected_album_name, f"Track album should be '{expected_album_name}', got: {track['album']}"

    def test_hozier_track_count_matches(self, generated_catalog, expected_catalog):
        """Track count should match expected fixture."""
        artist = find_artist(generated_catalog, "Hozier")
        expected_artist = expected_catalog["artists"][0]
        expected_album = expected_artist["albums"][0]
        expected_album_name = expected_album["name"]

        album = find_album(artist, expected_album_name)
        assert album is not None

        expected_track_count = len(expected_album["tracks"])
        actual_track_count = len(album["tracks"])
        assert actual_track_count == expected_track_count, f"Expected {expected_track_count} tracks, got {actual_track_count}"


class TestGeneratedCatalogMikkyEkko:
    """Test the generated catalog for Mikky Ekko Last.fm fallback.

    Artist: "Mikky Ekko"
    Album: "Reds - Single" (not in TheAudioDB, should use Last.fm for image)
    """

    @pytest.fixture
    def generated_catalog(self):
        """Load the generated catalog from dry-run."""
        if not GENERATED_CATALOG.exists():
            pytest.skip(f"Generated catalog not found: {GENERATED_CATALOG}. Run 'cd backend && python upload_music.py --dry-run' first.")
        with open(GENERATED_CATALOG) as f:
            return json.load(f)

    @pytest.fixture
    def expected_catalog(self):
        """Load the expected Mikky Ekko fixture."""
        with open(TESTS_DIR / "2-mikko-test.json") as f:
            return json.load(f)

    def test_mikky_ekko_artist_exists(self, generated_catalog):
        """Mikky Ekko artist should exist in generated catalog."""
        artist = find_artist(generated_catalog, "Mikky Ekko")
        assert artist is not None, "Mikky Ekko artist not found in generated catalog"

    def test_mikky_ekko_album_name_correct(self, generated_catalog, expected_catalog):
        """Album name should be 'Reds - Single'."""
        artist = find_artist(generated_catalog, "Mikky Ekko")
        assert artist is not None

        expected_artist = expected_catalog["artists"][0]
        expected_album_name = expected_artist["albums"][0]["name"]

        album = find_album(artist, expected_album_name)
        assert album is not None, f"Album '{expected_album_name}' not found. Available albums: {[a['name'] for a in artist['albums']]}"

    def test_mikky_ekko_s3_keys_correct(self, generated_catalog, expected_catalog):
        """s3_keys should use sanitized artist/album names."""
        artist = find_artist(generated_catalog, "Mikky Ekko")
        expected_album_name = expected_catalog["artists"][0]["albums"][0]["name"]
        album = find_album(artist, expected_album_name)

        assert album is not None

        for track in album["tracks"]:
            s3_key = track["s3_key"]
            assert s3_key.startswith("Mikky-Ekko/Reds-Single/"), f"s3_key should start with 'Mikky-Ekko/Reds-Single/', got: {s3_key}"

    def test_mikky_ekko_track_album_field_correct(self, generated_catalog, expected_catalog):
        """Track album field should match expected."""
        artist = find_artist(generated_catalog, "Mikky Ekko")
        expected_album_name = expected_catalog["artists"][0]["albums"][0]["name"]
        album = find_album(artist, expected_album_name)

        assert album is not None

        for track in album["tracks"]:
            assert track["album"] == expected_album_name

    def test_mikky_ekko_track_count_matches(self, generated_catalog, expected_catalog):
        """Track count should match expected fixture."""
        artist = find_artist(generated_catalog, "Mikky Ekko")
        expected_artist = expected_catalog["artists"][0]
        expected_album = expected_artist["albums"][0]
        expected_album_name = expected_album["name"]

        album = find_album(artist, expected_album_name)
        assert album is not None

        expected_track_count = len(expected_album["tracks"])
        actual_track_count = len(album["tracks"])
        assert actual_track_count == expected_track_count, f"Expected {expected_track_count} tracks, got {actual_track_count}"


class TestEmbeddedArtworkUrl:
    """Test that all tracks have embedded artwork URLs."""

    @pytest.fixture
    def generated_catalog(self):
        """Load the generated catalog from dry-run."""
        if not GENERATED_CATALOG.exists():
            pytest.skip(f"Generated catalog not found at {GENERATED_CATALOG}. Run: cd backend && python upload_music.py --dry-run")
        with open(GENERATED_CATALOG) as f:
            return json.load(f)

    def test_all_tracks_have_embedded_artwork_url(self, generated_catalog):
        """Every track must have embedded_artwork_url set (not null)."""
        tracks_missing_artwork = []

        for artist in generated_catalog.get("artists", []):
            for album in artist.get("albums", []):
                for track in album.get("tracks", []):
                    if track.get("embedded_artwork_url") is None:
                        tracks_missing_artwork.append(
                            f"{artist['name']} - {album['name']} - {track['title']}"
                        )

        assert len(tracks_missing_artwork) == 0, (
            f"Found {len(tracks_missing_artwork)} tracks without embedded_artwork_url:\n"
            + "\n".join(tracks_missing_artwork[:10])
            + (f"\n... and {len(tracks_missing_artwork) - 10} more" if len(tracks_missing_artwork) > 10 else "")
        )


class TestNoDuplicateTracks:
    """Test that duplicate tracks are properly deduplicated.

    This handles cases where duplicate folders exist (e.g., "Album" and "Album copy")
    that get merged after TheAudioDB name correction.
    """

    @pytest.fixture
    def generated_catalog(self):
        """Load the generated catalog from dry-run."""
        if not GENERATED_CATALOG.exists():
            pytest.skip(f"Generated catalog not found: {GENERATED_CATALOG}")
        with open(GENERATED_CATALOG) as f:
            return json.load(f)

    def test_no_duplicate_s3_keys_in_album(self, generated_catalog):
        """Each album should have unique s3_keys (no duplicate tracks)."""
        duplicates_found = []

        for artist in generated_catalog.get("artists", []):
            for album in artist.get("albums", []):
                s3_keys = [t["s3_key"] for t in album.get("tracks", [])]
                seen = set()
                for key in s3_keys:
                    if key in seen:
                        duplicates_found.append(
                            f"{artist['name']} - {album['name']}: {key}"
                        )
                    seen.add(key)

        assert len(duplicates_found) == 0, (
            f"Found duplicate s3_keys:\n" + "\n".join(duplicates_found)
        )

    def test_no_duplicate_titles_in_album(self, generated_catalog):
        """Each album should have unique track titles."""
        duplicates_found = []

        for artist in generated_catalog.get("artists", []):
            for album in artist.get("albums", []):
                titles = [t["title"] for t in album.get("tracks", [])]
                seen = set()
                for title in titles:
                    if title in seen:
                        duplicates_found.append(
                            f"{artist['name']} - {album['name']}: {title}"
                        )
                    seen.add(title)

        assert len(duplicates_found) == 0, (
            f"Found duplicate titles:\n" + "\n".join(duplicates_found)
        )
