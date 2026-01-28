# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Music app with a SwiftUI iOS/macOS frontend and Python backend for uploading music to DigitalOcean Spaces. The app supports **offline playback only** - tracks must be cached locally before they can be played.

## Build Commands

### iOS/macOS Frontend
```bash
# Build from command line
xcodebuild -project frontend/Music.xcodeproj -scheme Music -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run tests
xcodebuild -project frontend/Music.xcodeproj -scheme Music -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Alternatively, open `frontend/Music.xcodeproj` in Xcode and use Cmd+B to build, Cmd+R to run.

### Backend (Python)
```bash
cd backend
pip install -r requirements.txt
python upload_music.py              # Backwards-compatible
python -m backend.main              # Package-style (from parent dir)
python upload_music.py --dry-run    # Scan only, no uploads
python upload_music.py --verbose    # Verbose output
python upload_music.py --workers 8  # Custom parallel workers
```

Required `.env` file in `backend/`:
```
DO_SPACES_KEY=your_key
DO_SPACES_SECRET=your_secret
DO_SPACES_BUCKET=your_bucket
DO_SPACES_REGION=sfo3
DO_SPACES_PREFIX=music              # Optional, S3 path prefix (default: music)
MUSICBRAINZ_CONTACT=your@email.com  # Optional, for better rate limit tolerance
MUSICBRAINZ_ENABLED=true            # Optional, default true
LASTFM_API_KEY=your_key             # Optional, fallback for album metadata
```

### Backend Tests
```bash
# Generate catalog first (required for integration tests)
cd backend && python upload_music.py --dry-run

# Run all tests
python -m pytest tests/ -v

# Run specific test file
python -m pytest tests/test_catalog.py -v

# Run with coverage
python -m pytest tests/ -v --cov=backend
```

**Test Files:**
- `tests/test_catalog.py` - Integration tests comparing generated catalog against expected fixtures
- `tests/test_conversion.py` - Integration tests for FLAC to M4A conversion (uses Santana album)
- `tests/1-hozier-test.json` - Fixture for TheAudioDB album name correction
- `tests/2-mikko-test.json` - Fixture for Last.fm fallback
- `tests/test_identifiers.py` - Unit tests for S3 key sanitization
- `tests/test_theaudiodb.py` - Unit tests for album name normalization
- `tests/test_lastfm.py` - Unit tests for Last.fm helpers

## Architecture

### Frontend (`frontend/Music/`)

**Models/**
- `MusicCatalog.swift` - Codable models: `MusicCatalog`, `Artist`, `Album`, `Track`
- `CacheModels.swift` - SwiftData models: `CachedTrack`, `CachedArtwork`, `CachedCatalog` for offline storage tracking

**Services/**
- `MusicService.swift` - Fetches catalog JSON from CDN (with cache-busting timestamp), provides artists/albums/songs arrays, supports offline catalog caching
- `PlayerService.swift` - Audio playback with AVPlayer, system Now Playing integration, queue management, session tracking for smart shuffle
- `CacheService.swift` - Downloads and caches music/artwork for offline playback using SwiftData, cascading artwork caching for artists/albums
- `ShuffleService.swift` - Weighted random track selection with 9 intelligence factors for smart shuffle
- `AnalyticsStore.swift` - Core Data + CloudKit analytics with play counts, skip tracking, completion rates, and time-of-day preferences

**Views/**
- `ContentView.swift` - Main view with TabView (iOS) or NavigationSplitView (macOS), offline mode banner
- `ArtistsView.swift` - Artist list with grid/list toggle, `ArtistDetailView`, `AlbumDetailView`, `ArtworkImage`, `ArtistGridCard`, `AlbumGridCard`, `ViewMode` enum
- `AlbumsView.swift` - Album list with grid/list toggle and navigation to detail
- `SongsView.swift` - All songs list with `SongRow` component (shows cache status)
- `NowPlayingAccessory.swift` - iOS 18 tab bar accessory (compact player)
- `NowPlayingSheet.swift` - Full-screen player with seekable progress slider
- `SidebarNowPlaying.swift` - macOS/iPadOS sidebar player card
- `SettingsView.swift` - Cache management (download all, clear cache, cache size)
- `CacheDownloadView.swift` - Modal with per-track download progress, passes catalog for cascading artwork
- `PlaylistView.swift`, `SearchView.swift` - Placeholder views

**Key Patterns:**
- Uses `@Observable` macro for services (requires iOS 17+)
- Uses SwiftData for cache tracking (requires iOS 17+)
- Platform-specific code wrapped in `#if os(iOS)` / `#if os(macOS)`
- `ArtworkImage` component handles async image loading with local cache fallback
- Tab bar uses `.tabViewBottomAccessory` for Now Playing (iOS 18+)
- macOS sidebar uses `.safeAreaInset(edge: .bottom)` for Now Playing
- `@AppStorage` for persisting view mode preferences (grid/list)
- `ViewMode` enum with segmented picker for toggling between grid and list layouts

