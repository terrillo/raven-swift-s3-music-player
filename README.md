# raven-swift-s3-music-player

![macOS Screenshot](screenshots/macOS.png)

A full-stack music streaming app with an offline-first SwiftUI frontend and Python backend for S3-compatible storage.

![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20macOS%20%7C%20visionOS-blue)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange)
![Python](https://img.shields.io/badge/Python-3.8+-green)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

## Features

A complete music streaming solution that puts you in control: host your own library on S3-compatible storage, enrich it with metadata from multiple sources, and enjoy seamless offline playback across all your Apple devices.

### Frontend (iOS/macOS/visionOS App)

#### Playback
- Play, pause, skip forward/backward with smooth transitions
- Shuffle mode for randomized playback
- Repeat modes: off, repeat all, repeat one
- Queue management with up next display
- Seekable progress bar with time display
- Background audio playback continues when app is minimized
- System Now Playing integration (lock screen, Control Center, headphone controls)

#### Browsing & Discovery
- **Artists View**: Browse all artists with grid or list layout toggle
- **Albums View**: Browse all albums with grid or list layout toggle
- **Songs View**: Full track listing with cache status indicators
- **Genres View**: Browse by genre with drill-down to matching tracks
- **Auto-Playlists**: Top 100 tracks by play count
- Artist detail pages with bio, albums, and track listings
- Album detail pages with artwork, track listing, and metadata

#### Offline & Caching
- Download entire library for fully offline playback
- Per-track download progress with cancel option
- Cascading artwork caching (automatically downloads artist and album images)
- Cache size display and one-tap clear option
- Offline mode banner shows last catalog update time
- Cached tracks indicated with visual status icons
- Non-cached tracks appear dimmed and disabled

#### Search
- Global search across artists, albums, and songs
- Real-time results as you type

#### Statistics & Analytics
- Play count tracking per track
- CloudKit sync for statistics across devices
- Listening time and unique tracks played
- Top Artists chart with play counts
- Top Genres chart with listening breakdown
- Time period filters: week, month, all time

#### Now Playing Experience
- **Full-screen sheet**: Large artwork, playback controls, progress slider
- **iOS tab bar accessory**: Compact mini-player (iOS 18+)
- **macOS/iPadOS sidebar**: Persistent player card in navigation sidebar

#### Platform-Specific
- **iOS**: Tab-based navigation, iOS 18 tab bar accessories
- **macOS**: NavigationSplitView with three-column layout, sidebar player
- **visionOS**: Spatial computing support
- View mode preferences (grid/list) persist via `@AppStorage`

### Backend (Python Upload & Metadata)

#### Audio Format Support
- Supported formats: MP3, M4A, FLAC, WAV, AAC
- Automatic conversion to M4A (256kbps AAC) via ffmpeg
- Lossless FLAC files converted while preserving quality
- Embedded artwork extraction from audio file tags

#### Metadata Enrichment
- **TheAudioDB**: Artist bios, images, genres, styles, moods
- **MusicBrainz**: Accurate artist/album identification via MBIDs
- **Last.fm**: Fallback for album artwork and wiki when TheAudioDB lacks data
- Album name correction to canonical names (e.g., "Hozier-DeLuxe-Version" → "Hozier")
- Rich metadata fields: genre, style, mood, theme at artist, album, and track levels

#### Upload & Catalog Generation
- Parallel uploads with configurable worker count
- Retry logic with exponential backoff for reliability
- UUID-based filenames for artwork (prevents conflicts)
- Hierarchical JSON catalog with streaming URLs
- S3-compatible storage (DigitalOcean Spaces, AWS S3, MinIO, Cloudflare R2)
- Dry-run mode for testing without uploading
- Verbose output for debugging

## Prerequisites

- **Python 3.8+** with pip
- **ffmpeg** (for audio conversion)
- **Xcode 15+** (for iOS/macOS app)
- **S3-compatible storage** (DigitalOcean Spaces, AWS S3, MinIO, etc.)
- **Optional API keys**: TheAudioDB (free), MusicBrainz contact email, Last.fm

## Getting Started

### Backend Setup

1. **Clone the repository**
   ```bash
   git clone https://github.com/yourusername/raven-swift-s3-music-player.git
   cd raven-swift-s3-music-player
   ```

2. **Create `.env` file in `backend/`**
   ```env
   # Required
   DO_SPACES_KEY=your_access_key
   DO_SPACES_SECRET=your_secret_key
   DO_SPACES_BUCKET=your_bucket_name

   # Optional
   DO_SPACES_REGION=nyc3
   DO_SPACES_PREFIX=music
   MUSICBRAINZ_CONTACT=your@email.com
   MUSICBRAINZ_ENABLED=true
   LASTFM_API_KEY=your_lastfm_key
   LASTFM_ENABLED=true
   ```

3. **Install dependencies**
   ```bash
   cd backend
   pip install -r requirements.txt
   ```

4. **Organize your music**
   ```
   music/
   ├── Artist Name/
   │   ├── Album Name/
   │   │   ├── 01 - Track.mp3
   │   │   ├── 02 - Track.flac
   │   │   └── ...
   ```

5. **Run the uploader**
   ```bash
   python main.py
   ```

### Frontend Setup

1. **Open the Xcode project**
   ```bash
   open frontend/Music.xcodeproj
   ```

2. **Update the CDN URL** in `frontend/Music/Services/MusicService.swift`:
   ```swift
   private let catalogBaseURL = "https://YOUR_BUCKET.YOUR_REGION.cdn.digitaloceanspaces.com/music/music_catalog.json"
   ```

3. **Build and run** on simulator or device (Cmd+R)

4. **Optional: iCloud sync** - For syncing listening statistics across devices, see [iCloud Setup Guide](docs/icloud-setup.md)

## Configuration

### Required Environment Variables

| Variable | Description |
|----------|-------------|
| `DO_SPACES_KEY` | S3 access key |
| `DO_SPACES_SECRET` | S3 secret key |
| `DO_SPACES_BUCKET` | Bucket name |

### Optional Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DO_SPACES_REGION` | `nyc3` | S3 region (nyc3, sfo3, ams3, sgp1, fra1, syd1, blr1) |
| `DO_SPACES_ENDPOINT` | Auto | Custom S3 endpoint URL |
| `DO_SPACES_PREFIX` | `music` | S3 path prefix for all files |
| `MUSICBRAINZ_CONTACT` | - | Contact email for better rate limits |
| `MUSICBRAINZ_ENABLED` | `true` | Enable MusicBrainz lookups |
| `LASTFM_API_KEY` | - | Last.fm API key for fallback metadata |
| `LASTFM_ENABLED` | `true` | Enable Last.fm fallback |

## CLI Usage

```bash
# Standard upload
python backend/main.py

# Dry run (scan only, no uploads)
python backend/main.py --dry-run

# Verbose output
python backend/main.py --verbose

# Custom parallel workers
python backend/main.py --workers 8

# Combine options
python backend/main.py --dry-run --verbose
```

## Project Structure

```
raven-swift-s3-music-player/
├── backend/
│   ├── main.py                 # Entry point with MusicUploader orchestrator
│   ├── config.py               # Configuration and environment loading
│   ├── upload_music.py         # Backwards-compatible wrapper
│   ├── services/
│   │   ├── storage.py          # S3/Spaces uploads
│   │   ├── theaudiodb.py       # TheAudioDB API
│   │   ├── musicbrainz.py      # MusicBrainz MBID lookups
│   │   └── lastfm.py           # Last.fm fallback
│   ├── extractors/
│   │   ├── metadata.py         # Audio tag extraction
│   │   └── artwork.py          # Embedded artwork extraction
│   ├── processors/
│   │   ├── audio.py            # File scanning, ffmpeg conversion
│   │   └── catalog.py          # Catalog JSON generation
│   ├── models/
│   │   ├── track.py            # TrackMetadata dataclass
│   │   └── catalog.py          # Catalog dataclasses
│   └── utils/
│       ├── cache.py            # Thread-safe caching
│       └── identifiers.py      # S3 key sanitization
├── frontend/
│   └── Music/
│       ├── Models/
│       │   ├── MusicCatalog.swift    # Codable models
│       │   └── CacheModels.swift     # SwiftData cache models
│       ├── Services/
│       │   ├── MusicService.swift    # Catalog fetching
│       │   ├── PlayerService.swift   # Audio playback
│       │   ├── CacheService.swift    # Offline caching
│       │   └── StatisticsService.swift
│       └── Views/
│           ├── ContentView.swift
│           ├── ArtistsView.swift
│           ├── AlbumsView.swift
│           ├── SongsView.swift
│           ├── NowPlayingSheet.swift
│           └── SettingsView.swift
├── music/                      # Your music library (Artist/Album/Track)
├── tests/                      # Backend test suite
└── CLAUDE.md                   # Development instructions
```

## API Integrations

| Service | Purpose | Rate Limit |
|---------|---------|------------|
| **TheAudioDB** | Artist bios, images, album metadata | Free tier available |
| **MusicBrainz** | Accurate MBIDs for lookups | 1 req/sec (contact email improves limits) |
| **Last.fm** | Fallback album artwork and wiki | API key required |

## Testing

```bash
cd backend

# Generate catalog first (required for integration tests)
python main.py --dry-run

# Run all tests
python -m pytest tests/ -v

# Run with coverage
python -m pytest tests/ -v --cov=backend

# Run specific test file
python -m pytest tests/test_catalog.py -v
```

## Catalog JSON Structure

The backend generates a `music_catalog.json` file with this structure:

```json
{
  "generated_at": "2024-01-15T10:30:00Z",
  "total_tracks": 150,
  "artists": [
    {
      "name": "Artist Name",
      "bio": "Artist biography...",
      "image_url": "https://cdn.example.com/artist.jpg",
      "genre": "Alternative Rock",
      "albums": [
        {
          "name": "Album Name",
          "image_url": "https://cdn.example.com/album.jpg",
          "release_date": 2020,
          "tracks": [
            {
              "title": "Track Title",
              "artist": "Artist Name",
              "album": "Album Name",
              "track_number": 1,
              "duration": 245,
              "format": "m4a",
              "url": "https://cdn.example.com/music/Artist/Album/Track.m4a",
              "s3_key": "Artist/Album/Track.m4a"
            }
          ]
        }
      ]
    }
  ]
}
```

## Screenshots

<!-- Add your screenshots here -->

| iOS | macOS |
|-----|-------|
| ![iOS Screenshot](screenshots/iOS.png) | ![macOS Screenshot](screenshots/macOS.png) |

![macOS Screenshot](screenshots/macOS-2.png)
![macOS Screenshot](screenshots/macOS-3.png)
![macOS Screenshot](screenshots/macOS-4.png)

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [TheAudioDB](https://www.theaudiodb.com/) for artist and album metadata
- [MusicBrainz](https://musicbrainz.org/) for accurate music identification
- [Last.fm](https://www.last.fm/) for fallback metadata
- [mutagen](https://mutagen.readthedocs.io/) for audio tag extraction
