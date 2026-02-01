# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A unified Swift music app for iOS and macOS with integrated upload capabilities. The app supports **offline playback only** - tracks must be cached locally before they can be played. Music uploads are handled natively on macOS through a built-in upload interface.

**Cross-device sync**: Music catalog syncs automatically across devices via CDN. Upload music on macOS and it becomes available on iOS within seconds.

## Build Commands

```bash
# Build for iOS Simulator
xcodebuild -project frontend/Music.xcodeproj -scheme Music -destination 'platform=iOS Simulator,name=iPhone 16' build

# Build for macOS
xcodebuild -project frontend/Music.xcodeproj -scheme Music -destination 'platform=macOS' build

# Run tests
xcodebuild -project frontend/Music.xcodeproj -scheme Music -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Alternatively, open `frontend/Music.xcodeproj` in Xcode and use Cmd+B to build, Cmd+R to run.

## Architecture

### Directory Structure

```
frontend/Music/
├── Models/
│   ├── CatalogModels.swift       # SwiftData models: CatalogArtist, CatalogAlbum, CatalogTrack
│   ├── MusicCatalog.swift        # Codable DTOs: MusicCatalog, Artist, Album, Track
│   ├── CacheModels.swift         # SwiftData: CachedTrack, CachedArtwork
│   ├── NavigationDestination.swift
│   ├── PlaybackState.swift
│   └── ViewMode.swift
├── Services/
│   ├── MusicService.swift        # Catalog loading: SwiftData + CDN fetch
│   ├── PlayerService.swift       # AVPlayer, Now Playing, queue management
│   ├── CacheService.swift        # Track/artwork download and caching
│   ├── ShuffleService.swift      # Weighted random selection (9 factors)
│   ├── AnalyticsStore.swift      # Core Data + CloudKit play analytics
│   ├── FavoritesStore.swift      # Favorites management
│   ├── StatisticsService.swift   # Music statistics
│   └── Upload/                   # macOS-only upload services
│       ├── MusicUploader.swift           # Main orchestrator
│       ├── UploadConfiguration.swift     # Keychain credential storage
│       ├── StorageService.swift          # S3/DigitalOcean Spaces client
│       ├── MetadataExtractor.swift       # AVFoundation tag extraction
│       ├── ArtworkExtractor.swift        # Embedded artwork extraction
│       ├── AudioConverter.swift          # FLAC→M4A via ffmpeg
│       ├── CatalogBuilder.swift          # Catalog JSON generation
│       ├── Identifiers.swift             # S3 key sanitization
│       ├── MusicBrainzService.swift      # MBID lookups
│       ├── TheAudioDBService.swift       # Artist/album metadata
│       └── LastFMService.swift           # Album metadata fallback
├── Views/
│   ├── ContentView.swift                 # TabView (iOS) / NavigationSplitView (macOS)
│   ├── ArtistsView.swift                 # Artist list, ArtistDetailView, AlbumDetailView
│   ├── AlbumsView.swift                  # Album browsing
│   ├── SongsView.swift                   # All songs with SongRow
│   ├── GenreView.swift                   # Genre browsing
│   ├── SearchView.swift                  # Global search
│   ├── PlaylistView.swift                # Auto-generated playlists
│   ├── NowPlayingSheet.swift             # Full-screen player
│   ├── NowPlayingAccessory.swift         # iOS 18 tab bar mini-player
│   ├── SidebarNowPlaying.swift           # macOS sidebar player
│   ├── QueueListView.swift               # Queue display
│   ├── CacheDownloadView.swift           # Download progress
│   ├── SettingsView.swift                # Settings & cache management
│   ├── StatisticsView.swift              # Play statistics
│   └── UploadView.swift                  # macOS-only upload interface
├── Extensions/
│   ├── Image+DominantColor.swift
│   └── Color+AppAccent.swift
├── MusicApp.swift                        # App entry with SwiftData container
└── MusicDB.xcdatamodeld                  # Core Data schema (analytics)
```

### Data Models

**SwiftData Catalog Models** (`CatalogModels.swift`):
```swift
@Model class CatalogArtist    // Persistent artist with albums relationship
@Model class CatalogAlbum     // Persistent album with tracks relationship
@Model class CatalogTrack     // Persistent track (s3Key is unique identifier)
@Model class CatalogMetadata  // Catalog sync metadata
```

**Codable DTOs** (`MusicCatalog.swift`):
```swift
struct MusicCatalog, Artist, Album, Track  // For JSON serialization
```

**Cache Tracking** (`CacheModels.swift`):
```swift
@Model class CachedTrack      // Downloaded audio file reference
@Model class CachedArtwork    // Downloaded artwork reference
```

### Services

**MusicService** - Loads catalog from SwiftData, fetches from CDN if local database is empty. Syncs iCloud Key-Value settings on each load to discover CDN configuration set by macOS uploader.

**PlayerService** - AVPlayer-based playback with system Now Playing integration, queue management, and session tracking for smart shuffle.

**CacheService** - Downloads tracks and artwork to `~/Documents/MusicCache/`, tracks downloads via SwiftData.

**ShuffleService** - Weighted random selection with 9 intelligence factors:
1. Base weight by play count
2. Skip penalty (exponential decay)
3. Artist diversity (avoids clustering)
4. Album spread
5. Session memory (90% penalty for played tracks)
6. Rediscovery boost (50% for 30+ day old tracks)
7. Genre continuity (50% boost)
8. Mood continuity (30% boost)
9. Time-of-day preferences (20% boost)

**AnalyticsStore** - Core Data + CloudKit for play counts, skip tracking, completion rates, and time preferences.

### Upload Services (macOS Only)

The `Services/Upload/` directory contains the complete upload pipeline:

**MusicUploader** - Orchestrates the upload workflow:
1. Scan folder for audio files
2. Extract metadata in parallel
3. Lookup corrections via TheAudioDB/MusicBrainz
4. Upload to S3 with AWS Signature V4
5. Build catalog and save to SwiftData
6. Upload `catalog.json` to CDN for cross-device sync
7. Save CDN settings to iCloud Key-Value store

**StorageService** - S3-compatible client for DigitalOcean Spaces with AWS Signature V4 authentication.

**MetadataExtractor** - Extracts tags from audio files using AVFoundation.

**ArtworkExtractor** - Extracts embedded album art from audio files.

**AudioConverter** - Converts FLAC to M4A using ffmpeg subprocess.

**CatalogBuilder** - Generates hierarchical catalog JSON from processed tracks.

**External API Services**:
- `TheAudioDBService` - Artist bios, images, album metadata
- `MusicBrainzService` - MBID lookups for accurate artist/album matching
- `LastFMService` - Fallback for album artwork and wiki

**UploadConfiguration** - Credentials stored securely in macOS Keychain:
- DigitalOcean Spaces: key, secret, bucket, region, prefix
- Optional: Last.fm API key, MusicBrainz contact email

### Key Patterns

- `@Observable` macro for services (iOS 17+)
- SwiftData for catalog and cache persistence (iOS 17+)
- Platform-specific code: `#if os(iOS)` / `#if os(macOS)`
- `@AppStorage` for view preferences (grid/list mode)
- Tab bar uses `.tabViewBottomAccessory` for Now Playing (iOS 18+)
- macOS sidebar uses `.safeAreaInset(edge: .bottom)` for Now Playing