**Playback Behavior:**
- **Cached-only mode**: Tracks must be downloaded before they can be played
- Non-cached tracks appear dimmed (50% opacity) and are disabled
- System Now Playing integration: lock screen, Control Center, headphone controls
- Background audio playback supported

**Smart Shuffle:**
The shuffle system uses weighted random selection with 9 intelligence factors:

1. **Base weight by play count** - Unplayed tracks weighted higher (10.0) than frequently played (3.0)
2. **Skip penalty** - Exponential decay (0.3^n) for skipped tracks, extra penalty for recent skips
3. **Artist diversity** - Penalizes same artist in last 5 tracks to avoid clustering
4. **Album spread** - Penalizes tracks from recently played albums
5. **Session memory** - Strongly penalizes (90%) tracks already played this session
6. **Rediscovery boost** - 50% boost for tracks not played in 30+ days
7. **Genre continuity** - 50% boost for matching genre with current track
8. **Mood continuity** - 30% boost for matching mood with current track
9. **Time-of-day preferences** - Up to 20% boost for tracks frequently played at current time period (morning/afternoon/evening/night)

Key files:
- `ShuffleService.swift` - Weight calculation with `ShuffleContext` struct
- `PlayerService.swift` - Session tracking (`sessionPlayedKeys`, `recentArtists`, `recentAlbums`)
- `AnalyticsStore.swift` - Query methods: `fetchLastPlayDates()`, `fetchCompletionRates()`, `fetchTimeOfDayPreferences()`
- `MusicDB.xcdatamodeld` - `PlayEventEntity` includes `completionRate` attribute

### Backend (`backend/`)

The backend is organized as a Python package with clear separation of concerns:

```
backend/
├── main.py                 # Entry point with MusicUploader orchestrator
├── config.py               # Configuration classes, env loading, constants
├── upload_music.py         # Backwards-compatible wrapper script
├── services/
│   ├── storage.py          # StorageService - S3/Spaces uploads
│   ├── theaudiodb.py       # TheAudioDBService - TheAudioDB API integration
│   ├── musicbrainz.py      # MusicBrainzService - MBID lookups for accuracy
│   └── lastfm.py           # LastFMService - Last.fm API fallback for album metadata
├── extractors/
│   ├── metadata.py         # MetadataExtractor - audio tag extraction
│   └── artwork.py          # ArtworkExtractor - embedded artwork extraction
├── processors/
│   ├── audio.py            # AudioProcessor - file scanning, ffmpeg conversion
│   └── catalog.py          # CatalogBuilder - catalog JSON generation
├── models/
│   ├── track.py            # TrackMetadata dataclass
│   └── catalog.py          # Artist, Album, Catalog, ArtistInfo, AlbumInfo, TrackInfo dataclasses
└── utils/
    ├── cache.py            # ThreadSafeCache generic class
    └── identifiers.py      # S3 key sanitization, year extraction utilities
```

**Key Classes:**
- `MusicUploader` (main.py) - Orchestrates the upload workflow
- `StorageService` - DigitalOcean Spaces interactions with retry logic
- `TheAudioDBService` - TheAudioDB API for artist bio/images, album metadata (thread-safe caching)
- `MusicBrainzService` - Fetches MBIDs for accurate lookups
- `LastFMService` - Last.fm API fallback for album artwork and wiki when TheAudioDB has no data
- `MetadataExtractor` - Extracts tags from MP3/M4A/FLAC using mutagen
- `ArtworkExtractor` - Extracts embedded album art (APIC/covr/Picture)
- `AudioProcessor` - Scans directories, converts to m4a via ffmpeg
- `CatalogBuilder` - Builds hierarchical JSON from tracks

