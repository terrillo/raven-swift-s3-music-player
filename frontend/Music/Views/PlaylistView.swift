//
//  PlaylistView.swift
//  Music

import SwiftUI

struct PlaylistView: View {
    @Binding var showingSearch: Bool
    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?

    var body: some View {
        NavigationStack {
            List {
                Section("Favorites") {
                    NavigationLink {
                        FavoriteArtistsView(
                            musicService: musicService,
                            playerService: playerService,
                            cacheService: cacheService
                        )
                    } label: {
                        Label("Favorite Artists", systemImage: "heart.fill")
                    }

                    NavigationLink {
                        FavoriteAlbumsView(
                            musicService: musicService,
                            playerService: playerService,
                            cacheService: cacheService
                        )
                    } label: {
                        Label("Favorite Albums", systemImage: "heart.fill")
                    }

                    NavigationLink {
                        FavoriteTracksView(
                            musicService: musicService,
                            playerService: playerService,
                            cacheService: cacheService
                        )
                    } label: {
                        Label("Favorite Songs", systemImage: "heart.fill")
                    }
                }

                Section("Auto Playlists") {
                    NavigationLink {
                        RecentlyAddedView(
                            musicService: musicService,
                            playerService: playerService,
                            cacheService: cacheService
                        )
                    } label: {
                        Label("Recently Added", systemImage: "clock.arrow.circlepath")
                    }

                    NavigationLink {
                        Top100View(
                            musicService: musicService,
                            playerService: playerService,
                            cacheService: cacheService
                        )
                    } label: {
                        Label("Top 100", systemImage: "chart.line.uptrend.xyaxis")
                    }
                }

                Section("Insights") {
                    NavigationLink {
                        StatisticsView(
                            musicService: musicService,
                            playerService: playerService,
                            cacheService: cacheService
                        )
                    } label: {
                        Label("Statistics", systemImage: "chart.bar.fill")
                    }
                }
            }
            .navigationTitle("Playlists")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
        }
    }
}

struct FavoriteArtistsView: View {
    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?

    private var favoriteArtists: [Artist] {
        let favoriteEntities = FavoritesStore.shared.fetchFavoriteArtists()
        return favoriteEntities.compactMap { entity in
            guard let artistId = entity.artistId else { return nil }
            return musicService.artists.first { $0.id == artistId }
        }
    }