### Playback Behavior

- **Cached-only mode**: Tracks must be downloaded before playback
- Non-cached tracks appear dimmed (50% opacity) and are disabled
- System Now Playing: lock screen, Control Center, headphone controls
- Background audio playback supported

## Cross-Device Sync

The app uses a CDN-based sync architecture that enables music uploaded on macOS to appear on iOS automatically.

### Architecture

```
┌─────────────┐     catalog.json      ┌─────────────┐
│   macOS     │ ──────────────────▶   │     CDN     │
│  Uploader   │                       │  (Spaces)   │
└─────────────┘                       └─────────────┘
       │                                     │
       │  iCloud Key-Value                   │  fetch catalog.json
       │  (cdnBaseURL, cdnPrefix)            │
       ▼                                     ▼
┌─────────────────────────────────────────────────┐
│                 iOS / macOS                     │
│              MusicService                       │
│  1. Sync iCloud settings                        │
│  2. Load from SwiftData                         │
│  3. If empty → fetch from CDN                   │
│  4. Save to SwiftData for offline access        │
└─────────────────────────────────────────────────┘
```

### iCloud Key-Value Storage

Settings synced via `NSUbiquitousKeyValueStore`:
- `cdnBaseURL` - CDN base URL (e.g., `https://bucket.region.cdn.digitaloceanspaces.com`)
- `cdnPrefix` - Path prefix (e.g., `music`)

