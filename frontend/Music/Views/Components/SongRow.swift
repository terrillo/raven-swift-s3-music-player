//
//  SongRow.swift
//  Music
//

import SwiftUI

// MARK: - Configuration Enums

enum SongRowLeadingStyle {
    case artwork                           // 44px artwork with now-playing overlay
    case trackNumber                       // Track number or speaker icon
    case rankWithArtwork(rank: Int)        // Rank number + artwork
    case index(Int)                        // Simple index number
}

enum SongRowSubtitleStyle {
    case albumName                         // Show artist + album
    case relativeDate                      // Show artist + relative date
    case playCount(Int)                    // Show artist + play count
    case artistOnly                        // Just artist, no second line
}

// MARK: - SongRow View

struct SongRow: View {
    let track: Track

    // Configuration
    var leadingStyle: SongRowLeadingStyle = .artwork
    var subtitleStyle: SongRowSubtitleStyle = .albumName
    var showFavoriteButton: Bool = true
    var showDownloadIcon: Bool = true

    // Services
    var playerService: PlayerService
    var cacheService: CacheService?
    var musicService: MusicService?
    var isPlayable: Bool = true

    // Optional context (for artwork fallbacks)
    var albumImageUrl: String? = nil
    var artistImageUrl: String? = nil

    // Custom theming (for queue view)
    var accentColor: Color? = nil

    // Navigation callback for context menu
    var onNavigate: ((NavigationDestination) -> Void)? = nil

    // Callback for creating a new playlist with this track
    var onCreatePlaylist: ((Track) -> Void)? = nil

    // MARK: - Computed Properties

    private var isCurrentTrack: Bool {
        playerService.currentTrack?.id == track.id
    }

    private var isFavorite: Bool {
        FavoritesStore.shared.isTrackFavorite(track.s3Key)
    }

    private var isCached: Bool {
        cacheService?.isTrackCached(track) ?? isPlayable
    }

    /// Prefer album artwork over embedded artwork to reduce cache size
    /// Falls back to artist image if no album or embedded artwork exists
    private var preferredArtworkUrl: String? {
        albumImageUrl ?? track.embeddedArtworkUrl ?? artistImageUrl
    }

    private var localArtworkURL: URL? {
        guard let urlString = preferredArtworkUrl else { return nil }
        return cacheService?.localArtworkURL(for: urlString)
    }

    private var titleColor: Color {
        if let accentColor = accentColor {
            return accentColor.contrastingForeground
        }
        return isCurrentTrack ? Color.appAccent : (isPlayable ? .primary : .secondary)
    }

    private var secondaryColor: Color {
        if let accentColor = accentColor {
            return accentColor.contrastingSecondary
        }
        return .secondary
    }

    private var tertiaryColor: Color {
        if let accentColor = accentColor {
            return accentColor.labelTertiary
        }
        return .secondary
    }

    // Look up artist from musicService (O(1) via dictionary)
    private var artist: Artist? {
        guard let artistName = track.artist,
              let musicService = musicService else { return nil }
        return musicService.artistByName[artistName]
    }

    // Look up album from musicService (O(1) via dictionary)
    private var album: Album? {
        guard let albumName = track.album,
              let musicService = musicService else { return nil }
        return musicService.albumByName[albumName]
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 12) {
            leadingView
            infoView
            Spacer()
            trailingView
        }
        .opacity(isPlayable ? 1.0 : 0.5)
        .contextMenu { contextMenuContent }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuContent: some View {
        if let onNavigate = onNavigate {
            if let artist = artist {
                Button {
                    onNavigate(.artist(artist))
                } label: {
                    Label("Go to Artist", systemImage: "music.mic")
                }
            }

            if let album = album {
                Button {
                    onNavigate(.album(album, artist))
                } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }

            if artist != nil || album != nil {
                Divider()
            }
        }

        Button {
            FavoritesStore.shared.toggleTrackFavorite(track)
        } label: {
            Label(
                isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: isFavorite ? "heart.slash" : "heart"
            )
        }

        Divider()

        // Add to Playlist menu
        Menu {
            ForEach(PlaylistStore.shared.playlists, id: \.id) { playlist in
                Button {
                    PlaylistStore.shared.addTrack(track, to: playlist)
                } label: {
                    Label(playlist.name ?? "Untitled", systemImage: "music.note.list")
                }
            }

            if !PlaylistStore.shared.playlists.isEmpty {
                Divider()
            }

            Button {
                onCreatePlaylist?(track)
            } label: {
                Label("New Playlist...", systemImage: "plus")
            }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }
    }

    // MARK: - Leading View