    var body: some View {
        Group {
            if favoriteArtists.isEmpty {
                ContentUnavailableView(
                    "No Favorite Artists",
                    systemImage: "heart",
                    description: Text("Tap the heart icon on any artist to add them to your favorites")
                )
            } else {
                List(favoriteArtists) { artist in
                    NavigationLink {
                        ArtistDetailView(artist: artist, musicService: musicService, playerService: playerService, cacheService: cacheService)
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkImage(
                                url: artist.imageUrl,
                                size: 56,
                                systemImage: "music.mic",
                                localURL: cacheService?.localArtworkURL(for: artist.imageUrl ?? ""),
                                cacheService: cacheService,
                                isCircular: true
                            )

                            VStack(alignment: .leading, spacing: 4) {
                                Text(artist.name)
                                    .font(.headline)

                                let songCount = artist.albums.flatMap { $0.tracks }.count
                                Text("\(artist.albums.count) albums · \(songCount) songs")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            ArtistFavoriteButton(artist: artist)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Favorite Artists")
    }
}

struct FavoriteAlbumsView: View {
    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?

    private var favoriteAlbums: [Album] {
        let favoriteEntities = FavoritesStore.shared.fetchFavoriteAlbums()
        return favoriteEntities.compactMap { entity in
            guard let albumId = entity.albumId else { return nil }
            return musicService.albums.first { $0.id == albumId }
        }
    }

    var body: some View {
        Group {
            if favoriteAlbums.isEmpty {
                ContentUnavailableView(
                    "No Favorite Albums",
                    systemImage: "heart",
                    description: Text("Tap the heart icon on any album to add it to your favorites")
                )
            } else {
                List(favoriteAlbums) { album in
                    NavigationLink {
                        AlbumDetailView(album: album, musicService: musicService, playerService: playerService, cacheService: cacheService)
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkImage(
                                url: album.imageUrl,
                                size: 56,
                                systemImage: "square.stack",
                                localURL: cacheService?.localArtworkURL(for: album.imageUrl ?? ""),
                                cacheService: cacheService
                            )

                            VStack(alignment: .leading, spacing: 4) {
                                Text(album.name)
                                    .font(.headline)

                                if let artist = album.tracks.first?.artist {
                                    Text(artist)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                Text("\(album.tracks.count) songs")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }

                            Spacer()

                            AlbumFavoriteButton(album: album)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Favorite Albums")
    }
}

struct FavoriteTracksView: View {
    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?

    private var favoriteTracks: [Track] {
        let favoriteEntities = FavoritesStore.shared.fetchFavoriteTracks()
        return favoriteEntities.compactMap { entity in
            guard let s3Key = entity.trackS3Key else { return nil }
            return musicService.songs.first { $0.s3Key == s3Key }
        }
    }

    private var firstPlayableTrack: Track? {
        favoriteTracks.first { playerService.isTrackPlayable($0) }
    }

    private var hasPlayableTracks: Bool {
        firstPlayableTrack != nil
    }

    var body: some View {
        Group {
            if favoriteTracks.isEmpty {
                ContentUnavailableView(
                    "No Favorite Songs",
                    systemImage: "heart",
                    description: Text("Tap the heart icon on any song to add it to your favorites")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Shuffle button
                        Button {
                            playerService.shufflePlay(queue: favoriteTracks)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!hasPlayableTracks)
                        .padding(.horizontal)
                        .padding(.vertical, 8)

                        Divider()

                        ForEach(favoriteTracks) { track in
                            let isPlayable = playerService.isTrackPlayable(track)
                            Button {
                                if isPlayable {
                                    playerService.play(track: track, queue: favoriteTracks)
                                }
                            } label: {
                                SongRow(track: track, playerService: playerService, cacheService: cacheService, isPlayable: isPlayable)
                                    .padding(.horizontal)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .disabled(!isPlayable)

                            Divider()
                                .padding(.leading, 60)
                        }
                    }
                }
            }
        }
        .navigationTitle("Favorite Songs")
    }
}

struct RecentlyAddedView: View {
    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?

    private var recentTracks: [Track] {
        musicService.recentlyAddedSongs
    }

    private var firstPlayableTrack: Track? {
        recentTracks.first { playerService.isTrackPlayable($0) }
    }

    private var hasPlayableTracks: Bool {
        firstPlayableTrack != nil
    }

    var body: some View {
        Group {
            if recentTracks.isEmpty {
                ContentUnavailableView(
                    "No Recently Added Songs",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Songs you upload will appear here")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Shuffle button
                        Button {
                            playerService.shufflePlay(queue: recentTracks)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!hasPlayableTracks)
                        .padding(.horizontal)
                        .padding(.vertical, 8)

                        Divider()

                        ForEach(recentTracks) { track in
                            let isPlayable = playerService.isTrackPlayable(track)
                            Button {
                                if isPlayable {
                                    playerService.play(track: track, queue: recentTracks)
                                }
                            } label: {
                                RecentlyAddedRow(
                                    track: track,
                                    playerService: playerService,
                                    cacheService: cacheService,
                                    isPlayable: isPlayable
                                )
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .disabled(!isPlayable)

                            Divider()
                                .padding(.leading, 60)
                        }
                    }
                }
            }
        }
        .navigationTitle("Recently Added")
    }
}

struct RecentlyAddedRow: View {
    let track: Track
    var playerService: PlayerService
    var cacheService: CacheService?
    var isPlayable: Bool = true

    private var isCurrentTrack: Bool {
        playerService.currentTrack?.id == track.id
    }

    private var isFavorite: Bool {
        FavoritesStore.shared.isTrackFavorite(track.s3Key)
    }

    private var relativeDate: String {
        guard let addedAt = track.addedAt else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: addedAt, relativeTo: Date())
    }

    var body: some View {
        HStack {
            // Album artwork with now playing indicator
            ZStack {
                ArtworkImage(
                    url: track.embeddedArtworkUrl,
                    size: 44,
                    systemImage: "music.note",
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

            VStack(alignment: .leading) {
                Text(track.title)
                    .font(.headline)
                    .foregroundStyle(isCurrentTrack ? Color.appAccent : (isPlayable ? .primary : .secondary))
                HStack {
                    if let artist = track.artist {
                        Text(artist)
                    }
                    if !relativeDate.isEmpty {
                        Text("•")
                        Text(relativeDate)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                FavoritesStore.shared.toggleTrackFavorite(track)
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(isFavorite ? .pink : .secondary)
            }
            .buttonStyle(.plain)

            if !isPlayable {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Text(track.formattedDuration)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .opacity(isPlayable ? 1.0 : 0.5)
    }
}

struct Top100View: View {
    var musicService: MusicService
    var playerService: PlayerService
    var cacheService: CacheService?

    @State private var selectedPeriod: TimePeriod = .allTime

    private var topTracks: [(track: Track, playCount: Int)] {
        // Fetch top tracks from Core Data + CloudKit with time filtering
        let topTrackData = AnalyticsStore.shared.fetchTopTracks(limit: 100, period: selectedPeriod)

        // Use O(1) lookup dictionary instead of O(n) search
        let trackLookup = musicService.trackByS3Key

        // Match to actual Track objects
        return topTrackData.compactMap { (s3Key, count) in
            guard let track = trackLookup[s3Key] else { return nil }
            return (track: track, playCount: count)
        }
    }

    var body: some View {
        Group {
            if topTracks.isEmpty {
                ContentUnavailableView(
                    "No Play History",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("Songs you play will appear here ranked by play count")
                )
            } else {
                List {
                    // Time Period Picker
                    Section {
                        Picker("Time Period", selection: $selectedPeriod) {
                            ForEach(TimePeriod.allCases) { period in
                                Text(period.rawValue).tag(period)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .listRowBackground(Color.clear)

                    // Track List
                    ForEach(Array(topTracks.enumerated()), id: \.element.track.id) { index, item in
                        let isPlayable = playerService.isTrackPlayable(item.track)
                        Button {
                            if isPlayable {
                                let tracks = topTracks.map { $0.track }
                                playerService.play(track: item.track, queue: tracks)
                            }
                        } label: {
                            Top100Row(
                                rank: index + 1,
                                track: item.track,
                                playCount: item.playCount,
                                playerService: playerService,
                                cacheService: cacheService,
                                isPlayable: isPlayable
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!isPlayable)
                    }
                }
                .refreshable {
                    musicService.invalidateCaches()
                }
            }
        }
        .navigationTitle("Top 100")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    musicService.invalidateCaches()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh stats")
            }
        }
    }
}

struct Top100Row: View {
    let rank: Int
    let track: Track
    let playCount: Int
    var playerService: PlayerService
    var cacheService: CacheService?
    var isPlayable: Bool = true

    private var isCurrentTrack: Bool {
        playerService.currentTrack?.id == track.id
    }

    private var isFavorite: Bool {
        FavoritesStore.shared.isTrackFavorite(track.s3Key)
    }

    var body: some View {
        HStack {
            // Rank number
            Text("\(rank)")
                .font(.headline)
                .foregroundStyle(isCurrentTrack ? Color.appAccent : .secondary)
                .frame(width: 30)

            // Album artwork with now playing indicator
            ZStack {
                ArtworkImage(
                    url: track.embeddedArtworkUrl,
                    size: 44,
                    systemImage: "music.note",
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

            VStack(alignment: .leading) {
                Text(track.title)
                    .font(.headline)
                    .foregroundStyle(isCurrentTrack ? Color.appAccent : (isPlayable ? .primary : .secondary))
                HStack {
                    if let artist = track.artist {
                        Text(artist)
                    }
                    Text("•")
                    Text("\(playCount) plays")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                FavoritesStore.shared.toggleTrackFavorite(track)
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(isFavorite ? .pink : .secondary)
            }
            .buttonStyle(.plain)

            if !isPlayable {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Text(track.formattedDuration)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .opacity(isPlayable ? 1.0 : 0.5)
    }
}

#Preview {
    PlaylistView(
        showingSearch: .constant(false),
        musicService: MusicService(),
        playerService: PlayerService()
    )
}