These are set automatically when:
1. Uploading music on macOS (after catalog.json upload)
2. Saving upload settings on macOS

iOS reads these settings to construct the catalog URL: `{cdnBaseURL}/{cdnPrefix}/catalog.json`

### Sync Triggers

The catalog refreshes in these scenarios:

1. **App launch** - Syncs iCloud settings, loads from SwiftData, fetches from CDN if empty
2. **Foreground return** - `scenePhase` changes to `.active` triggers reload
3. **Manual refresh** - Refresh button in empty state or macOS sidebar
4. **After upload** - macOS immediately updates local SwiftData

### Settings (iOS)

The Settings view shows a "CDN Prefix" field that displays the current prefix synced from macOS. This is auto-synced and typically doesn't need manual changes. Users can override if needed (e.g., for multiple music libraries).

## Platform Features

| Feature | iOS | macOS |
|---------|-----|-------|
| Browse Music | Yes | Yes |
| Offline Playback | Yes | Yes |
| Cache Management | Yes | Yes |
| Smart Shuffle | Yes | Yes |
| Upload Music | No | Yes |
| Search | Yes | Yes |
| Favorites | Yes | Yes |
| Statistics | Yes | Yes |
| Catalog Sync | Receive | Send |

## Upload Workflow (macOS)

1. Open Upload tab in sidebar
2. Configure DigitalOcean Spaces credentials (stored in Keychain)
3. Select music folder to scan
4. Preview detected files (paginated table showing new vs existing)
5. Start upload:
   - New files are uploaded with metadata enrichment
   - `catalog.json` is uploaded to CDN
   - CDN settings are synced to iCloud
   - Catalog is saved to SwiftData (available immediately)

### Rebuild Catalog

When scanning a folder that has no new files to upload (all files already exist on remote), the upload preview shows a "Rebuild Catalog" button instead of "Start Upload". This:
- Rebuilds the catalog from existing remote files
- Re-uploads `catalog.json` to CDN
- Syncs settings to iCloud
- Useful after metadata corrections or when resetting the catalog

### Critical: s3_key Uses Corrected Album Name

The `s3_key` must use the **corrected album name from TheAudioDB**, not the local folder name.

Example:
- Local folder: `Hozier/Hozier-DeLuxe-Version/Take-Me-To-Church.mp3`
- TheAudioDB album name: `Hozier`
- Correct s3_key: `Hozier/Hozier/Take-Me-To-Church.mp3`

`CatalogBuilder` handles this correction automatically.

## Cache Storage

Location: `~/Documents/MusicCache/`
- `tracks/` - Downloaded audio files (SHA256 hashed filenames)
- `artwork/` - Downloaded artwork (SHA256 hashed filenames)

Tracked via SwiftData (`CachedTrack`, `CachedArtwork` models).

## CDN URL

Audio and artwork served from: `https://terrillo.sfo3.cdn.digitaloceanspaces.com/music/`

Default values in MusicService:
- `defaultCDNBase` = `https://terrillo.sfo3.cdn.digitaloceanspaces.com`
- `defaultCDNPrefix` = `music`

## Data Flow

```
macOS Upload:
[Audio Files] → MetadataExtractor → TheAudioDB/MusicBrainz → AudioConverter
     ↓
StorageService (S3 upload)
     ↓
CatalogBuilder → catalog.json → CDN upload
     ↓
SwiftData (local) + iCloud Key-Value (cdnBaseURL, cdnPrefix)

iOS/macOS Catalog Sync:
iCloud Key-Value → MusicService.syncCloudSettings()
     ↓
SwiftData (check if empty) → CDN fetch if empty
     ↓
catalog.json → SwiftData (save for offline)

iOS/macOS Playback:
SwiftData → MusicService → UI
     ↓
CacheService → Downloads tracks/artwork → Offline playback
     ↓
AnalyticsStore → Core Data + CloudKit
```

## Catalog JSON Structure

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