    @ViewBuilder
    private var leadingView: some View {
        switch leadingStyle {
        case .artwork:
            artworkWithNowPlayingOverlay

        case .trackNumber:
            trackNumberView
                .frame(width: 30)

        case .rankWithArtwork(let rank):
            HStack(spacing: 8) {
                Text("\(rank)")
                    .font(.headline)
                    .foregroundStyle(isCurrentTrack ? Color.appAccent : secondaryColor)
                    .frame(width: 30)
                artworkWithNowPlayingOverlay
            }

        case .index(let index):
            Text("\(index)")
                .font(.caption)
                .foregroundStyle(secondaryColor)
                .frame(width: 24)
        }
    }

    @ViewBuilder
    private var artworkWithNowPlayingOverlay: some View {
        ZStack {
            ArtworkImage(
                url: preferredArtworkUrl,
                size: 44,
                systemImage: "music.note",
                localURL: localArtworkURL,
                cacheService: cacheService
            )

            if isCurrentTrack {
                Color.black.opacity(0.4)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Image(systemName: playerService.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 44, height: 44)
    }

    @ViewBuilder
    private var trackNumberView: some View {
        if isCurrentTrack {
            Image(systemName: playerService.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                .foregroundStyle(Color.appAccent)
        } else if let trackNumber = track.trackNumber {
            Text("\(trackNumber)")
                .foregroundStyle(isPlayable ? secondaryColor : Color.secondary.opacity(0.6))
        } else {
            Spacer()
        }
    }

    // MARK: - Info View

    @ViewBuilder
    private var infoView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.title)
                .font(leadingStyle.isQueue ? .body : .headline)
                .foregroundStyle(titleColor)
                .lineLimit(1)

            subtitleView
        }
    }