**Features:**
- Scans `music/` directory for audio files (mp3, m4a, flac, wav, aac)
- Extracts metadata using mutagen (title, artist, album, track number, duration)
- Extracts embedded album art from audio files
- Uses MusicBrainz IDs (MBIDs) for accurate TheAudioDB API lookups
- **Artist images from TheAudioDB** (strArtistThumb, strArtistFanart)
- **Album artwork from TheAudioDB** (strAlbumThumb) with embedded art as fallback
- Fetches bio, genre, style, mood from TheAudioDB API
- **Rich metadata fields**: Separate genre, style, mood, theme fields for artists, albums, and tracks
- **Name correction**: Uses TheAudioDB/MusicBrainz canonical names
- Uploads files and artwork to DigitalOcean Spaces with UUID-based filenames
- Generates `music_catalog.json` with streaming URLs
- Retry logic with exponential backoff for large file uploads
- Optimized transfer config for multipart uploads (FLAC files can be 50MB+)
- CLI arguments: `--dry-run`, `--verbose`, `--workers N`
- **Last.fm fallback**: When TheAudioDB has no album data, Last.fm is used as fallback for album artwork and wiki
- Album folders are uploaded to match the TheAudioDB album name

**Critical: s3_key Must Use Corrected Album Name**

The `s3_key` in the catalog JSON must use the **corrected album name from TheAudioDB**, not the local folder name. This is essential for the frontend to find files correctly.

Example:
- Local folder: `Hozier/Hozier-DeLuxe-Version/Take-Me-To-Church.mp3`
- TheAudioDB returns album name: `Hozier`
- Correct s3_key: `Hozier/Hozier/Take-Me-To-Church.mp3`
- Wrong s3_key: `Hozier/Hozier-DeLuxe-Version/Take-Me-To-Church.mp3`

The `CatalogBuilder._build_album()` method handles this by updating the s3_key when `display_album_name != album_name`. Do not break this behavior.

**Catalog JSON Structure:**
```json
{
  "artists": [{
    "name": "Artist Name",
    "bio": "Artist biography...",
    "image_url": "https://...",
    "genre": "Alternative Rock",
    "style": "Rock/Pop",
    "mood": "Happy",
    "artist_type": "Group",
    "area": "United States",
    "begin_date": "1990-01-15",
    "end_date": null,
    "disambiguation": "American rock band",
    "albums": [{
      "name": "Album Name",
      "image_url": "https://...",
      "wiki": "Album description...",
      "release_date": 2020,
      "genre": "Pop-Rock",
      "style": "Rock/Pop",
      "mood": "Relaxed",
      "theme": "In Love",
      "release_type": "Album",
      "country": "US",
      "label": "Record Label",
      "tracks": [{
        "title": "Song",
        "artist": "Artist",
        "album": "Album",
        "track_number": 1,
        "duration": 180,
        "format": "flac",
        "s3_key": "Artist/Album/Song.flac",
        "url": "https://...",
        "embedded_artwork_url": "https://...",
        "genre": "Pop-Rock",
        "style": "Rock/Pop",
        "mood": "Relaxed",
        "theme": "In Love"
      }]
    }]
  }]
}
```

### Music Files (`music/`)
- Local music library organized as `Artist/Album/Track.mp3|m4a|flac`
- Supported formats: mp3, m4a, flac, wav, aac

## CDN URL
Catalog is served from: `https://terrillo.sfo3.cdn.digitaloceanspaces.com/music/music_catalog.json`

## Cache Storage
- Location: `~/Documents/MusicCache/`
  - `tracks/` - Downloaded audio files (SHA256 hashed filenames)
  - `artwork/` - Downloaded artwork (SHA256 hashed filenames)
- Tracked via SwiftData (`CachedTrack`, `CachedArtwork`, `CachedCatalog` models)

## Offline Support
- **Catalog caching**: Catalog JSON is cached locally via `CachedCatalog` model for fully offline browsing
- **Cascading artwork**: When tracks are downloaded, related artist and album images are automatically cached
- **Offline banner**: Shows "Offline Mode" with last updated time when network is unavailable
- **View mode persistence**: Grid/list preferences saved via `@AppStorage` and persist across launches