    @ViewBuilder
    private var subtitleView: some View {
        switch subtitleStyle {
        case .albumName:
            if let artist = track.artist {
                Text(artist)
                    .font(.caption)
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
            }
            if let album = track.album {
                Text(album)
                    .font(.caption)
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

        case .relativeDate:
            HStack(spacing: 4) {
                if let artist = track.artist {
                    Text(artist)
                }
                if let relativeDate = formattedRelativeDate, !relativeDate.isEmpty {
                    Text("•")
                    Text(relativeDate)
                }
            }
            .font(.caption)
            .foregroundStyle(secondaryColor)
            .lineLimit(1)

        case .playCount(let count):
            HStack(spacing: 4) {
                if let artist = track.artist {
                    Text(artist)
                }
                Text("•")
                Text("\(count) plays")
            }
            .font(.caption)
            .foregroundStyle(secondaryColor)
            .lineLimit(1)

        case .artistOnly:
            if let artist = track.artist {
                Text(artist)
                    .font(.caption)
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
            }
        }
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var formattedRelativeDate: String? {
        guard let addedAt = track.addedAt else { return nil }
        return Self.relativeDateFormatter.localizedString(for: addedAt, relativeTo: Date())
    }

    // MARK: - Trailing View

    @ViewBuilder
    private var trailingView: some View {
        if showFavoriteButton && accentColor == nil {
            Button {
                FavoritesStore.shared.toggleTrackFavorite(track)
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(isFavorite ? .pink : secondaryColor)
            }
            .buttonStyle(.plain)
        }

        if showDownloadIcon {
            if isCached {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(secondaryColor.opacity(0.5))
                    .font(.caption)
            } else {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(secondaryColor)
                    .font(.caption)
            }
        }

        Text(track.formattedDuration)
            .font(.caption)
            .foregroundStyle(tertiaryColor)
            .monospacedDigit()
    }
}

// MARK: - Leading Style Helpers

private extension SongRowLeadingStyle {
    var isQueue: Bool {
        if case .index = self { return true }
        return false
    }
}

// MARK: - Static Factory Methods

extension SongRow {
    /// Standard song list (SongsView, SearchView, FavoritesView)
    static func songs(
        track: Track,
        playerService: PlayerService,
        cacheService: CacheService?,
        musicService: MusicService? = nil,
        isPlayable: Bool = true,
        albumImageUrl: String? = nil,
        artistImageUrl: String? = nil,
        onNavigate: ((NavigationDestination) -> Void)? = nil,
        onCreatePlaylist: ((Track) -> Void)? = nil
    ) -> SongRow {
        SongRow(
            track: track,
            leadingStyle: .artwork,
            subtitleStyle: .albumName,
            showFavoriteButton: true,
            showDownloadIcon: true,
            playerService: playerService,
            cacheService: cacheService,
            musicService: musicService,
            isPlayable: isPlayable,
            albumImageUrl: albumImageUrl,
            artistImageUrl: artistImageUrl,
            onNavigate: onNavigate,
            onCreatePlaylist: onCreatePlaylist
        )
    }

    /// Album detail view
    static func albumTrack(
        track: Track,
        playerService: PlayerService,
        cacheService: CacheService? = nil,
        musicService: MusicService? = nil,
        isPlayable: Bool = true,
        onNavigate: ((NavigationDestination) -> Void)? = nil,
        onCreatePlaylist: ((Track) -> Void)? = nil
    ) -> SongRow {
        SongRow(
            track: track,
            leadingStyle: .trackNumber,
            subtitleStyle: .artistOnly,
            showFavoriteButton: true,
            showDownloadIcon: true,
            playerService: playerService,
            cacheService: cacheService,
            musicService: musicService,
            isPlayable: isPlayable,
            onNavigate: onNavigate,
            onCreatePlaylist: onCreatePlaylist
        )
    }

    /// Recently added playlist
    static func recentlyAdded(
        track: Track,
        playerService: PlayerService,
        cacheService: CacheService?,
        musicService: MusicService? = nil,
        isPlayable: Bool = true,
        onNavigate: ((NavigationDestination) -> Void)? = nil,
        onCreatePlaylist: ((Track) -> Void)? = nil
    ) -> SongRow {
        SongRow(
            track: track,
            leadingStyle: .artwork,
            subtitleStyle: .relativeDate,
            showFavoriteButton: true,
            showDownloadIcon: true,
            playerService: playerService,
            cacheService: cacheService,
            musicService: musicService,
            isPlayable: isPlayable,
            onNavigate: onNavigate,
            onCreatePlaylist: onCreatePlaylist
        )
    }

    /// Top 100 chart
    static func top100(
        track: Track,
        rank: Int,
        playCount: Int,
        playerService: PlayerService,
        cacheService: CacheService?,
        musicService: MusicService? = nil,
        isPlayable: Bool = true,
        onNavigate: ((NavigationDestination) -> Void)? = nil,
        onCreatePlaylist: ((Track) -> Void)? = nil
    ) -> SongRow {
        SongRow(
            track: track,
            leadingStyle: .rankWithArtwork(rank: rank),
            subtitleStyle: .playCount(playCount),
            showFavoriteButton: true,
            showDownloadIcon: true,
            playerService: playerService,
            cacheService: cacheService,
            musicService: musicService,
            isPlayable: isPlayable,
            onNavigate: onNavigate,
            onCreatePlaylist: onCreatePlaylist
        )
    }

    /// Queue/history display (no navigation - it's in a sheet)
    static func queue(
        track: Track,
        index: Int,
        playerService: PlayerService,
        accentColor: Color
    ) -> SongRow {
        SongRow(
            track: track,
            leadingStyle: .index(index),
            subtitleStyle: .artistOnly,
            showFavoriteButton: false,
            showDownloadIcon: false,
            playerService: playerService,
            cacheService: nil,
            musicService: nil,
            isPlayable: true,
            accentColor: accentColor,
            onNavigate: nil
        )
    }
}

// MARK: - Previews

#Preview("Standard Song Row") {
    List {
        SongRow.songs(
            track: .preview,
            playerService: PlayerService(),
            cacheService: nil
        )
        SongRow.songs(
            track: .preview,
            playerService: PlayerService(),
            cacheService: nil,
            isPlayable: false
        )
    }
}

#Preview("Album Track Row") {
    List {
        SongRow.albumTrack(
            track: .preview,
            playerService: PlayerService()
        )
        SongRow.albumTrack(
            track: .preview,
            playerService: PlayerService(),
            isPlayable: false
        )
    }
}

#Preview("Recently Added Row") {
    List {
        SongRow.recentlyAdded(
            track: .preview,
            playerService: PlayerService(),
            cacheService: nil
        )
    }
}

#Preview("Top 100 Row") {
    List {
        SongRow.top100(
            track: .preview,
            rank: 1,
            playCount: 42,
            playerService: PlayerService(),
            cacheService: nil
        )
        SongRow.top100(
            track: .preview,
            rank: 2,
            playCount: 38,
            playerService: PlayerService(),
            cacheService: nil
        )
    }
}

#Preview("Queue Row") {
    ZStack {
        Color.blue
        VStack(spacing: 0) {
            SongRow.queue(
                track: .preview,
                index: 1,
                playerService: PlayerService(),
                accentColor: .blue
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()
                .padding(.leading, 52)

            SongRow.queue(
                track: .preview,
                index: 2,
                playerService: PlayerService(),
                accentColor: .blue
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
    .frame(height: 150)
}
